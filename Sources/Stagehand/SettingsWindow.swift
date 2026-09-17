import AppKit
import SwiftUI
import StagehandPlatform

@MainActor
enum SettingsWindow {
    static func make(model: StagehandModel, showOnboarding: @escaping () -> Void = {}) -> NSWindow {
        let window = RibbonWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
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
        window.contentMinSize = NSSize(width: 700, height: 620)
        window.center()
        return window
    }
}
