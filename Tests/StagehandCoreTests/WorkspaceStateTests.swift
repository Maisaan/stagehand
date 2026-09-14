import Foundation
import Testing
@testable import StagehandCore

@Test func sharedWindowsHaveIndependentOrderAndWidth() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["t3", "browser", "terminal"])
    state.focus(windowID: "t3")
    state.setWidthFraction(0.7, for: "t3")
    #expect(state.apply(.shareToSpace(index: 1)) == true)
    state.apply(.goToSpace(index: 1))
    state.reconcile(windowIDs: ["t3", "browser", "terminal", "notes"])
    state.focus(windowID: "t3")
    state.apply(.reorderNext)
    state.setWidthFraction(0.4, for: "t3")

    #expect(state.spaces[0].windowIDs == ["t3", "browser", "terminal"])
    #expect(state.spaces[1].windowIDs == ["notes", "t3"])
    #expect(state.spaces[0].widthFraction(for: "t3") == 0.7)
    #expect(state.spaces[1].widthFraction(for: "t3") == 0.4)
    #expect(state.apply(.shareToSpace(index: 0)) == false)
}

@Test func reconcileDoesNotRestoreMovedWindowsAndDeletesAllClosedMemberships() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c"])
    state.focus(windowID: "b")
    state.apply(.moveToSpace(index: 1, follow: false))
    state.reconcile(windowIDs: ["a", "b", "c", "d"])
    #expect(state.currentSpace.windowIDs == ["a", "c", "d"])
    #expect(state.focusedWindowID == "d")
    #expect(state.spaces[1].windowIDs == ["b"])

    state.focus(windowID: "a")
    state.apply(.shareToSpace(index: 1))
    state.reconcile(windowIDs: ["b", "c", "d"])
    #expect(state.spaces.allSatisfy { !$0.windowIDs.contains("a") })
    #expect(state.spaces.allSatisfy { $0.widthFractions["a"] == nil })
    #expect(state.focusedWindowID == "c")
}

@Test func newWindowsAreInsertedAfterFocusAndRepeatedReconcileIsStable() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c"])
    state.focus(windowID: "a")
    state.reconcile(windowIDs: ["a", "b", "c", "new", "new", ""])
    #expect(state.currentSpace.windowIDs == ["a", "new", "b", "c"])
    #expect(state.focusedWindowID == "new")
    let snapshot = state
    state.reconcile(windowIDs: ["c", "new", "a", "b"])
    #expect(state == snapshot)
}

@Test func navigationStopsAtBoundariesAndRemembersFocus() {
    var state = WorkspaceState()
    #expect(state.apply(.previousSpace) == false)
    #expect(state.apply(.focusNext) == false)
    state.reconcile(windowIDs: ["a", "b"])
    #expect(state.apply(.focusNext) == false)
    #expect(state.apply(.reorderNext) == false)
    #expect(state.apply(.focusPrevious) == true)
    #expect(state.apply(.focusPrevious) == false)
    state.apply(.goToSpace(index: 8))
    #expect(state.apply(.nextSpace) == false)
    #expect(state.apply(.goToSpace(index: -1)) == false)
    #expect(state.apply(.goToSpace(index: 9)) == false)
    state.apply(.goToSpace(index: 0))
    #expect(state.focusedWindowID == "a")
}

@Test func movingAndFollowingPreservesWidthAndSelectsMovedWindow() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b"])
    state.setWidthFraction(0.5, for: "b")
    #expect(state.apply(.moveToSpace(index: 2, follow: true)) == true)
    #expect(state.activeSpaceIndex == 2)
    #expect(state.focusedWindowID == "b")
    #expect(state.currentSpace.widthFraction(for: "b") == 0.5)
    #expect(state.spaces[0].windowIDs == ["a"])
    #expect(state.spaces[0].focusedWindowID == "a")
}

@Test func movingToExistingMembershipPreservesDestinationOrderAndWidth() {
    var state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b"], focusedWindowID: "a", widthFractions: ["a": 0.5]),
        SpaceState(windowIDs: ["c", "a", "d"], focusedWindowID: "c", widthFractions: ["a": 0.8])
    ])
    state.apply(.moveToSpace(index: 1, follow: false))
    #expect(state.spaces[0].windowIDs == ["b"])
    #expect(state.spaces[1].windowIDs == ["c", "a", "d"])
    #expect(state.spaces[1].focusedWindowID == "c")
    #expect(state.spaces[1].widthFraction(for: "a") == 0.8)
}

@Test func removingMembershipDoesNotOrphanWindow() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a"])
    #expect(state.removeFromCurrentSpace(windowID: "a") == false)
    state.apply(.shareToSpace(index: 1))
    #expect(state.removeFromCurrentSpace(windowID: "a") == true)
    #expect(state.currentSpace.windowIDs.isEmpty)
    #expect(state.focusedWindowID == nil)
    state.reconcile(windowIDs: ["a"])
    #expect(state.currentSpace.windowIDs.isEmpty)
    #expect(state.spaces[1].windowIDs == ["a"])
}

@Test func widthsAreClampedAndSurviveModeChanges() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a"])
    #expect(state.apply(.growWidth) == false)
    for _ in 0..<30 { state.apply(.shrinkWidth) }
    #expect(state.currentSpace.widthFraction(for: "a") == 0.25)
    #expect(state.apply(.shrinkWidth) == false)
    state.apply(.growWidth)
    #expect(state.currentSpace.widthFraction(for: "a") == 0.3)
    state.layoutMode = .monocle
    #expect(state.apply(.growWidth) == false)
    state.layoutMode = .scrolling
    #expect(state.currentSpace.widthFraction(for: "a") == 0.3)
    state.setWidthFraction(.infinity, for: "a")
    #expect(state.currentSpace.widthFraction(for: "a") == 0.95)
    state.setWidthFraction(-10, for: "a")
    #expect(state.currentSpace.widthFraction(for: "a") == 0.25)
}

@Test func persistenceRoundTripsAndSanitizesInvalidState() throws {
    var original = WorkspaceState()
    original.reconcile(windowIDs: ["a", "b"])
    original.apply(.shareToSpace(index: 4))
    original.apply(.goToSpace(index: 4))
    let data = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == original)

    let invalid = Data(#"{"activeSpaceIndex":100,"spaces":[{"windowIDs":["a","a","","b"],"focusedWindowID":"missing","widthFractions":{"a":4,"b":-1,"missing":0.5}}]}"#.utf8)
    let restored = try JSONDecoder().decode(WorkspaceState.self, from: invalid)
    #expect(restored.spaces.count == 9)
    #expect(restored.activeSpaceIndex == 8)
    #expect(restored.spaces[0].windowIDs == ["a", "b"])
    #expect(restored.spaces[0].focusedWindowID == "a")
    #expect(restored.spaces[0].widthFractions == ["a": 0.95, "b": 0.25])
}
