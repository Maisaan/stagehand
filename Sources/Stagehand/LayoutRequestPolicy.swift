import StagehandCore

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

    func confirmFocus(windowID: String, currentFocus: () -> String?, activate: () async -> Bool) async -> Bool {
        if self == .navigation { return await activate() }
        return currentFocus() == windowID
    }
}
