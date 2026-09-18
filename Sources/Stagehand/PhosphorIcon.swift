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
        Image(nsImage: image)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private var image: NSImage {
        let filename = name.rawValue
        let url = Bundle.main.url(forResource: filename, withExtension: "svg", subdirectory: "Phosphor")
            ?? Bundle.module.url(forResource: filename, withExtension: "svg", subdirectory: "Phosphor")
        guard let url, let image = NSImage(contentsOf: url) else {
            assertionFailure("Missing Phosphor icon: \(filename)")
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
}
