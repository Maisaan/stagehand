import AppKit
import StagehandCore
import StagehandPlatform

/// A change to the active space's columns, as the stacking shortcuts make them.
enum ColumnChange: Equatable {
    /// The focused window, alone in its column, joins the neighboring column on
    /// that side at the bottom; in a stack, it leaves as its own column on that
    /// side. Focus stays on it.
    case moveFocusedWindowAcrossColumns(direction: Int)
    /// Focus moves to the window above (negative) or below in the same column.
    case focusMember(direction: Int)

    var diagnosticName: String {
        switch self {
        case .moveFocusedWindowAcrossColumns(let direction): direction < 0 ? "stackLeft" : "stackRight"
        case .focusMember(let direction): direction < 0 ? "focusMemberAbove" : "focusMemberBelow"
        }
    }
}

/// Why a column change was not made. A refusal leaves the layout as it was and
/// Stagehand running; it is never a pause.
enum ColumnRefusal: Equatable {
    /// The stack's members cannot all fit in the available height at the least
    /// heights their apps accept.
    case stackDoesNotFit(windowIDs: [String], requiredHeight: CGFloat, availableHeight: CGFloat)
}

enum ColumnChangeOutcome: Equatable {
    case applied
    case unchanged
    case refused(ColumnRefusal)
}

extension StagehandModel {
    /// Queues a column change behind earlier changes. Whether it fits is decided
    /// when it starts; a refusal goes to `onColumnChangeRefused`.
    func changeColumns(_ change: ColumnChange) {
        guard isRunning, !isSuspended else { return }
        if gestureAxis != nil {
            input.cancelGestureSequence()
            resetGestureTracking()
        }
        enqueue(.columns(change))
    }

    /// Makes a column change if every stack it builds fits at its members' known
    /// minimum heights, and otherwise returns the refusal with the workspace
    /// unchanged. The change queue calls this as the change starts.
    func applyColumnChange(_ change: ColumnChange) -> ColumnChangeOutcome {
        var candidate = state
        let changed = switch change {
        case .moveFocusedWindowAcrossColumns(let direction): candidate.moveFocusedWindowAcrossColumns(by: direction)
        case .focusMember(let direction): candidate.focusMember(by: direction)
        }
        guard changed else { return .unchanged }
        if let refusal = stackRefusal(from: state, to: candidate) {
            reportColumnRefusal(refusal, change: change, decided: "before_change")
            return .refused(refusal)
        }
        state = candidate
        return .applied
    }

    // MARK: - Refusal without pausing
    //
    // Every other failed layout rolls back and pauses (finish(_:outcome:)). A stack
    // that does not fit is the user's request meeting app limits, not a failure of
    // Stagehand, so it is refused and Stagehand keeps running. It is decided before
    // the change wherever the minimum heights are already known; a minimum first
    // learned by the change's own layout undoes the change after it.

    /// The first stack in the active space that gained a member between the two
    /// states and cannot fit at its members' known minimum heights.
    func stackRefusal(from previous: WorkspaceState, to next: WorkspaceState) -> ColumnRefusal? {
        guard let availableFrame, previous.spaces.indices.contains(next.activeSpaceIndex) else { return nil }
        let before = previous.spaces[next.activeSpaceIndex]
        for column in next.currentSpace.columns where column.isStack {
            // A column whose members all came from one column gained no one.
            let sources = Set(column.windowIDs.map { before.columnIndex(of: $0) })
            guard sources.count > 1 || sources.contains(nil) else { continue }
            let required = WindowLayout.minimumStackHeight(windowIDs: column.windowIDs, gap: gap,
                                                           minimumHeights: learnedMinimumHeights)
            if required > availableFrame.height + 1 {
                return .stackDoesNotFit(windowIDs: column.windowIDs, requiredHeight: required,
                                        availableHeight: availableFrame.height)
            }
        }
        return nil
    }

