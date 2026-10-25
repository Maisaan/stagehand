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

/// 2026-10-12T07:22:57Z: a refresh re-activated an already focused window while
/// the system was presenting an authentication panel for it.
@MainActor
@Test func navigationDoesNotActivateAWindowThatAlreadyHoldsFocus() async {
    var activations = 0
    let outcome = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "target" },
        activate: { activations += 1; return true }
    )
    #expect(outcome == .focused)
    #expect(activations == 0)
    // A parked window that still reads as focused needs activation's restore retries.
    let parked = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { "target" },
        activate: { activations += 1; return true },
        isParked: { true }
    )
    #expect(parked == .focused)
    #expect(activations == 1)
}

/// 2026-10-25: the focus read before activation waited on the app being left,
/// on the main thread, although AppKit already said the destination's app was
/// not frontmost and so could not hold focus.
@MainActor
@Test func navigationDoesNotReadFocusWhenTheDestinationAppIsNotFrontmost() async {
    var focusReads = 0
    let activated = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { focusReads += 1; return "other" },
        activate: { true },
        mayHoldFocus: { false }
    )
    #expect(activated == .focused)
    #expect(focusReads == 0)
    // A refused activation still fails without a read when the app is not frontmost.
    let refused = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { focusReads += 1; return "other" },
        activate: { false },
        mayHoldFocus: { false }
    )
    #expect(refused == .failed)
    #expect(focusReads == 0)
    // Once the app is frontmost, the read decides as before.
    let alreadyFocused = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "target",
        currentFocus: { focusReads += 1; return "target" },
        activate: { false },
        mayHoldFocus: { true }
    )
    #expect(alreadyFocused == .focused)
    #expect(focusReads == 1)
}
