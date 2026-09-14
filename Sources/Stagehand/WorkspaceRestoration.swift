import StagehandCore

/// Retains memberships until a resumed window is discovered or confirmed closed.
struct WorkspaceRestoration {
    private var pending: (state: WorkspaceState, windowIDs: Set<String>)?

    mutating func pause(state: WorkspaceState, transitionRollback: WorkspaceState?) -> WorkspaceState {
        var paused = transitionRollback ?? state
        paused.isPaused = true
        var remembered = paused
        if let pending {
            // Another pause may happen before a busy window has rejoined.
            remembered.restoreMemberships(windowIDs: pending.windowIDs, from: pending.state)
        }
        pending = (remembered, Set(remembered.spaces.flatMap(\.windowIDs)))
        return paused
    }

    mutating func reconcile(state: inout WorkspaceState, windowIDs: [String], trackedWindowIDs: Set<String>) {
        if let pending {
            state.restoreMemberships(windowIDs: pending.windowIDs.intersection(windowIDs), from: pending.state)
        }
        state.reconcile(windowIDs: windowIDs)
        guard var remaining = pending else { return }
        remaining.windowIDs.formIntersection(trackedWindowIDs)
        remaining.windowIDs.subtract(windowIDs)
        // Once restored, subsequent moves, resizes, and membership removals win.
        pending = remaining.windowIDs.isEmpty ? nil : remaining
    }
}
