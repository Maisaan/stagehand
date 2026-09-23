import StagehandCore
import Testing
@testable import Stagehand

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
