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
    #expect(window.contentMinSize == NSSize(width: 680, height: 560))
    #expect(window.collectionBehavior.contains(.auxiliary))
    #expect(window.collectionBehavior.contains(.fullScreenNone))
    #expect(!window.collectionBehavior.contains(.canJoinAllApplications))
    #expect(!window.collectionBehavior.contains(.fullScreenAuxiliary))

    // Measure the SwiftUI root itself. The hosting view's bounds alone can grow while
    // a fixed-size root remains 680 × 610 inside it.
    let measured = NSView()
    let content = NSHostingView(rootView: SettingsView(model: model).background(SettingsSizeProbe(view: measured)))
    window.contentView = content

    for size in [NSSize(width: 680, height: 560), NSSize(width: 900, height: 760)] {
        window.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        #expect(content.bounds.size == size)
        #expect(measured.frame.size == size)
    }
}

@Test @MainActor func hexColorEditorKeepsEnoughWidthForTheWholeValue() async throws {
    _ = NSApplication.shared
    let content = NSHostingView(rootView: SettingsView(model: StagehandModel()))
    content.frame = CGRect(x: 0, y: 0, width: 680, height: 560)
    content.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    content.layoutSubtreeIfNeeded()

    let field = try #require(editableTextFields(in: content).first { $0.stringValue.hasPrefix("#") })
    #expect(field.frame.width >= 100)
}

@Test func legacySettingsTabNamesMapToTheNewSidebarPages() {
    #expect(SettingsPage(tab: "Workspace") == .windows)
    #expect(SettingsPage(tab: "Controls") == .shortcuts)
    #expect(SettingsPage(tab: "Setup") == .system)
}

@MainActor private func editableTextFields(in view: NSView) -> [NSTextField] {
    let current = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
    return current + view.subviews.flatMap(editableTextFields)
}

private struct SettingsSizeProbe: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
