import Testing
@testable import Stagehand

@MainActor
@Test func navigationTrustsExactObservedFocusWhenActivationReportsFailure() async {
    let accepted = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "target" },
        activate: { false }
    )
    let rejected = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "other" },
        activate: { false }
    )

    #expect(accepted)
    #expect(!rejected)
}
