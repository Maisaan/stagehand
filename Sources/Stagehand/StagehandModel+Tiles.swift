import AppKit
import StagehandCore
import StagehandPlatform

/// A change to the active space's tiles, as the stacking shortcuts make them.
enum TileChange: Equatable {
    /// The focused window, alone in its tile, joins the neighboring tile on
    /// that side at the bottom; in a stack, it leaves as its own tile on that
    /// side. Focus stays on it.
    case moveFocusedWindowAcrossTiles(direction: Int)
    /// Focus moves to the window above (negative) or below in the same tile.
    case focusMember(direction: Int)

    var diagnosticName: String {
        switch self {
        case .moveFocusedWindowAcrossTiles(let direction): direction < 0 ? "stackLeft" : "stackRight"
        case .focusMember(let direction): direction < 0 ? "focusMemberAbove" : "focusMemberBelow"
        }
    }

    /// The tile change a stacking shortcut or arrow shortcut swipe asks for.
    init?(_ action: NavigationAction) {
        switch action {
        case .stackPrevious: self = .moveFocusedWindowAcrossTiles(direction: -1)
        case .stackNext: self = .moveFocusedWindowAcrossTiles(direction: 1)
        case .focusMemberAbove: self = .focusMember(direction: -1)
        case .focusMemberBelow: self = .focusMember(direction: 1)
        default: return nil
        }
    }
}

/// Why a tile change was not made. A refusal leaves the layout as it was and
/// Stagehand running; it is never a pause.
enum TileRefusal: Equatable {
    /// The stack's members cannot all fit in the available height at the least
    /// heights their apps accept.
    case stackDoesNotFit(windowIDs: [String], requiredHeight: CGFloat, availableHeight: CGFloat)
}

enum TileChangeOutcome: Equatable {
    case applied
    case unchanged
    case refused(TileRefusal)
}

extension StagehandModel {
    /// Queues a tile change behind earlier changes. Whether it fits is decided
    /// when it starts; a refusal goes to `onTileChangeRefused`.
    func changeTiles(_ change: TileChange) {
        guard isRunning, !isSuspended else { return }
        if gestureAxis != nil {
            input.cancelGestureSequence()
            resetGestureTracking()
        }
        enqueue(.tiles(change))
    }

