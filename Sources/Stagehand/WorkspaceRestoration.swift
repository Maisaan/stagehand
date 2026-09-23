import StagehandCore

/// Retains memberships until a resumed window is discovered or confirmed closed.
struct WorkspaceRestoration {
    private struct PendingMemberships {
        var state: WorkspaceState
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

    mutating func reconcile(
        state: inout WorkspaceState,
        windowIDs: [String],
        trackedWindowIDs: Set<String>,
        initialWidthFractions: [String: Double] = [:]
    ) {
        let liveWindowIDs = Set(windowIDs)
        let previousActiveSpaceIndex = state.activeSpaceIndex
        let closedIDs = Set(state.spaces.flatMap(\.windowIDs))
            .union(pending.flatMap(\.windowIDs))
            .subtracting(trackedWindowIDs)
        let closingSpaces = state.spaces.indices.filter { index in
            state.spaces[index].windowIDs.contains(where: closedIDs.contains)
                || pending.contains { $0.state.spaces[index].windowIDs.contains(where: closedIDs.contains) }
        }
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
        state.reconcile(windowIDs: windowIDs, initialWidthFractions: initialWidthFractions)
        for index in pending.indices {
            pending[index].windowIDs.formIntersection(trackedWindowIDs)
            pending[index].windowIDs.subtract(liveWindowIDs)
        }
        // Once restored, subsequent moves, resizes, and membership removals win.
        pending.removeAll { $0.windowIDs.isEmpty }
        for index in closingSpaces.reversed() {
            if compactEmptySpace(state: &state, at: index), index == previousActiveSpaceIndex,
               let successor = state.spaces[index].focusedWindowID {
                state.focus(windowID: successor, inSpace: index)
            }
        }
    }

    @discardableResult
    mutating func compactEmptySpace(state: inout WorkspaceState, at index: Int) -> Bool {
        guard state.spaces.indices.contains(index), state.spaces[index].windowIDs.isEmpty,
              !pending.contains(where: { memberships in
            memberships.windowIDs.contains { memberships.state.spaces[index].windowIDs.contains($0) }
        }) else { return false }
        let hasPendingSuccessor = pending.contains { memberships in
            ((index + 1)..<WorkspaceState.spaceCount).contains { laterIndex in
                memberships.windowIDs.contains {
                    memberships.state.spaces[laterIndex].windowIDs.contains($0)
                }
            }
        }
        if hasPendingSuccessor {
            state.discardSpace(at: index)
        } else if !state.closeEmptySpace(at: index) {
            return false
        }
        for pendingIndex in pending.indices {
            pending[pendingIndex].state.discardSpace(at: index)
        }
        return true
    }
}
