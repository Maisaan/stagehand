import AppKit
import StagehandCore
@testable import StagehandPlatform
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct NavigationInteractionTests {
    @Test func hoverRevealsAndHoldsBarWithoutTakingKeyboardFocus() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let overlays = NavigationOverlays(reduceMotion: { true })
        defer { overlays.hide() }
        overlays.canRevealNavigation = { true }
        overlays.updateNavigation(state: WorkspaceState(), windows: [])
        #expect(overlays.hud == nil)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp.keyWindow

        overlays.pointerMoved(to: CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1))
        let panel = try #require(overlays.hud)
        #expect(panel.isVisible)
        #expect(overlays.pointerKeepsHUDVisible)
        #expect(!overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        #expect(!panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
        #expect(NSApp.keyWindow === keyWindow)

        overlays.pointerMoved(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY))
        #expect(overlays.pointerKeepsHUDVisible)
        overlays.pointerMoved(to: CGPoint(x: screen.frame.minX, y: screen.frame.minY))
        #expect(!overlays.pointerKeepsHUDVisible)
        #expect(overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        #expect(overlays.completeHUDDismiss(generation: overlays.hudGeneration))
        #expect(!panel.isVisible)
    }

    @Test func suspendedOrPausedWorkspaceCannotRevealOnHover() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        overlays.canRevealNavigation = { false }
        overlays.updateNavigation(state: WorkspaceState(), windows: [])
        let trigger = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
        overlays.pointerMoved(to: trigger)
        #expect(overlays.hud == nil)
        #expect(!overlays.pointerKeepsHUDVisible)
        overlays.canRevealNavigation = { true }
        overlays.hide()
        overlays.pointerMoved(to: trigger)
        #expect(overlays.hud == nil)
    }

    @Test func appSelectionUsesManagedWindowIdentityAndExistingFocusRoute() {
        let model = NavigationHUDModel()
        model.windows = [WindowRecord(id: "first", appName: "Example", title: "One", bundleIdentifier: "com.example",
                                      pid: 10, frame: .zero, isResizable: true),
                         WindowRecord(id: "second", appName: "Example", title: "Two", bundleIdentifier: "com.example",
                                      pid: 10, frame: .zero, isResizable: true)]
        var selections: [String] = []
        model.onFocusWindow = { selections.append($0) }
        model.selectWindow(id: "second")
        model.selectWindow(id: "stale-window")
        #expect(selections == ["second"])
        // Focus indication changes only after the actual window manager confirms navigation.
        #expect(model.focusedID == nil)
    }

    @Test func appBarLabelOmitsTheWindowTitle() {
        let model = NavigationHUDModel()
        model.windows = [WindowRecord(id: "first", appName: "Example", title: "A very long document title",
                                      bundleIdentifier: "com.example", pid: 10, frame: .zero, isResizable: true)]
        model.focusedID = "first"
        #expect(model.focusedAppName == "Example")
    }

    @Test func appBarMembershipActionsUseTheClickedWindow() {
        let model = NavigationHUDModel()
        model.space = 1
        model.windows = [
            WindowRecord(id: "focused", appName: "First", title: "", bundleIdentifier: "com.first",
                         pid: 10, frame: .zero, isResizable: true),
            WindowRecord(id: "other", appName: "Second", title: "", bundleIdentifier: "com.second",
                         pid: 11, frame: .zero, isResizable: true)
        ]
        model.focusedID = "focused"
        model.spaces = [
            SpaceState(windowIDs: ["focused", "other"]),
            SpaceState(windowIDs: ["other"]),
            SpaceState()
        ]
        var shared: [(String, Int)] = []
        var removed: [String] = []
        model.onShareWindow = { shared.append(($0, $1)) }
        model.onRemoveWindow = { removed.append($0) }

        #expect(model.shareDestinations(for: "other") == [2])
        #expect(model.canRemoveFromCurrentSpace(windowID: "other"))
        model.shareWindow(id: "other", withSpace: 2)
        model.shareWindow(id: "other", withSpace: 1)
        model.removeWindowFromCurrentSpace(id: "other")

        #expect(shared.map(\.0) == ["other"])
        #expect(shared.map(\.1) == [2])
        #expect(removed == ["other"])
    }

    @Test func appBarDropReordersTheDraggedWindow() {
        let model = NavigationHUDModel()
        model.windows = [
            WindowRecord(id: "first", appName: "First", title: "", bundleIdentifier: "com.first",
                         pid: 10, frame: .zero, isResizable: true),
            WindowRecord(id: "second", appName: "Second", title: "", bundleIdentifier: "com.second",
                         pid: 11, frame: .zero, isResizable: true),
            WindowRecord(id: "third", appName: "Third", title: "", bundleIdentifier: "com.third",
                         pid: 12, frame: .zero, isResizable: true)
        ]
        var reorders: [(String, Int)] = []
        model.onReorderWindow = { reorders.append(($0, $1)) }

        #expect(model.reorderWindow(id: "first", onto: "third"))
        #expect(!model.reorderWindow(id: "first", onto: "first"))
        #expect(!model.reorderWindow(id: "stale", onto: "second"))
        #expect(!model.reorderWindow(id: "second", onto: "stale"))
        #expect(reorders.map(\.0) == ["first"])
        #expect(reorders.map(\.1) == [2])
    }

    @Test func spacePickerUsesAvailableSpacesAndReturnsToAppsAfterSelection() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let state = WorkspaceState(spaces: [SpaceState(), SpaceState(windowIDs: ["one"]),
                                           SpaceState(), SpaceState(windowIDs: ["two"])], activeSpaceIndex: 1)
        overlays.showNavigation(state: state, windows: [])
        var selected: [Int] = []
        overlays.onSelectSpace = { selected.append($0) }
        let model = overlays.hudModel
        #expect(model.availableSpaceIndices == [1, 3])
        model.toggleSpaces()
        #expect(model.showingSpaces)
        #expect(model.displayedItemCount == 2)
        let panel = try #require(overlays.hud)
        #expect(panel.frame.width == 132 + NavigationHUDGeometry.padding * 2)
        model.selectSpace(index: 8)
        #expect(model.showingSpaces)
        #expect(selected.isEmpty)
        model.selectSpace(index: 3)
        #expect(selected == [3])
        #expect(!model.showingSpaces)
        #expect(panel.frame.width == 96 + NavigationHUDGeometry.padding * 2)
    }
}
