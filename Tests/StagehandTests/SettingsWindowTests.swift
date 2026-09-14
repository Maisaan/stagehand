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

@Test @MainActor func maximizeHidesGapEditorWithoutDiscardingItsValue() async throws {
    _ = NSApplication.shared
    let defaults = UserDefaults.standard
    let savedPreference = defaults.object(forKey: "maximizeWindows")
    defer { defaults.set(savedPreference, forKey: "maximizeWindows") }
    let model = StagehandModel()
    let gap = model.gap
    model.setMaximizeWindows(false)
    let window = SettingsWindow.make(model: model)
    defer { window.close() }
    let content = try #require(window.contentView)

    for maximize in [false, true, false] {
        model.setMaximizeWindows(maximize)
        try await Task.sleep(for: .milliseconds(30))
        content.layoutSubtreeIfNeeded()
        #expect(containsGapEditor(in: content) == !maximize)
        #expect(model.gap == gap)
    }
}

@MainActor private func containsGapEditor(in view: NSView) -> Bool {
    if view is GapTextField { return true }
    return view.subviews.contains { containsGapEditor(in: $0) }
}

private struct SettingsSizeProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
