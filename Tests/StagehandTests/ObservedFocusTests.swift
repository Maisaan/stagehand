import StagehandCore
import Testing
@testable import Stagehand

@Test func newlyDiscoveredOrReturningWindowFollowsVerifiedSystemFocus() {
    #expect(shouldFollowObservedFocus(
        observedWindowID: "returning-window",
        discoveredWindowIDs: ["returning-window", "neighbor"]
    ))
    #expect(shouldFollowObservedFocus(
        observedWindowID: "never-managed-window",
        discoveredWindowIDs: ["returning-window", "never-managed-window"]
    ))
    #expect(!shouldFollowObservedFocus(
        observedWindowID: "background-window",
        discoveredWindowIDs: ["returning-window", "never-managed-window"]
    ))
}

@MainActor
@Test func staleFocusNotificationDoesNotPrepareALayout() throws {
    let state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["current", "transient"], focusedWindowID: "current")
    ])

    #expect(prepareObservedFocus(
        state: state,
        notificationWindowID: "transient",
        focusedWindowID: "current"
    ) == nil)

    let prepared = try #require(prepareObservedFocus(
        state: state,
        notificationWindowID: "transient",
        focusedWindowID: "transient"
    ))
    #expect(prepared.focusedWindowID == "transient")
}
