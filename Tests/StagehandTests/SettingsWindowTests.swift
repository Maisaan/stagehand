import AppKit
import SwiftUI
import Testing
@testable import Stagehand

@Test @MainActor func settingsWindowAllowsResizingAndCompactContent() throws {
    _ = NSApplication.shared
    let model = StagehandModel()
    let window = SettingsWindow.make(model: model)
    defer { window.close() }

    #expect(window.styleMask.contains(.resizable))
    #expect(window.contentMinSize == NSSize(width: 520, height: 480))
    #expect(window.collectionBehavior.contains(.auxiliary))
    #expect(window.collectionBehavior.contains(.fullScreenNone))
    #expect(!window.collectionBehavior.contains(.canJoinAllApplications))
    #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))

    // Measure the SwiftUI root itself. The hosting view's bounds alone can grow while
    // a fixed-size root remains 680 × 610 inside it.
    let measured = NSView()
    let content = NSHostingView(rootView: SettingsView(model: model).background(SettingsSizeProbe(view: measured)))
    window.contentView = content

    for size in [NSSize(width: 520, height: 480), NSSize(width: 900, height: 760)] {
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        #expect(content.bounds.size == size)
        #expect(measured.frame.size == size)
    }
}

private struct SettingsSizeProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
