import AppKit
import Testing
@testable import Stagehand
import StagehandCore
@testable import StagehandPlatform

@MainActor
@Test func focusBorderStaysBetweenNormalAndFloatingWindows() throws {
    let overlays = NavigationOverlays()
    defer { overlays.hide() }

    overlays.updateBorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100), visible: true)

    let border = try #require(overlays.border)
    #expect(border.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(border.level.rawValue < NSWindow.Level.floating.rawValue)
}

/// A lock or a trip to another Desktop keeps the panels, so the first presentation after
/// unlock does not build and draw a new one on the main thread. Stop releases them.
@MainActor
@Test func suspendKeepsThePanelsAndHideReleasesThem() throws {
    let overlays = NavigationOverlays()
    defer { overlays.hide() }
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    overlays.updateBorder(frame: frame, visible: true)
    let border = try #require(overlays.border)

    overlays.suspend()
    #expect(!border.isVisible)
    #expect(overlays.border === border)
    overlays.updateBorder(frame: frame, visible: true)
    #expect(overlays.border === border)
    #expect(border.isVisible)

    overlays.hide()
    #expect(overlays.border == nil)
}

@Test func shortcutRibbonFollowsTheCurrentBindings() throws {
    let sections = ShortcutHintSection.sections(for: ShortcutBinding.defaults)
    #expect(sections.map(\.title) == ["Navigate", "Move window", "Size", "Stagehand"])
    let hints = sections.flatMap(\.hints)
    #expect(hints.contains(ShortcutHint(title: "Window", modifiers: "⌃ ⌥", keys: ["←", "→"])))
    #expect(hints.contains(ShortcutHint(title: "Go to space", modifiers: "⌃ ⌥", keys: ["1–9"])))
    #expect(hints.contains(ShortcutHint(title: "Share with", modifiers: "⌃ ⌥ ⇧", keys: ["1–9"])))
    // "+" implies Shift, so grow stays on the same line as shrink.
    #expect(hints.contains(ShortcutHint(title: "Width", modifiers: "⌃ ⌥", keys: ["-", "+"])))
    #expect(hints.contains(ShortcutHint(title: "Shortcuts", modifiers: "⌃ ⌥ ⌘", keys: ["/"])))

    var bindings = ShortcutBinding.defaults
    for index in bindings.indices where bindings[index].id == "focusPrevious" || bindings[index].id == "togglePause" {
        bindings[index].isEnabled = false
    }
    let edited = ShortcutHintSection.sections(for: bindings).flatMap(\.hints)
    #expect(edited.contains(ShortcutHint(title: "Window", modifiers: "⌃ ⌥", keys: ["→"])))
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
    ribbon.setContent(ShortcutBinding.defaults, swipeTip: nil)
    ribbon.toggle()

    let panel = try #require(ribbon.panel)
    let padding = HUDContainerView.padding * 2
    // A narrow list of four groups.
    #expect(abs(panel.frame.width - padding - ShortcutHintsView.width) <= 1)
    #expect(panel.frame.height - padding > 300)
    let visible = try #require(NSScreen.managedDisplay).visibleFrame
    #expect(abs(panel.frame.maxX - HUDContainerView.padding - (visible.maxX - ShortcutHintsRibbon.edgeInset)) <= 1)
    #expect(abs(panel.frame.minY + HUDContainerView.padding - (visible.minY + ShortcutHintsRibbon.edgeInset)) <= 1)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.canBecomeKey)
}

