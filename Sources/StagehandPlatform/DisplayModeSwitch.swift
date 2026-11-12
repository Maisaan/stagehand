import AppKit
import CoreGraphics

/// A display mode's sizes, apart from its CoreGraphics object, so the choice can be tested.
public struct DisplayModeOption: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var usableForDesktop: Bool

    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, usableForDesktop: Bool = true) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.usableForDesktop = usableForDesktop
    }

    init(mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                  refreshRate: mode.refreshRate, usableForDesktop: mode.isUsableForDesktopGUI())
    }

    public var pointSize: String { "\(width)x\(height)" }

    private var isHiDPI: Bool { pixelWidth > width }
    private var aspectRatio: Double { Double(width) / Double(height) }

    /// The scaled mode nearest in size to `current` with a different point size, the same
    /// pixel density and shape, preferring the current refresh rate, then the larger size.
    public static func alternative(to current: DisplayModeOption, among modes: [DisplayModeOption]) -> DisplayModeOption? {
        modes.filter {
            $0.usableForDesktop && $0.isHiDPI == current.isHiDPI
                && ($0.width != current.width || $0.height != current.height)
                && abs($0.aspectRatio - current.aspectRatio) < 0.02
        }.min { lhs, rhs in
            (lhs.refreshRate == current.refreshRate ? 0 : 1, abs(lhs.width - current.width), -lhs.width)
                < (rhs.refreshRate == current.refreshRate ? 0 : 1, abs(rhs.width - current.width), -rhs.width)
        }
    }
}

/// Changes one display's mode for this process only: macOS puts the user's mode back
/// by itself when Stagehand exits or crashes.
@MainActor
public final class DisplayModeSwitch {
    public let display: CGDirectDisplayID
    public let original: DisplayModeOption
    private let originalMode: CGDisplayMode
    private var mayBeChanged = false

    public init?(display: CGDirectDisplayID) {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        self.display = display
        originalMode = mode
        original = DisplayModeOption(mode: mode)
    }

    /// The built-in display while it is drawable; nil with the lid closed.
    public static func activeBuiltInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    public func alternativeMode() -> (mode: CGDisplayMode, option: DisplayModeOption)? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return nil }
        let described = modes.map(DisplayModeOption.init(mode:))
        guard let choice = DisplayModeOption.alternative(to: original, among: described),
              let index = described.firstIndex(of: choice) else { return nil }
        return (modes[index], choice)
    }

    public func apply(_ mode: CGDisplayMode) -> CGError {
        mayBeChanged = true
        return configure(mode)
    }

    /// Puts the original mode back after any `apply`, even a failed one.
    @discardableResult
    public func restore() -> CGError {
        guard mayBeChanged else { return .success }
        let result = configure(originalMode)
        if result == .success { mayBeChanged = false }
        return result
    }

    public var screenSize: CGSize? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }?.frame.size
    }

    private func configure(_ mode: CGDisplayMode) -> CGError {
        var configuration: CGDisplayConfigRef?
        let began = CGBeginDisplayConfiguration(&configuration)
        guard began == .success, let configuration else { return began }
        let configured = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
        guard configured == .success else {
            CGCancelDisplayConfiguration(configuration)
            return configured
        }
        return CGCompleteDisplayConfiguration(configuration, .forAppOnly)
    }
}
