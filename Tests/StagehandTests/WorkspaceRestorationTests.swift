import CoreGraphics
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

struct WorkspaceRestorationTests {
    @Test func applicationTerminationRemovesItsWindowsBeforeTheNextRefresh() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["left", "terminated", "right"], focusedWindowID: "terminated")
        ])
        var windows = [
            WindowRecord(id: "left", appName: "Left", title: "", bundleIdentifier: "left", pid: 1,
                         frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "terminated", appName: "Gone", title: "", bundleIdentifier: "gone", pid: 2,
                         frame: CGRect(x: 100, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "right", appName: "Right", title: "", bundleIdentifier: "right", pid: 3,
                         frame: CGRect(x: 200, y: 0, width: 100, height: 100), isResizable: true)
        ]

        let removed = removeTerminatedApplication(pid: 2, windows: &windows, state: &state)

        #expect(removed == ["terminated"])
        #expect(windows.map(\.id) == ["left", "right"])
        #expect(state.currentSpace.windowIDs == ["left", "right"])
        #expect(state.focusedWindowID == "right")
    }

    @Test func destroyedWindowLeavesTheRibbonBeforeTheNextScan() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["left", "closed", "right"], focusedWindowID: "closed")
        ])
        var windows = [
            WindowRecord(id: "left", appName: "Left", title: "", bundleIdentifier: "left", pid: 1,
                         frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "closed", appName: "Closed", title: "", bundleIdentifier: "closed", pid: 2,
                         frame: CGRect(x: 100, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "right", appName: "Right", title: "", bundleIdentifier: "right", pid: 2,
                         frame: CGRect(x: 200, y: 0, width: 100, height: 100), isResizable: true)
        ]

        #expect(removeDestroyedWindow(windowID: "closed", windows: &windows, state: &state))
        #expect(windows.map(\.id) == ["left", "right"])
        #expect(state.currentSpace.windowIDs == ["left", "right"])
        #expect(state.focusedWindowID == "right")
        #expect(!removeDestroyedWindow(windowID: "closed", windows: &windows, state: &state))
    }

    @Test func minimizedWindowLeavesTheRibbonAndReturnsToItsMembership() {
        let original = WorkspaceState(spaces: [
            SpaceState(
                windowIDs: ["left", "minimized", "right"],
                focusedWindowID: "minimized",
                widthFractions: ["minimized": 0.62]
            ),
            SpaceState(windowIDs: ["minimized"])
        ])
        var state = original
        var restoration = WorkspaceRestoration()

        var windows = [
            WindowRecord(id: "left", appName: "Left", title: "", bundleIdentifier: "left", pid: 1,
                         frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "minimized", appName: "Minimized", title: "", bundleIdentifier: "minimized", pid: 2,
                         frame: CGRect(x: 100, y: 0, width: 100, height: 100), isResizable: true),
            WindowRecord(id: "right", appName: "Right", title: "", bundleIdentifier: "right", pid: 3,
                         frame: CGRect(x: 200, y: 0, width: 100, height: 100), isResizable: true)
        ]
        let minimized = windows[1]

        #expect(removeUnavailableWindow(
            windowID: minimized.id,
            windows: &windows,
            state: &state,
            restoration: &restoration,
            trackedWindowIDs: ["left", "minimized", "right"]
        ))

        #expect(state.spaces.allSatisfy { !$0.windowIDs.contains("minimized") })
        #expect(state.currentSpace.windowIDs == ["left", "right"])
        #expect(state.focusedWindowID != "minimized")

        #expect(restoreAvailableWindow(
            minimized,
            windows: &windows,
            state: &state,
            restoration: &restoration,
            trackedWindowIDs: ["left", "minimized", "right"],
            initialWidthFractions: ["minimized": 0.8]
        ))

        #expect(state.spaces[0].windowIDs == original.spaces[0].windowIDs)
        #expect(state.spaces[0].widthFraction(for: "minimized") == 0.62)
        #expect(state.spaces[1].windowIDs == ["minimized"])
    }

    @Test func focusHistoryReturnsToTheMostRecentlyFocusedSurvivingWindow() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["closing", "spatial-fallback", "previous"], focusedWindowID: "closing")
        ])
        var history = WindowFocusHistory()
        history.record(windowID: "previous")
        history.record(windowID: "closing")

        state.reconcile(windowIDs: ["spatial-fallback", "previous"])
        history.remove(windowIDs: ["closing"])
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: "closing",
            history: history,
            state: &state
        )

        #expect(state.focusedWindowID == "previous")
    }

    @Test func focusHistorySkipsMissingWindowsAndAllowsTheLayoutFallback() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["closing", "fallback"], focusedWindowID: "closing")
        ])
        var history = WindowFocusHistory()
        history.record(windowID: "missing")
        history.record(windowID: "closing")

        state.reconcile(windowIDs: ["fallback"])
        history.remove(windowIDs: ["closing"])
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: "closing",
            history: history,
            state: &state
        )

        #expect(state.focusedWindowID == "fallback")
    }

    @Test func newlyDiscoveredWindowUsesItsInitialWidth() {
        var state = WorkspaceState()
        var restoration = WorkspaceRestoration()

        restoration.reconcile(
            state: &state,
            windowIDs: ["new"],
            trackedWindowIDs: ["new"],
            initialWidthFractions: ["new": 0.64]
        )

        #expect(state.currentSpace.widthFraction(for: "new") == 0.64)
    }

    @Test func resumingPreservesSpacesOrderSharingAndWidthsAndOmitsClosedWindows() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["left", "closed", "shared"], focusedWindowID: "left",
                       widthFractions: ["shared": 0.6, "closed": 0.5]),
            SpaceState(),
            SpaceState(windowIDs: ["shared", "closed", "right"], focusedWindowID: "right",
                       widthFractions: ["shared": 0.4, "closed": 0.7])
        ], activeSpaceIndex: 2)
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: nil)
        #expect(state.isPaused)
        restoration.reconcile(state: &state, windowIDs: ["right", "shared", "left"],
                              trackedWindowIDs: ["left", "shared", "right"])
        state.isPaused = false

        #expect(state.activeSpaceIndex == 2)
        #expect(state.spaces[0] == SpaceState(windowIDs: ["left", "shared"], focusedWindowID: "left",
                                            widthFractions: ["shared": 0.6]))
        #expect(state.spaces[1].windowIDs.isEmpty)
        #expect(state.spaces[2] == SpaceState(windowIDs: ["shared", "right"], focusedWindowID: "right",
                                            widthFractions: ["shared": 0.4]))
    }

    @Test func resumingPreservesMembershipsWhenAWindowIsDiscoveredLate() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["shared", "other"], focusedWindowID: "other",
                       widthFractions: ["shared": 0.6]),
            SpaceState(windowIDs: ["other", "shared"], focusedWindowID: "other",
                       widthFractions: ["shared": 0.4])
        ])
        let spaces = state.spaces
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: nil)
        restoration.reconcile(state: &state, windowIDs: ["other"], trackedWindowIDs: ["shared", "other"])
        state.isPaused = false
        #expect(state.spaces.allSatisfy { !$0.windowIDs.contains("shared") })
        restoration.reconcile(state: &state, windowIDs: ["other", "shared"],
                              trackedWindowIDs: ["shared", "other"])

        #expect(state.spaces == spaces)
    }

    @Test func anotherPauseBeforeDiscoveryKeepsPendingMembershipsAndRecentEdits() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["left", "shared", "right"], focusedWindowID: "left"),
            SpaceState(windowIDs: ["shared"])
        ])
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: nil)
        restoration.reconcile(state: &state, windowIDs: ["left", "right"],
                              trackedWindowIDs: ["left", "shared", "right"])
        state.isPaused = false
        state.setWidthFraction(0.5, for: "left")
        state = restoration.pause(state: state, transitionRollback: nil)
        restoration.reconcile(state: &state, windowIDs: ["right", "shared", "left"],
                              trackedWindowIDs: ["left", "shared", "right"])

        #expect(state.spaces[0].windowIDs == ["left", "shared", "right"])
        #expect(state.spaces[0].widthFraction(for: "left") == 0.5)
        #expect(state.spaces[1].windowIDs == ["shared"])
    }

    @Test func pausingDuringAFailedTransitionRestoresThePreviousLayout() {
        let previous = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["shared", "other"], widthFractions: ["shared": 0.6]),
            SpaceState(windowIDs: ["shared"], widthFractions: ["shared": 0.4])
        ])
        var state = previous
        state.apply(.reorderNext)
        state.apply(.moveToSpace(index: 2, follow: true))
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: previous)
        #expect(state.isPaused)
        restoration.reconcile(state: &state, windowIDs: ["other", "shared"],
                              trackedWindowIDs: ["shared", "other"])
        state.isPaused = false

        #expect(state == previous)
    }

    @Test func restoredMembershipsDoNotUndoLaterChangesAndNewWindowsUseTheActiveSpace() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["shared", "other"], focusedWindowID: "other"),
            SpaceState(windowIDs: ["shared", "late"])
        ])
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: nil)
        restoration.reconcile(state: &state, windowIDs: ["other", "shared"],
                              trackedWindowIDs: ["other", "shared", "late"])
        state.isPaused = false
        state.removeFromCurrentSpace(windowID: "shared")
        state.apply(.goToSpace(index: 1))
        state.setWidthFraction(0.5, for: "shared")
        state.apply(.moveToSpace(index: 2, follow: true))
        restoration.reconcile(state: &state, windowIDs: ["new", "shared", "other", "late"],
                              trackedWindowIDs: ["new", "shared", "other", "late"])

        #expect(state.spaces[0].windowIDs == ["other"])
        #expect(state.spaces[1].windowIDs == ["late"])
        #expect(state.spaces[2].windowIDs == ["shared", "new"])
        #expect(state.spaces[2].widthFraction(for: "shared") == 0.5)
        #expect(state.focusedWindowID == "new")
    }

    @Test func confirmedClosedWindowsLoseTheirSavedMemberships() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["closed", "other"]),
            SpaceState(windowIDs: ["closed"])
        ])
        var restoration = WorkspaceRestoration()
        state = restoration.pause(state: state, transitionRollback: nil)
        restoration.reconcile(state: &state, windowIDs: ["other"], trackedWindowIDs: ["other", "closed"])
        restoration.reconcile(state: &state, windowIDs: ["other"], trackedWindowIDs: ["other"])
        #expect(state.spaces[1].windowIDs.isEmpty)
        // Reopening a registered native window can reuse its ID, but it is a new membership.
        restoration.reconcile(state: &state, windowIDs: ["other", "closed"],
                              trackedWindowIDs: ["other", "closed"])

        #expect(state.spaces[0].windowIDs == ["other", "closed"])
        #expect(state.spaces[1].windowIDs.isEmpty)
    }
}
