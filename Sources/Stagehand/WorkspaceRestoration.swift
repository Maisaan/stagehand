import StagehandCore

/// Retains memberships until a resumed window is discovered or confirmed closed.
struct WorkspaceRestoration {
    private struct PendingMemberships {
        let state: WorkspaceState
        var windowIDs: Set<String>
    }

    private var pending: [PendingMemberships] = []

    mutating func pause(state: WorkspaceState, transitionRollback: WorkspaceState?) -> WorkspaceState {
        var paused = transitionRollback ?? state
        paused.isPaused = true
        var remembered = paused
        for pending in pending {
            // Another pause may happen before a busy window has rejoined.
            remembered.restoreMemberships(windowIDs: pending.windowIDs, from: pending.state)
        }
        pending = [PendingMemberships(
            state: remembered,
            windowIDs: Set(remembered.spaces.flatMap(\.windowIDs))
        )]
        return paused
    }

    mutating func reconcile(state: inout WorkspaceState, windowIDs: [String], trackedWindowIDs: Set<String>) {
        let liveWindowIDs = Set(windowIDs)
        for pending in pending {
            state.restoreMemberships(windowIDs: pending.windowIDs.intersection(windowIDs), from: pending.state)
        }
        let alreadyPending = Set(pending.flatMap(\.windowIDs))
        let newlyUnavailable = Set(state.spaces.flatMap(\.windowIDs))
            .intersection(trackedWindowIDs)
            .subtracting(liveWindowIDs)
            .subtracting(alreadyPending)
        if !newlyUnavailable.isEmpty {
            pending.append(PendingMemberships(state: state, windowIDs: newlyUnavailable))
        }
        state.reconcile(windowIDs: windowIDs)
        for index in pending.indices {
            pending[index].windowIDs.formIntersection(trackedWindowIDs)
            pending[index].windowIDs.subtract(liveWindowIDs)
        }
        // Once restored, subsequent moves, resizes, and membership removals win.
        pending.removeAll { $0.windowIDs.isEmpty }
    }
}