    /// After a column change's layout completed: if that layout learned minimum
    /// heights that leave the new stack too tall, return to the columns from before
    /// the change and lay them out again. Windows that left meanwhile stay gone.
    /// Returns whether the change was undone.
    func undoColumnChangeThatDidNotFit(_ change: ColumnChange, stateBefore: WorkspaceState) -> Bool {
        guard let refusal = stackRefusal(from: stateBefore, to: state) else { return false }
        var restored = stateBefore
        restored.isPaused = state.isPaused
        workspaceRestoration.reconcile(state: &restored, windowIDs: windows.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs)
        state = restored
        reportColumnRefusal(refusal, change: change, decided: "after_layout")
        enqueue(.refresh)
        return true
    }

    func reportColumnRefusal(_ refusal: ColumnRefusal, change: ColumnChange, decided: String) {
        switch refusal {
        case .stackDoesNotFit(let windowIDs, let required, let available):
            diagnostics.record("column_change_refused", details: [
                "operation": "columns.\(change.diagnosticName)",
                "reason": "stack_does_not_fit",
                "decided": decided,
                "windowIDs": windowIDs.joined(separator: ","),
                "requiredHeight": String(Double(required)),
                "availableHeight": String(Double(available))
            ])
        }
        onColumnChangeRefused?(refusal)
    }

    // MARK: - Learned minimum heights

    /// Learns from a height a layout asked for and the height the window took. A
    /// taller window than asked has a minimum; a window that took less than its
    /// learned minimum shows that minimum was wrong.
    func noteLayoutHeight(windowID: String, requested: CGFloat, actual: CGFloat) {
        guard requested.isFinite, actual.isFinite, actual > 0 else { return }
        if actual > requested + 1 {
            learnedMinimumHeights[windowID] = max(learnedMinimumHeights[windowID] ?? 0, actual)
        } else {
            forgetMinimumHeight(windowID: windowID, ifAbove: actual)
        }
    }

    func forgetMinimumHeight(windowID: String, ifAbove height: CGFloat) {
        guard let minimum = learnedMinimumHeights[windowID], height.isFinite, height > 0,
              height < minimum - 1 else { return }
        learnedMinimumHeights[windowID] = nil
    }

    // MARK: - Pointer drops and resizes

    /// Applies a title-bar drop of `windowID` at `frame` against the ribbon as it
    /// was laid out before the drag. A window alone in its column moves its column
    /// to where it was dropped. A stacked window dropped within its column's span
    /// moves up or down among its column-mates; dropped outside it, it becomes its
    /// own column there. Never joins a stack.
    func applyWindowDrop(windowID: String, frame: CGRect, placements: [WindowPlacement]) {
        let space = state.currentSpace
        guard let column = space.columnIndex(of: windowID), space.columns[column].isStack else {
            state.reorderWindow(windowID: windowID,
                                to: dropColumnIndex(windowID: windowID, droppedMidX: frame.midX,
                                                    placements: placements, space: space))
            return
        }
        let members = Set(space.columns[column].windowIDs)
        let own = placements.filter { members.contains($0.windowID) }
        guard let minX = own.map(\.frame.minX).min(), let maxX = own.map(\.frame.maxX).max() else { return }
        if (minX...maxX).contains(frame.midX) {
            let position = own.count { $0.windowID != windowID && $0.frame.midY < frame.midY }
            state.reorderMember(windowID: windowID, to: position, inSpace: state.activeSpaceIndex)
        } else {
            state.unstack(windowID: windowID,
                          toColumnAt: dropColumnIndex(windowID: windowID, droppedMidX: frame.midX,
                                                      placements: placements, space: space),
                          inSpace: state.activeSpaceIndex)
        }
    }

