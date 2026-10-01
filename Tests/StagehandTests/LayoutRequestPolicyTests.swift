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

    #expect(accepted == .focused)
    #expect(rejected == .failed)
}

/// 2026-10-01T01:53:56Z: a parked window was minimized without an AX
/// notification, so navigating to it paused Stagehand.
@MainActor
@Test func navigationReportsATargetThatBecameUnavailableInsteadOfFailing() async {
    let minimized = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "other" },
        activate: { false },
        unavailability: { .minimized }
    )
    // A live window that refuses focus must still fail and pause.
    let refused = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "other" },
        activate: { false },
        unavailability: { nil }
    )
    // Availability is irrelevant once focus is confirmed.
    let focused = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "other" },
        activate: { true },
        unavailability: { .closed }
    )

    #expect(minimized == .unavailable(.minimized))
    #expect(refused == .failed)
    #expect(focused == .focused)
}