@MainActor
@Test func shortcutRibbonTogglesAndExpires() async throws {
    #expect(ShortcutHintsRibbon.visibleDuration == .seconds(4))
    let ribbon = ShortcutHintsRibbon(reduceMotion: { true })
    defer { ribbon.hide() }
    ribbon.setContent(ShortcutBinding.defaults, swipeTip: nil)
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

@MainActor
@Test func shortcutRibbonSwipeTipFollowsTheSwipeSettings() {
    #expect(ShortcutHintsModel.swipeTip(enabled: false, reversed: true) == nil)
    let plain = ShortcutHintsModel.swipeTip(enabled: true, reversed: false)
    #expect(plain?.contains("three fingers") == true)
    #expect(plain?.contains("Swipe left") == false)
    #expect(ShortcutHintsModel.swipeTip(enabled: true, reversed: true)?.contains("Swipe left for →") == true)
}

@MainActor
@Test func shortcutRibbonStaysWhileThePointerIsOverIt() async throws {
    var pointer = CGPoint(x: -10_000, y: -10_000)
    let ribbon = ShortcutHintsRibbon(reduceMotion: { true }, pointerLocation: { pointer })
    defer { ribbon.hide() }
    ribbon.setContent(ShortcutBinding.defaults, swipeTip: nil)
    ribbon.show(for: .milliseconds(50))
    let panel = try #require(ribbon.panel)
    pointer = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
    ribbon.pointerMoved()
    #expect(ribbon.pointerInside)

    try await Task.sleep(for: .milliseconds(500))
    #expect(ribbon.isShowing)

    pointer = CGPoint(x: -10_000, y: -10_000)
    ribbon.pointerMoved()
    let deadline = ContinuousClock.now + .seconds(3)
    while panel.isVisible, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!panel.isVisible)
}

/// App bar chips look their app's icon up once, not on every redraw.
@MainActor
@Test func appIconsAreLookedUpOnce() {
    let first = AppIconCache.icon(for: "com.apple.finder")
    #expect(first != nil)
    #expect(AppIconCache.icon(for: "com.apple.finder") === first)
    #expect(AppIconCache.icon(for: "invalid.stagehand.none") == nil)
}

/// A new window count lays the bar out again inside the same panel instead of resizing it.
@Test func appBarPanelKeepsItsFrameAcrossWindowCounts() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    for notch in [false, true] {
        func layout(_ count: Int) -> NavigationHUDGeometry {
            NavigationHUDGeometry.layout(
                screenFrame: screen, visibleFrame: visible, safeAreaTop: notch ? 38 : 0,
                auxiliaryLeft: notch ? CGRect(x: 0, y: 944, width: 662, height: 38) : nil,
                auxiliaryRight: notch ? CGRect(x: 850, y: 944, width: 662, height: 38) : nil,
                windowCount: count)
        }
        let narrow = layout(2)
        let wide = layout(30)
        #expect(narrow.panelFrame == wide.panelFrame)
        #expect(narrow.contentFrame.width < wide.contentFrame.width)
        #expect(wide.panelFrame.contains(narrow.contentFrame))
        #expect(narrow.contentFrame.midX == wide.contentFrame.midX)
    }
    // A display narrower than the widest bar clamps both to its edges.
    let small = CGRect(x: 0, y: 0, width: 400, height: 600)
    func clamped(_ count: Int) -> NavigationHUDGeometry {
        NavigationHUDGeometry.layout(screenFrame: small, visibleFrame: small, safeAreaTop: 0,
                                     auxiliaryLeft: nil, auxiliaryRight: nil, windowCount: count)
    }
    #expect(clamped(2).panelFrame == clamped(30).panelFrame)
    #expect(clamped(2).panelFrame.contains(clamped(2).contentFrame))
    #expect(clamped(30).contentFrame.width == small.width - 32)
}

/// Accepting mouse events makes a panel catch clicks on its transparent padding, so only
/// the bar itself takes the pointer.
@MainActor
@Test func appBarTakesThePointerOnlyOverTheBar() throws {
    var pointer = CGPoint(x: -10_000, y: -10_000)
    let overlays = NavigationOverlays(reduceMotion: { true }, pointerLocation: { pointer })
    defer { overlays.hide() }
    let window = WindowRecord(id: "a", appName: "App", title: "a", bundleIdentifier: "test.app", pid: 1,
                              frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
    overlays.showNavigation(state: WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")]),
                            windows: [window])
    let hud = try #require(overlays.hud)
    #expect(hud.ignoresMouseEvents)

    let bar = hud.frame.insetBy(dx: 0, dy: NavigationHUDGeometry.padding)
    pointer = CGPoint(x: hud.frame.midX, y: bar.midY)
    overlays.pointerMoved()
    #expect(!hud.ignoresMouseEvents)

    // Beside the one-window bar, still inside the panel.
    pointer = CGPoint(x: hud.frame.minX + 4, y: bar.midY)
    overlays.pointerMoved()
    #expect(hud.ignoresMouseEvents)

    pointer = CGPoint(x: hud.frame.midX, y: bar.midY)
    overlays.showWarning("Stagehand paused")
    #expect(hud.ignoresMouseEvents)
}