    /// Applies a user resize of a stacked window. A width change sets the column's
    /// width. A height change moves the edge the user dragged: the neighbor on that
    /// edge gives or takes the difference, and the other members keep their heights.
    /// The window's own preferred height, which applies when it is alone, is untouched.
    func applyStackedResize(windowID: String, previous: CGRect, observed: CGRect, available: CGRect) {
        if abs(observed.width - previous.width) > 3 {
            state.setWidthFraction(observed.width / available.width, for: windowID)
        }
        forgetMinimumHeight(windowID: windowID, ifAbove: observed.height)
        guard abs(observed.height - previous.height) > 3,
              let column = state.currentSpace.columnIndex(of: windowID),
              let resize = stackResize(column: state.currentSpace.columns[column], windowID: windowID,
                                       previous: previous, observed: observed,
                                       height: { self.knownFrames[$0]?.height },
                                       minimumHeight: { self.learnedMinimumHeights[$0] }) else { return }
        state.setHeightWeight(resize.weight, for: windowID)
        state.setHeightWeight(resize.neighborWeight, for: resize.neighborID)
    }
}

/// The column index a dropped window lands at: the number of other columns whose
/// slot center is left of the window's center. `placements` are the ribbon before
/// the drag; they are grouped into slots by the columns of `space`. A placement
/// of a window `space` no longer holds counts on its own. While every column holds
/// one window, this counts windows exactly as the drop always did.
func dropColumnIndex(windowID: String, droppedMidX: CGFloat, placements: [WindowPlacement],
                     space: SpaceState) -> Int {
    var slots: [Int: (minX: CGFloat, maxX: CGFloat, midX: CGFloat, count: Int)] = [:]
    var loose = 0
    for placement in placements where placement.windowID != windowID {
        guard let column = space.columnIndex(of: placement.windowID) else {
            if placement.frame.midX < droppedMidX { loose += 1 }
            continue
        }
        if let slot = slots[column] {
            slots[column] = (min(slot.minX, placement.frame.minX), max(slot.maxX, placement.frame.maxX),
                             slot.midX, slot.count + 1)
        } else {
            slots[column] = (placement.frame.minX, placement.frame.maxX, placement.frame.midX, 1)
        }
    }
    // A lone window's slot center is its own midX, taken as is so no rounding differs.
    return loose + slots.values.count { ($0.count == 1 ? $0.midX : ($0.minX + $0.maxX) / 2) < droppedMidX }
}

struct StackResize: Equatable {
    let neighborID: String
    let weight: Double
    let neighborWeight: Double
}

/// New height shares after the user resized a stacked window from `previous` to
/// `observed`. The neighbor on the edge that moved (above for a top-edge drag)
/// gives or takes the difference; at the stack's own top or bottom edge, the
/// neighbor on the other side does. The pair keeps its combined share, so the
/// other members keep their heights, and the neighbor keeps at least its known
/// minimum height.
func stackResize(column: ColumnState, windowID: String, previous: CGRect, observed: CGRect,
                 height: (String) -> CGFloat?, minimumHeight: (String) -> CGFloat?) -> StackResize? {
    guard column.isStack, let index = column.windowIDs.firstIndex(of: windowID),
          previous.height.isFinite, previous.height > 0,
          observed.height.isFinite, observed.height > 0 else { return nil }
    let topMoved = abs(observed.minY - previous.minY) > 3
    let bottomMoved = abs(observed.maxY - previous.maxY) > 3
    let above = index > 0 ? index - 1 : nil
    let below = index + 1 < column.windowIDs.count ? index + 1 : nil
    guard let neighbor = topMoved && !bottomMoved ? above ?? below : below ?? above else { return nil }
    let neighborID = column.windowIDs[neighbor]
    guard let neighborHeight = height(neighborID), neighborHeight.isFinite, neighborHeight > 0 else { return nil }
    let total = previous.height + neighborHeight
    let neighborFloor = max(1, minimumHeight(neighborID).flatMap { $0.isFinite ? $0 : nil } ?? 0)
    let memberHeight = min(observed.height, total - neighborFloor)
    guard memberHeight > 0 else { return nil }
    let pair = column.heightWeights[index] + column.heightWeights[neighbor]
    let share = Double(memberHeight / total)
    return StackResize(neighborID: neighborID, weight: pair * share, neighborWeight: pair * (1 - share))
}