    /// Makes a tile change if every stack it builds fits at its members' known
    /// minimum heights, and otherwise returns the refusal with the workspace
    /// unchanged. The change queue calls this as the change starts.
    func applyTileChange(_ change: TileChange) -> TileChangeOutcome {
        var candidate = state
        let changed = switch change {
        case .moveFocusedWindowAcrossTiles(let direction): candidate.moveFocusedWindowAcrossTiles(by: direction)
        case .focusMember(let direction): candidate.focusPane(direction: direction < 0 ? .up : .down)
        }
        guard changed else { return .unchanged }
        if let refusal = stackRefusal(from: state, to: candidate) {
            reportTileRefusal(refusal, change: change, decided: "before_change")
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
    func stackRefusal(from previous: WorkspaceState, to next: WorkspaceState) -> TileRefusal? {
        guard let availableFrame, previous.spaces.indices.contains(next.activeSpaceIndex) else { return nil }
        let before = previous.spaces[next.activeSpaceIndex]
        for tile in next.currentSpace.tiles where tile.isMultiPane {
            // A tile whose members all came from one tile gained no one.
            let sources = Set(tile.windowIDs.map { before.tileIndex(of: $0) })
            guard sources.count > 1 || sources.contains(nil) else { continue }
            let required = WindowLayout.minimumTileSize(tile, paneGap: gap, minimumWidths: [:],
                                                        minimumHeights: learnedMinimumHeights).height
            if required > availableFrame.height + 1 {
                return .stackDoesNotFit(windowIDs: tile.windowIDs, requiredHeight: required,
                                        availableHeight: availableFrame.height)
            }
        }
        return nil
    }

    /// After a tile change's layout completed: if that layout learned minimum
    /// heights that leave the new stack too tall, return to the tiles from before
    /// the change and lay them out again. Windows that left meanwhile stay gone.
    /// Returns whether the change was undone.
    func undoTileChangeThatDidNotFit(_ change: TileChange, stateBefore: WorkspaceState) -> Bool {
        guard let refusal = stackRefusal(from: stateBefore, to: state) else { return false }
        var restored = stateBefore
        restored.isPaused = state.isPaused
        workspaceRestoration.reconcile(state: &restored, windowIDs: windows.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs)
        state = restored
        reportTileRefusal(refusal, change: change, decided: "after_layout")
        enqueue(.refresh)
        return true
    }

    func reportTileRefusal(_ refusal: TileRefusal, change: TileChange, decided: String) {
        switch refusal {
        case .stackDoesNotFit(let windowIDs, let required, let available):
            diagnostics.record("tile_change_refused", details: [
                "operation": "tiles.\(change.diagnosticName)",
                "reason": "stack_does_not_fit",
                "decided": decided,
                "windowIDs": windowIDs.joined(separator: ","),
                "requiredHeight": String(Double(required)),
                "availableHeight": String(Double(available))
            ])
        }
        onTileChangeRefused?(refusal)
    }

    /// The short message for a refusal. It names no app or window: it shows on
    /// screen while the user is looking at those windows.
    static func message(for refusal: TileRefusal) -> String {
        switch refusal {
        case .stackDoesNotFit:
            "Not stacked: these windows can't get short enough to fit one above the other."
        }
    }

    /// The default `onTileChangeRefused`: a brief note in the app bar, which never
    /// takes focus. Stagehand keeps running and the layout stays as it was.
    func showTileRefusal(_ refusal: TileRefusal) {
        overlays.showNotice(Self.message(for: refusal))
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
    /// was laid out before the drag. A window alone in its tile moves its tile
    /// to where it was dropped. A stacked window dropped within its tile's span
    /// moves up or down among its tile-mates; dropped outside it, it becomes its
    /// own tile there. Never joins a stack.
    func applyWindowDrop(windowID: String, frame: CGRect, placements: [WindowPlacement]) {
        let space = state.currentSpace
        guard let tile = space.tileIndex(of: windowID), space.tiles[tile].isMultiPane else {
            state.reorderWindow(windowID: windowID,
                                to: dropTileIndex(windowID: windowID, droppedMidX: frame.midX,
                                                  placements: placements, space: space))
            return
        }
        let members = Set(space.tiles[tile].windowIDs)
        let own = placements.filter { members.contains($0.windowID) }
        guard let minX = own.map(\.frame.minX).min(), let maxX = own.map(\.frame.maxX).max() else { return }
        if (minX...maxX).contains(frame.midX) {
            let position = own.count { $0.windowID != windowID && $0.frame.midY < frame.midY }
            state.reorderPane(windowID: windowID, to: position, inSpace: state.activeSpaceIndex)
        } else {
            state.expel(windowID: windowID,
                        toTileAt: dropTileIndex(windowID: windowID, droppedMidX: frame.midX,
                                                placements: placements, space: space),
                        inSpace: state.activeSpaceIndex)
        }
    }

    /// Applies a user resize of a stacked window. A width change sets the tile's
    /// width. A height change moves the edge the user dragged: the neighbor on that
    /// edge gives or takes the difference, and the other members keep their heights.
    /// The window's own preferred height, which applies when it is alone, is untouched.
    func applyStackedResize(windowID: String, previous: CGRect, observed: CGRect, available: CGRect) {
        if abs(observed.width - previous.width) > 3 {
            state.setWidthFraction(observed.width / available.width, for: windowID)
        }
        forgetMinimumHeight(windowID: windowID, ifAbove: observed.height)
        guard abs(observed.height - previous.height) > 3,
              let tile = state.currentSpace.tileIndex(of: windowID),
              let resize = stackResize(tile: state.currentSpace.tiles[tile], windowID: windowID,
                                       previous: previous, observed: observed,
                                       height: { self.knownFrames[$0]?.height },
                                       minimumHeight: { self.learnedMinimumHeights[$0] }) else { return }
        state.setSplitShares(windowID: windowID, neighborID: resize.neighborID, fraction: resize.share)
    }
}

/// The tile index a dropped window lands at: the number of other tiles whose
/// center is left of the window's center. `placements` are the ribbon before
/// the drag; they are grouped by the tiles of `space`. A placement
/// of a window `space` no longer holds counts on its own. While every tile holds
/// one window, this counts windows exactly as the drop always did.
func dropTileIndex(windowID: String, droppedMidX: CGFloat, placements: [WindowPlacement],
                   space: SpaceState) -> Int {
    var spans: [Int: (minX: CGFloat, maxX: CGFloat, midX: CGFloat, count: Int)] = [:]
    var loose = 0
    for placement in placements where placement.windowID != windowID {
        guard let tile = space.tileIndex(of: placement.windowID) else {
            if placement.frame.midX < droppedMidX { loose += 1 }
            continue
        }
        if let span = spans[tile] {
            spans[tile] = (min(span.minX, placement.frame.minX), max(span.maxX, placement.frame.maxX),
                           span.midX, span.count + 1)
        } else {
            spans[tile] = (placement.frame.minX, placement.frame.maxX, placement.frame.midX, 1)
        }
    }
    // A lone window's tile center is its own midX, taken as is so no rounding differs.
    return loose + spans.values.count { ($0.count == 1 ? $0.midX : ($0.minX + $0.maxX) / 2) < droppedMidX }
}

struct StackResize: Equatable {
    let neighborID: String
    /// The resized window's part of the height it shares with the neighbor.
    let share: Double
}

/// The new height share after the user resized a window of a vertical stack of
/// panes from `previous` to `observed`. The neighbor on the edge that moved
/// (above for a top-edge drag) gives or takes the difference; at the stack's own
/// top or bottom edge, the neighbor on the other side does. The pair keeps its
/// combined share, so the other panes keep their heights, and the neighbor keeps
/// at least its known minimum height.
func stackResize(tile: Tile, windowID: String, previous: CGRect, observed: CGRect,
                 height: (String) -> CGFloat?, minimumHeight: (String) -> CGFloat?) -> StackResize? {
    guard case .split(.vertical, let children, _) = tile.panes,
          let index = children.firstIndex(of: .pane(windowID: windowID)),
          previous.height.isFinite, previous.height > 0,
          observed.height.isFinite, observed.height > 0 else { return nil }
    let topMoved = abs(observed.minY - previous.minY) > 3
    let bottomMoved = abs(observed.maxY - previous.maxY) > 3
    let above = index > 0 ? children[index - 1] : nil
    let below = index + 1 < children.count ? children[index + 1] : nil
    guard case .pane(let neighborID) = topMoved && !bottomMoved ? above ?? below : below ?? above,
          let neighborHeight = height(neighborID), neighborHeight.isFinite, neighborHeight > 0 else { return nil }
    let total = previous.height + neighborHeight
    let neighborFloor = max(1, minimumHeight(neighborID).flatMap { $0.isFinite ? $0 : nil } ?? 0)
    let memberHeight = min(observed.height, total - neighborFloor)
    guard memberHeight > 0 else { return nil }
    return StackResize(neighborID: neighborID, share: Double(memberHeight / total))
}
