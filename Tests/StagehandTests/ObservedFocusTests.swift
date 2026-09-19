import Testing
@testable import Stagehand

@Test func temporarilyUnavailableKnownWindowRetainsObservedFocus() {
    #expect(shouldFollowObservedFocus(
        hasNewWindows: true,
        observedWindowID: "returning-window",
        previouslyKnownWindowIDs: ["returning-window", "neighbor"]
    ))
    #expect(!shouldFollowObservedFocus(
        hasNewWindows: true,
        observedWindowID: "never-managed-window",
        previouslyKnownWindowIDs: ["returning-window", "neighbor"]
    ))
}
