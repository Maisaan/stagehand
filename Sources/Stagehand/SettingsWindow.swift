import AppKit
import SwiftUI
import StagehandPlatform

@MainActor
enum SettingsWindow {
    static func make(model: StagehandModel) -> NSWindow {
        let window = RibbonWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Stagehand"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Settings belongs to Stage Manager as a utility window, but must never
        // join another app's native full-screen Space.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.contentMinSize = NSSize(width: 520, height: 480)
        window.center()
        return window
    }
}
