import Foundation
import Testing

@Test func closingTheLastWindowLeavesItsSpaceAndPreservesOtherSpaceNumbers() {
    var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a"]), SpaceState(),
                                       SpaceState(windowIDs: ["closing"]), SpaceState(windowIDs: ["b"])], activeSpaceIndex: 2)
    state.reconcile(windowIDs: ["a", "b"])
    #expect(state.activeSpaceIndex == 0)
    #expect(state.focusedWindowID == "a")
    #expect(state.displayedSpaceIndices == [0, 3])
    #expect(state.spaces[3].windowIDs == ["b"])
    #expect(state.apply(.nextSpace) == true)
    #expect(state.activeSpaceIndex == 3)
    #expect(state.apply(.previousSpace) == true)
    #expect(state.activeSpaceIndex == 0)
}

@Test func closingFirstOccupiedSpaceFallsForwardAndClosingAllWindowsKeepsOneEmptySpace() {
    var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["closing"]), SpaceState(), SpaceState(windowIDs: ["b"])])
    state.reconcile(windowIDs: ["b"])
    #expect(state.activeSpaceIndex == 2)
    state.reconcile(windowIDs: [])
    #expect(state.activeSpaceIndex == 0)
    #expect(state.displayedSpaceIndices == [0])
    #expect(state.currentSpace.windowIDs.isEmpty)
}

@Test func replacementWindowAndIntentionallyEmptySpaceDoNotTriggerSpaceClosure() {
    var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a"]), SpaceState(windowIDs: ["closing"])], activeSpaceIndex: 1)
    state.reconcile(windowIDs: ["a", "replacement"])
    #expect(state.activeSpaceIndex == 1)
    #expect(state.focusedWindowID == "replacement")
    state.apply(.goToSpace(index: 5))
    state.reconcile(windowIDs: ["a", "replacement"])
    #expect(state.activeSpaceIndex == 5)
}
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

@Test func aSpecificWindowCanBeSharedWithoutChangingFocus() {
    var state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["focused", "other"], focusedWindowID: "focused",
                   widthFractions: ["other": 0.6]),
        SpaceState()
    ])

    let shared = state.share(windowID: "other", toSpace: 1)
    #expect(shared)
    #expect(state.spaces[1].windowIDs == ["other"])
    #expect(state.spaces[1].widthFraction(for: "other") == 0.6)
    #expect(state.focusedWindowID == "focused")
    let sharedMissing = state.share(windowID: "missing", toSpace: 1)
    let sharedAgain = state.share(windowID: "other", toSpace: 1)
    #expect(!sharedMissing)
    #expect(!sharedAgain)
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

@Test func widthCommandsPreserveRememberedWidthsWhileMaximized() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a"])
    #expect(state.apply(.growWidth) == false)
    for _ in 0..<30 { state.apply(.shrinkWidth) }
    #expect(state.currentSpace.widthFraction(for: "a") == 0.25)
    #expect(state.apply(.shrinkWidth) == false)
    state.apply(.growWidth)
    #expect(state.currentSpace.widthFraction(for: "a") == 0.3)
    state.maximizeWindows = true
    #expect(state.currentSpace.widthFraction(for: "a") == 0.3)
    #expect(state.apply(.shrinkWidth) == false)
    #expect(state.apply(.growWidth) == false)
    state.maximizeWindows = false
    #expect(state.currentSpace.widthFraction(for: "a") == 0.3)
    state.setWidthFraction(.infinity, for: "a")
    #expect(state.currentSpace.widthFraction(for: "a") == 0.95)
    #expect(state.apply(.growWidth) == false)
    state.setWidthFraction(-10, for: "a")
    #expect(state.currentSpace.widthFraction(for: "a") == 0.25)
}

@Test func maximizeTogglePreservesEverySpaceOrderFocusAndIndividualWidth() {
    var state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b"], focusedWindowID: "a", widthFractions: ["a": 0.95, "b": 0.5]),
        SpaceState(windowIDs: ["b", "a"], focusedWindowID: "b", widthFractions: ["a": 0.8, "b": 0.95])
    ])
    let spaces = state.spaces
    state.maximizeWindows = true
    #expect(state.spaces == spaces)
    state.apply(.goToSpace(index: 1))
    state.maximizeWindows = false
    #expect(state.spaces == spaces)
}

