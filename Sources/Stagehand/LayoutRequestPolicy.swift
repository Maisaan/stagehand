import StagehandCore
import StagehandPlatform

enum FocusConfirmation: Equatable {
    case focused
    /// The target was minimized or closed without a notification. Navigation
    /// should drop it like any other unavailable window instead of pausing.
    case unavailable(WindowUnavailability)
    case failed
}

@MainActor
enum LayoutRequestPolicy: Equatable {
    case navigation
    case preferences

    func beginInputTransfer(using begin: () -> UInt64?) -> UInt64? {
        self == .navigation ? begin() : nil
    }

    func prepare(state: WorkspaceState, focusedWindowID: String?) -> WorkspaceState? {
        guard self == .preferences else { return state }
        guard let focusedWindowID else { return nil }
        var state = state
        if !state.currentSpace.windowIDs.contains(focusedWindowID) {
            guard let space = state.spaces.firstIndex(where: { $0.windowIDs.contains(focusedWindowID) }) else { return nil }
            state.apply(.goToSpace(index: space))
        }
        state.focus(windowID: focusedWindowID)
        return state
    }

    /// `mayHoldFocus` answers, without an Accessibility call, whether the window's
    /// app is frontmost. `currentFocus` is a synchronous read from the focused app,
    /// which is busy at both points it would be asked, so it is skipped when the
    /// answer is already no.
    func confirmFocus(
        windowID: String,
        currentFocus: () -> String?,
        activate: () async -> Bool,
        unavailability: () -> WindowUnavailability? = { nil },
        isParked: () -> Bool = { false },
        mayHoldFocus: () -> Bool = { true }
    ) async -> FocusConfirmation {
        guard self == .navigation else { return currentFocus() == windowID ? .focused : .failed }
        // A visible window that already holds focus needs no activation.
        // Re-activating its app costs AX round trips on every refresh and takes
        // key status away from a panel another process has just presented for
        // it, such as a system authentication prompt. A window still parked
        // goes through activation, whose restore retries bring it back.
        if !isParked(), mayHoldFocus(), currentFocus() == windowID { return .focused }
        if await activate() || (mayHoldFocus() && currentFocus() == windowID) { return .focused }
        return unavailability().map(FocusConfirmation.unavailable) ?? .failed
    }
}
