import StagehandCore

/// Owns everything needed to undo or resume a layout: memberships of windows that
/// are temporarily unavailable, and the layout before an in-flight transition.
/// They are kept together because compaction rewrites both.
struct WorkspaceRestoration {
    private struct PendingMemberships {
        var state: WorkspaceState
        var windowIDs: Set<String>
    }

    private struct Transition {
        let state: WorkspaceState
        let pending: [PendingMemberships]
    }

    private var pending: [PendingMemberships] = []
    private var transition: Transition?

    var isInTransition: Bool { transition != nil }

    /// Records the layout to return to if the next transition fails. A transition
    /// already in progress keeps its original starting point.
    mutating func beginTransition(from state: WorkspaceState) {
        if transition == nil { transition = Transition(state: state, pending: pending) }
    }

    mutating func endTransition() {
        transition = nil
    }

    /// The transition's starting layout, reconciled with windows that changed since.
    func transitionStart(windowIDs: [String], trackedWindowIDs: Set<String>) -> WorkspaceState? {
        var copy = self
        var state = WorkspaceState()
        return copy.rollBack(state: &state, windowIDs: windowIDs, trackedWindowIDs: trackedWindowIDs)
            ? state : nil
    }

    /// Restores the layout from before the current transition. Windows that closed,
    /// became unavailable, or appeared meanwhile are reconciled against it.
    @discardableResult
    mutating func rollBack(state: inout WorkspaceState, windowIDs: [String],
                           trackedWindowIDs: Set<String>) -> Bool {
        guard let transition else { return false }
        self.transition = nil
        let isPaused = state.isPaused
        state = transition.state
        state.isPaused = isPaused
        pending = transition.pending
        reconcile(state: &state, windowIDs: windowIDs, trackedWindowIDs: trackedWindowIDs)
        return true
    }

    mutating func pause(state: WorkspaceState, windowIDs: [String],
                        trackedWindowIDs: Set<String>) -> WorkspaceState {
        var paused = state
        rollBack(state: &paused, windowIDs: windowIDs, trackedWindowIDs: trackedWindowIDs)
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