@Test func newWindowsRememberTheirIndividualWidthEvenWhenAddedWhileMaximized() {
    var state = WorkspaceState(maximizeWindows: true)
    state.reconcile(windowIDs: ["a"])
    #expect(state.currentSpace.widthFraction(for: "a") == 0.95)
    state.maximizeWindows = false
    state.reconcile(windowIDs: ["a", "b"])
    #expect(state.currentSpace.widthFraction(for: "b") == 0.95)
    state.setWidthFraction(2, for: "b")
    #expect(state.currentSpace.widthFraction(for: "b") == 0.95)
}

@Test func persistedLegacyLayoutsMigrateToOneRibbon() throws {
    let legacy = Data(#"{"layoutMode":"monocle","spaces":[{"windowIDs":["a","b"],"widthFractions":{"a":0.95,"b":0.5}}]}"#.utf8)
    let state = try JSONDecoder().decode(WorkspaceState.self, from: legacy)
    #expect(state.maximizeWindows)
    #expect(state.currentSpace.widthFraction(for: "a") == 0.95)
    #expect(state.currentSpace.widthFraction(for: "b") == 0.5)
    let saved = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(WorkspaceState.self, from: saved) == state)
    let payload = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(payload["layoutMode"] == nil)
    #expect(payload["maximumWidthFraction"] == nil)
    #expect(payload["maximizeWindows"] as? Bool == true)
    let scrolling = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"layoutMode":"scrolling"}"#.utf8))
    #expect(!scrolling.maximizeWindows)
    let interim = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"maximumWidthFraction":1}"#.utf8))
    #expect(interim.maximizeWindows)
    let explicit = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"maximizeWindows":false,"layoutMode":"monocle"}"#.utf8))
    #expect(!explicit.maximizeWindows)
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

@Test func displayedSpacesContainOnlyOccupiedSpacesAndTheActiveSpace() {
    var state = WorkspaceState()
    #expect(state.displayedSpaceIndices == [0])
    state.reconcile(windowIDs: ["a"])
    state.apply(.shareToSpace(index: 4))
    #expect(state.displayedSpaceIndices == [0, 4])
    state.apply(.goToSpace(index: 8))
    #expect(state.displayedSpaceIndices == [0, 4, 8])
    state.reconcile(windowIDs: [])
    #expect(state.displayedSpaceIndices == [8])
    #expect(state.spaces.count == 9)
    state.apply(.goToSpace(index: 2))
    #expect(state.activeSpaceIndex == 2)
    #expect(state.displayedSpaceIndices == [2])
}

@Test func droppedWindowMovesToFinalIndexWithoutChangingFocusWidthsOrOtherSpaces() {
    var state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b", "c", "d"], focusedWindowID: "b",
                   widthFractions: ["a": 0.3, "b": 0.5, "c": 0.7, "d": 0.95]),
        SpaceState(windowIDs: ["c", "a", "b"], focusedWindowID: "c",
                   widthFractions: ["a": 0.8, "b": 0.4, "c": 0.6])
    ])
    let widths = state.currentSpace.widthFractions
    let otherSpaces = Array(state.spaces.dropFirst())

    #expect(state.reorderWindow(windowID: "b", to: 3) == true)
    #expect(state.currentSpace.windowIDs == ["a", "c", "d", "b"])
    #expect(state.focusedWindowID == "b")
    #expect(state.reorderWindow(windowID: "d", to: 0) == true)
    #expect(state.currentSpace.windowIDs == ["d", "a", "c", "b"])
    #expect(state.focusedWindowID == "b")
    #expect(state.currentSpace.widthFractions == widths)
    #expect(Array(state.spaces.dropFirst()) == otherSpaces)
}

@Test func droppedWindowClampsIndexAndIgnoresUnknownOrUnchangedTargets() {
    var state = WorkspaceState()
    #expect(state.reorderWindow(windowID: "missing", to: 0) == false)
    state.reconcile(windowIDs: ["a", "b", "c"])
    #expect(state.reorderWindow(windowID: "b", to: .max) == true)
    #expect(state.currentSpace.windowIDs == ["a", "c", "b"])
    #expect(state.reorderWindow(windowID: "b", to: .min) == true)
    #expect(state.currentSpace.windowIDs == ["b", "a", "c"])

    let snapshot = state
    #expect(state.reorderWindow(windowID: "missing", to: 1) == false)
    #expect(state.reorderWindow(windowID: "b", to: 0) == false)
    #expect(state == snapshot)

    state.apply(.goToSpace(index: 1))
    #expect(state.reorderWindow(windowID: "b", to: 0) == false)
    #expect(state.currentSpace.windowIDs.isEmpty)
    #expect(state.spaces[0] == snapshot.spaces[0])
}
