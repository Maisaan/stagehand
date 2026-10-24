import AppKit
import Testing
@testable import Stagehand
import StagehandPlatform

@MainActor
@Test func focusBorderStaysBetweenNormalAndFloatingWindows() throws {
    let overlays = NavigationOverlays()
    defer { overlays.hide() }

    overlays.updateBorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100), visible: true)

    let border = try #require(overlays.border)
    #expect(border.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(border.level.rawValue < NSWindow.Level.floating.rawValue)
}

@Test func shortcutRibbonFollowsTheCurrentBindings() throws {
    let rows = ShortcutHintRow.rows(for: ShortcutBinding.defaults)
    #expect(rows.map(\.modifiers) == ["⌃ ⌥", "⌃ ⌥ ⌘", "⌃ ⌥ ⇧"])
    // Columns line up by key kind across rows.
    #expect(rows[0].columns[0] == [ShortcutHint(title: "Focus", keys: ["←", "→"])])
    #expect(rows[1].columns[0] == [ShortcutHint(title: "Reorder", keys: ["←", "→"])])
    #expect(rows[0].columns[2] == [ShortcutHint(title: "Go to", keys: ["1–9"])])
    #expect(rows[2].columns[2] == [ShortcutHint(title: "Share with", keys: ["1–9"])])
    // "+" implies Shift, so grow stays beside shrink in the unshifted row.
    #expect(rows[0].columns[3] == [ShortcutHint(title: "Width", keys: ["-", "+"])])
    #expect(rows[2].columns[4] == [ShortcutHint(title: "Previous preset", keys: ["0"])])
    #expect(rows[1].columns.flatMap { $0 }.contains(ShortcutHint(title: "Shortcuts", keys: ["/"])))

    var bindings = ShortcutBinding.defaults
    for index in bindings.indices where bindings[index].id == "focusPrevious" || bindings[index].id == "togglePause" {
        bindings[index].isEnabled = false
    }
    let edited = ShortcutHintRow.rows(for: bindings).flatMap { $0.columns.flatMap { $0 } }
    #expect(edited.contains(ShortcutHint(title: "Focus", keys: ["→"])))
    #expect(!edited.contains { $0.title == "Pause" })
}

@MainActor
@Test func shortcutRibbonToggleCommandDoesNotMoveFocus() throws {
    let binding = try #require(ShortcutBinding.defaults.first { $0.id == "toggleShortcutHints" })
    #expect(binding.action == .toggleShortcutHints)
    #expect(binding.action.isStagehandCommand)
    #expect(ShortcutBinding.validationIssue(key: binding.key, modifiers: binding.modifiers,
                                            keyLabel: binding.keyLabel) == nil)
}

@MainActor
@Test func shortcutRibbonPanelFitsItsContent() throws {
    let ribbon = ShortcutHintsRibbon(reduceMotion: { true })
    defer { ribbon.hide() }
    ribbon.setBindings(ShortcutBinding.defaults)
    ribbon.toggle()

    let panel = try #require(ribbon.panel)
    let padding = HUDContainerView.padding * 2
    // Two rows of hints, wider than any single label.
    #expect(panel.frame.width - padding > 400)
    #expect(panel.frame.height - padding > 40)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.canBecomeKey)
}

@MainActor
@Test func shortcutRibbonTogglesAndExpires() async throws {
    #expect(ShortcutHintsRibbon.visibleDuration == .seconds(4))
    let ribbon = ShortcutHintsRibbon(reduceMotion: { true })
    defer { ribbon.hide() }
    ribbon.setBindings(ShortcutBinding.defaults)
    ribbon.toggle()
    #expect(ribbon.isShowing)
    ribbon.toggle()
    // The fade runs on main-actor tasks; a loaded test host can delay them.
    let deadline = ContinuousClock.now + .seconds(3)
    while ribbon.panel?.isVisible == true, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!ribbon.isShowing)
    #expect(ribbon.panel?.isVisible == false)
}
