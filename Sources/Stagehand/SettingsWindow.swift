import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    static func make(model: StagehandModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Stagehand"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.contentMinSize = NSSize(width: 520, height: 480)
        window.center()
        return window
    }
}
