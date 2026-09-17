import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    static func make(model: StagehandModel, showOnboarding: @escaping () -> Void = {}) -> NSWindow {
        let window = SettingsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Stagehand"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        // Settings belongs to Stage Manager as a utility window, but must never
        // join another app's native full-screen Space.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.contentView = NSHostingView(rootView: SettingsView(model: model, showOnboarding: showOnboarding))
        window.alignWindowControls()
        window.contentMinSize = NSSize(width: 700, height: 620)
        window.center()
        return window
    }
}

@MainActor
private final class SettingsPanelWindow: NSWindow {
    private static let windowControlInset: CGFloat = 26

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        alignWindowControls()
    }

    func alignWindowControls() {
        guard let closeButton = standardWindowButton(.closeButton) else { return }
        let closeFrame = closeButton.convert(closeButton.bounds, to: nil)
        let closeCenter = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
        let offset = CGPoint(
            x: Self.windowControlInset - closeCenter.x,
            y: frame.height - Self.windowControlInset - closeCenter.y
        )
        guard offset != .zero else { return }

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(buttonType) else { continue }
            button.setFrameOrigin(CGPoint(
                x: button.frame.minX + offset.x,
                y: button.frame.minY + offset.y
            ))
        }
    }
}
