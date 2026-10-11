import AppKit
import SwiftUI

enum PhosphorIconName: String {
    case appWindow = "app-window-fill"
    case arrowCounterClockwise = "arrow-counter-clockwise-fill"
    case arrowsDownUp = "arrows-down-up-fill"
    case arrowsLeftRight = "arrows-left-right-fill"
    case browser = "browser-fill"
    case cardsThree = "cards-three-fill"
    case caretRight = "caret-right-fill"
    case check = "check-fill"
    case checkCircle = "check-circle-fill"
    case dotsSixVertical = "dots-six-vertical"
    case dotsThreeVertical = "dots-three-vertical-fill"
    case gear = "gear-fill"
    case gearSix = "gear-six-fill"
    case handPalm = "hand-palm-fill"
    case info = "info-fill"
    case keyboard = "keyboard-fill"
    case personArmsSpread = "person-arms-spread-fill"
    case rectangleDashed = "rectangle-dashed-fill"
    case shieldCheck = "shield-check-fill"
    case warning = "warning-fill"
    case warningCircle = "warning-circle-fill"
    case x = "x-fill"
    case xCircle = "x-circle-fill"
}

struct PhosphorIcon: View {
    let name: PhosphorIconName

    init(_ name: PhosphorIconName) {
        self.name = name
    }

    var body: some View {
        Image(nsImage: PhosphorIconCache.image(for: name))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// Parses each SVG once per process. View bodies run on every model change, and
/// reading and decoding the file each time was the cost the audit flagged.
@MainActor
enum PhosphorIconCache {
    private static var images: [PhosphorIconName: NSImage] = [:]
    private static let iconSize = NSSize(width: 16, height: 16)
    private static let resourceBundleName = "stagehand_Stagehand.bundle"

    static func image(for name: PhosphorIconName) -> NSImage {
        if let cached = images[name] { return cached }
        let image = load(name) ?? missingImage(for: name)
        images[name] = image
        return image
    }

    /// The installed app carries Phosphor in Contents/Resources. `swift test` and
    /// `swift run` keep it in the SwiftPM resource bundle next to the executable.
    /// The generated `Bundle.module` accessor traps when that bundle is absent, so
    /// resolve the directories by hand and fall through to nil instead.
    static func url(for name: PhosphorIconName) -> URL? {
        let filename = name.rawValue
        if let url = Bundle.main.url(forResource: filename, withExtension: "svg", subdirectory: "Phosphor") {
            return url
        }
        for directory in resourceBundleDirectories {
            guard let bundle = Bundle(url: directory.appendingPathComponent(resourceBundleName)),
                  let url = bundle.url(forResource: filename, withExtension: "svg", subdirectory: "Phosphor")
            else { continue }
            return url
        }
        return nil
    }

    private static var resourceBundleDirectories: [URL] {
        let anchor = Bundle(for: PhosphorBundleAnchor.self)
        var directories = [
            Bundle.main.bundleURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            anchor.bundleURL,
            anchor.resourceURL,
            anchor.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
        if let executable = Bundle.main.executableURL {
            directories.append(executable.deletingLastPathComponent())
        }
        var seen: Set<URL> = []
        return directories.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    private static func load(_ name: PhosphorIconName) -> NSImage? {
        guard let url = url(for: name), let image = NSImage(contentsOf: url) else { return nil }
        image.size = iconSize
        image.isTemplate = true
        return image
    }

    private static func missingImage(for name: PhosphorIconName) -> NSImage {
        assertionFailure("Missing Phosphor icon: \(name.rawValue)")
        let image = NSImage(size: iconSize)
        image.isTemplate = true
        return image
    }
}

private final class PhosphorBundleAnchor {}
