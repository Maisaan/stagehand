import AppKit
import StagehandCore

/// A connected display. Frames are in Accessibility coordinates: y grows downward
/// from the top of the menu-bar display.
public struct Display: Equatable, Sendable {
    public let id: DisplayID
    public let number: CGDirectDisplayID
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isBuiltIn: Bool
    public let backingScaleFactor: CGFloat
    public let maximumFramesPerSecond: Int
}

/// A screen as AppKit reports it, in AppKit coordinates (y grows upward).
public struct ScreenDescription: Equatable, Sendable {
    public let id: DisplayID
    public let number: CGDirectDisplayID
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isBuiltIn: Bool
    public let backingScaleFactor: CGFloat
    public let maximumFramesPerSecond: Int

    public init(id: DisplayID, number: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect,
                isBuiltIn: Bool, backingScaleFactor: CGFloat, maximumFramesPerSecond: Int) {
        self.id = id
        self.number = number
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isBuiltIn = isBuiltIn
        self.backingScaleFactor = backingScaleFactor
        self.maximumFramesPerSecond = maximumFramesPerSecond
    }

    @MainActor
    public init?(_ screen: NSScreen) {
        guard let number = screen.displayNumber, let id = DisplayID(displayNumber: number) else { return nil }
        self.init(id: id, number: number, frame: screen.frame, visibleFrame: screen.visibleFrame,
                  isBuiltIn: CGDisplayIsBuiltin(number) != 0, backingScaleFactor: screen.backingScaleFactor,
                  maximumFramesPerSecond: screen.maximumFramesPerSecond)
    }
}

/// The connected displays, left to right, and the display that holds spaces whose
/// display is not connected: the built-in display if there is one, else the menu-bar display.
public struct DisplayArrangement: Equatable, Sendable {
    public let displays: [Display]
    public let fallback: DisplayID?

    /// `screens` in `NSScreen.screens` order, so the first is the menu-bar display.
    public init(screens: [ScreenDescription]) {
        guard let primary = screens.first else {
            displays = []
            fallback = nil
            return
        }
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        displays = screens.map { screen in
            Display(id: screen.id, number: screen.number, frame: flipped(screen.frame),
                    visibleFrame: flipped(screen.visibleFrame), isBuiltIn: screen.isBuiltIn,
                    backingScaleFactor: screen.backingScaleFactor,
                    maximumFramesPerSecond: screen.maximumFramesPerSecond)
        }.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        fallback = (screens.first(where: \.isBuiltIn) ?? primary).id
    }

    @MainActor
    public static func current() -> DisplayArrangement {
        DisplayArrangement(screens: NSScreen.screens.compactMap(ScreenDescription.init))
    }

    public var builtIn: Display? { displays.first(where: \.isBuiltIn) }

    public var ids: [DisplayID] { displays.map(\.id) }

    public func display(_ id: DisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    /// The display touching `id`'s left or right edge, within a point, that overlaps it vertically.
    public func neighbor(of id: DisplayID, on side: WindowParkingSide) -> Display? {
        guard let display = display(id) else { return nil }
        let edge = side == .left ? display.frame.minX : display.frame.maxX
        return displays.first { other in
            guard other.id != id,
                  min(display.frame.maxY, other.frame.maxY) - max(display.frame.minY, other.frame.minY) > 0
            else { return false }
            let facingEdge = side == .left ? other.frame.maxX : other.frame.minX
            return abs(facingEdge - edge) <= 1
        }
    }

    public func sharedEdges(of id: DisplayID) -> Set<WindowParkingSide> {
        Set([WindowParkingSide.left, .right].filter { neighbor(of: id, on: $0) != nil })
    }

    /// A display with displays on both sides, so it has no free edge to park windows at.
    public var displayWithoutFreeEdge: Display? {
        displays.first { sharedEdges(of: $0.id).count == 2 }
    }

    /// Every display, unless one has no free edge: then the fallback display alone, or
    /// none when the fallback is such a display itself.
    public var managedDisplays: ManagedDisplays {
        guard let unsupported = displayWithoutFreeEdge else {
            return ManagedDisplays(ids: ids, fallback: fallback, displayWithoutFreeEdge: nil)
        }
        guard let fallback, sharedEdges(of: fallback).count < 2 else {
            return ManagedDisplays(ids: [], fallback: nil, displayWithoutFreeEdge: unsupported)
        }
        return ManagedDisplays(ids: [fallback], fallback: fallback, displayWithoutFreeEdge: unsupported)
    }
}

public struct ManagedDisplays: Equatable, Sendable {
    public let ids: [DisplayID]
    public let fallback: DisplayID?
    /// Set when the arrangement is refused: a display with displays on both sides.
    public let displayWithoutFreeEdge: Display?

    /// False only when the arrangement is refused and the fallback display has no free edge either.
    public var isManageable: Bool { !ids.isEmpty || displayWithoutFreeEdge == nil }
}

public extension DisplayID {
    init?(displayNumber: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayNumber)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return nil }
        self.init(rawValue: string as String)
    }
}

public extension NSScreen {
    var displayNumber: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    @MainActor
    static func screen(displayNumber: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayNumber == displayNumber }
    }
}
