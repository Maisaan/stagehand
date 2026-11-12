import AppKit
import StagehandCore
import StagehandPlatform

/// A change to the active space's tiles, made by the tile shortcuts.
enum TileChange: Equatable {
    /// The focused window swaps with the pane on that side (negative: left); at
    /// its tile's edge it leaves as its own tile; alone, it joins the neighbor.
    case moveWindowSideways(direction: Int)
    /// The focused window swaps with the pane above (negative) or below.
    case moveWindowVertically(direction: Int)
    /// Focus moves to the pane on that side within the tile.
    case focusPane(PaneDirection)
    case arrange(PaneLayout)

    var diagnosticName: String {
        switch self {
        case .moveWindowSideways(let direction): direction < 0 ? "moveWindowLeft" : "moveWindowRight"
        case .moveWindowVertically(let direction): direction < 0 ? "moveWindowUp" : "moveWindowDown"
        case .focusPane(let direction): "focusPane.\(direction)"
        case .arrange(let layout): "arrange.\(layout.rawValue)"
        }
    }

    /// The tile change a tile shortcut or arrow shortcut swipe asks for.
    init?(_ action: NavigationAction) {
        switch action {
        case .moveWindowLeftInTile: self = .moveWindowSideways(direction: -1)
        case .moveWindowRightInTile: self = .moveWindowSideways(direction: 1)
        case .moveWindowUpInTile: self = .moveWindowVertically(direction: -1)
        case .moveWindowDownInTile: self = .moveWindowVertically(direction: 1)
        case .focusPaneAbove: self = .focusPane(.up)
        case .focusPaneBelow: self = .focusPane(.down)
        case .arrangeTile(let layout): self = .arrange(layout)
        default: return nil
        }
    }
}

/// Why a tile change was not made. A refusal leaves the layout as it was and
/// Stagehand running; it is never a pause.
enum TileRefusal: Equatable {
    /// The tile's panes cannot all fit in the available frame at the least
    /// sizes their apps accept, on either axis.
    case tileDoesNotFit(windowIDs: [String], required: CGSize, available: CGSize)
    /// The space has fewer windows than the layout has panes.
    case notEnoughWindows(needed: Int, available: Int)
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

    /// Makes a tile change if every tile it changes fits at its panes' known
    /// minimum sizes, and otherwise returns the refusal with the workspace
    /// unchanged. The change queue calls this as the change starts.
    func applyTileChange(_ change: TileChange) -> TileChangeOutcome {
        var candidate = state
        switch change {
        case .moveWindowSideways(let direction):
            guard candidate.moveFocusedWindowSideways(by: direction) else { return .unchanged }
        case .moveWindowVertically(let direction):
            guard candidate.moveFocusedWindowVertically(by: direction) else { return .unchanged }
        case .focusPane(let direction):
            guard candidate.focusPane(direction: direction) else { return .unchanged }
        case .arrange(let layout):
            guard let windowID = candidate.focusedWindowID else { return .unchanged }
            switch candidate.arrange(tileOf: windowID, layout: layout) {
            case .arranged: break
            case .unchanged: return .unchanged
            case .notEnoughWindows(let needed, let available):
                let refusal = TileRefusal.notEnoughWindows(needed: needed, available: available)
                reportTileRefusal(refusal, change: change, decided: "before_change")
                return .refused(refusal)
            }
        }
        if let refusal = tileRefusal(from: state, to: candidate) {
            reportTileRefusal(refusal, change: change, decided: "before_change")
            return .refused(refusal)
        }
        state = candidate
        return .applied
    }

    // MARK: - Refusal without pausing
    //
    // Every other failed layout rolls back and pauses (finish(_:outcome:)). A tile
    // that does not fit is the user's request meeting app limits, not a failure of
    // Stagehand, so it is refused and Stagehand keeps running. It is decided before
    // the change wherever the minimum sizes are already known; a minimum first
    // learned by the change's own layout undoes the change after it.

    /// The first multi-pane tile in the active space whose layout changed between
    /// the two states and that cannot fit the available frame, in width or
    /// height, at its panes' known minimum sizes.
    func tileRefusal(from previous: WorkspaceState, to next: WorkspaceState) -> TileRefusal? {
        guard let availableFrame, previous.spaces.indices.contains(next.activeSpaceIndex) else { return nil }
        let before = previous.spaces[next.activeSpaceIndex]
        for tile in next.currentSpace.tiles where tile.isMultiPane && layoutChanged(tile, since: before) {
            let required = WindowLayout.minimumTileSize(tile, paneGap: paneGap, minimumWidths: learnedMinimumWidths,
                                                        minimumHeights: learnedMinimumHeights)
            if required.width > availableFrame.width + 1 || required.height > availableFrame.height + 1 {
                return .tileDoesNotFit(windowIDs: tile.windowIDs, required: required,
                                       available: availableFrame.size)
            }
        }
        return nil
    }

    /// A tile that only lost panes cannot need more room than it had, so leaving
    /// a tile that no longer fits is never refused.
    private func layoutChanged(_ tile: Tile, since before: SpaceState) -> Bool {
        guard let previous = before.tiles.first(where: { $0.id == tile.id }) else { return true }
        let members = Set(tile.windowIDs)
        return previous.panes.restricted(to: { members.contains($0) }) != tile.panes
    }

    /// After a tile change's layout completed: if that layout learned minimum
    /// sizes that leave a changed tile too big, return to the tiles from before
    /// the change and lay them out again. Windows that left meanwhile stay gone.
    /// Returns whether the change was undone.
    func undoTileChangeThatDidNotFit(_ change: TileChange, stateBefore: WorkspaceState) -> Bool {
        guard let refusal = tileRefusal(from: stateBefore, to: state) else { return false }
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
        var details = ["operation": "tiles.\(change.diagnosticName)", "decided": decided]
        switch refusal {
        case .tileDoesNotFit(let windowIDs, let required, let available):
            details["reason"] = "tile_does_not_fit"
            details["windowIDs"] = windowIDs.joined(separator: ",")
            details["requiredWidth"] = String(Double(required.width))
            details["requiredHeight"] = String(Double(required.height))
            details["availableWidth"] = String(Double(available.width))
            details["availableHeight"] = String(Double(available.height))
        case .notEnoughWindows(let needed, let available):
            details["reason"] = "not_enough_windows"
            details["neededWindows"] = String(needed)
            details["availableWindows"] = String(available)
        }
        diagnostics.record("tile_change_refused", details: details)
        onTileChangeRefused?(refusal)
    }

    /// The short message for a refusal. It names no app or window: it shows on
    /// screen while the user is looking at those windows.
    static func message(for refusal: TileRefusal) -> String {
        switch refusal {
        case .tileDoesNotFit:
            "Not arranged: these windows can't get small enough to fit in one tile."
        case .notEnoughWindows(let needed, _):
            "Not arranged: this space needs \(needed) windows for that layout."
        }
    }

    /// The default `onTileChangeRefused`: a brief note in the app bar, which never
    /// takes focus. Stagehand keeps running and the layout stays as it was.
    func showTileRefusal(_ refusal: TileRefusal) {
        overlays.showNotice(Self.message(for: refusal))
    }

    // MARK: - Learned minimum sizes

    /// Learns from a size a layout asked for and the size the window took, on
    /// each axis. A window larger than asked has a minimum; a window that took
    /// less than its learned minimum shows that minimum was wrong.
    func noteLayoutSize(windowID: String, requested: CGSize, actual: CGSize) {
        learnedMinimumWidths[windowID] = Self.learnedMinimum(learnedMinimumWidths[windowID],
                                                             requested: requested.width, actual: actual.width)
        learnedMinimumHeights[windowID] = Self.learnedMinimum(learnedMinimumHeights[windowID],
                                                              requested: requested.height, actual: actual.height)
    }

    func forgetMinimumSize(windowID: String, seen size: CGSize) {
        learnedMinimumWidths[windowID] = Self.keptMinimum(learnedMinimumWidths[windowID], seen: size.width)
        learnedMinimumHeights[windowID] = Self.keptMinimum(learnedMinimumHeights[windowID], seen: size.height)
    }

    private static func learnedMinimum(_ known: CGFloat?, requested: CGFloat, actual: CGFloat) -> CGFloat? {
        guard requested.isFinite, actual.isFinite, actual > 0 else { return known }
        return actual > requested + 1 ? max(known ?? 0, actual) : keptMinimum(known, seen: actual)
    }

    private static func keptMinimum(_ known: CGFloat?, seen: CGFloat) -> CGFloat? {
        guard let known, seen.isFinite, seen > 0, seen < known - 1 else { return known }
        return nil
    }

    /// Members never write their own widths to a multi-pane tile, so one
    /// member's width never overwrites another's.
    func widenTilesToLearnedMinimums(holding windowIDs: [String], availableWidth: CGFloat) {
        guard availableWidth.isFinite, availableWidth > 0 else { return }
        var widened = Set<String>()
        for windowID in windowIDs {
            guard let index = state.currentSpace.tileIndex(of: windowID) else { continue }
            let tile = state.currentSpace.tiles[index]
            guard tile.isMultiPane, widened.insert(tile.id).inserted else { continue }
            let minimum = WindowLayout.minimumTileSize(tile, paneGap: paneGap, minimumWidths: learnedMinimumWidths,
                                                       minimumHeights: learnedMinimumHeights).width / availableWidth
            if minimum > tile.widthFraction {
                state.setWidthFraction(Double(minimum), for: windowID)
            }
        }
    }

    // MARK: - Pointer drops and resizes

    /// Applies a title-bar drop of `windowID` at `frame` against the ribbon as it
    /// was laid out before the drag. A window alone in its tile moves its tile
    /// to where it was dropped. A window of a multi-pane tile dropped within its
    /// tile's span swaps with the pane under the drop; dropped outside it, it
    /// becomes its own tile there. Never joins a tile.
    func applyWindowDrop(windowID: String, frame: CGRect, placements: [WindowPlacement]) {
        let space = state.currentSpace
        guard let tileIndex = space.tileIndex(of: windowID), space.tiles[tileIndex].isMultiPane else {
            state.reorderWindow(windowID: windowID,
                                to: dropTileIndex(windowID: windowID, droppedMidX: frame.midX,
                                                  placements: placements, space: space))
            return
        }
        let tile = space.tiles[tileIndex]
        let members = Set(tile.windowIDs)
        let own = placements.filter { members.contains($0.windowID) }
        guard let minX = own.map(\.frame.minX).min(), let maxX = own.map(\.frame.maxX).max() else { return }
        if (minX...maxX).contains(frame.midX) {
            let drop = CGPoint(x: frame.midX, y: frame.midY)
            guard let target = own.min(by: { distance(from: drop, to: $0.frame) < distance(from: drop, to: $1.frame) }),
                  let pane = tile.panes.unitFrame(of: target.windowID) else { return }
            state.movePane(windowID: windowID, to: CGPoint(x: pane.midX, y: pane.midY),
                           inSpace: state.activeSpaceIndex)
        } else {
            state.expel(windowID: windowID,
                        toTileAt: dropTileIndex(windowID: windowID, droppedMidX: frame.midX,
                                                placements: placements, space: space),
                        inSpace: state.activeSpaceIndex)
        }
    }

    /// A title-bar drop that lands mostly on another managed display joins the space
    /// that display shows, as a tile of its own at the drop position, and takes focus there.
    func applyDropOnOtherDisplay(windowID: String, frame: CGRect) -> Bool {
        let arrangement = displayArrangement
        guard let display = managedDisplay(holding: frame, in: arrangement), display != state.focusedDisplay,
              let layout = otherDisplayLayouts(in: arrangement).first(where: { $0.display.id == display })
        else { return false }
        let position = dropTileIndex(windowID: windowID, droppedMidX: frame.midX, placements: layout.placements,
                                     space: state.spaces[layout.spaceIndex])
        return state.moveWindow(windowID, fromSpace: state.activeSpaceIndex, toSpace: layout.spaceIndex,
                                atTile: position)
    }

    /// A window alone in its tile sets the tile's width and its own preferred
    /// height; a pane's resize goes through `paneResize`.
    func applyPaneResize(windowID: String, previous: CGRect, observed: CGRect, available: CGRect) {
        forgetMinimumSize(windowID: windowID, seen: observed.size)
        let space = state.currentSpace
        guard let tileIndex = space.tileIndex(of: windowID), space.tiles[tileIndex].isMultiPane else {
            state.setWidthFraction(observed.width / available.width, for: windowID)
            preferredHeights[windowID] = preferredHeightAfterResize(previous: previous, observed: observed,
                                                                    available: available)
            return
        }
        let resizes = paneResize(
            tile: space.tiles[tileIndex], windowID: windowID, previous: previous, observed: observed,
            frame: { $0 == windowID ? previous : self.knownFrames[$0] },
            minimumSize: { WindowLayout.minimumTileSize($0, paneGap: self.paneGap,
                                                        minimumWidths: self.learnedMinimumWidths,
                                                        minimumHeights: self.learnedMinimumHeights) }
        )
        for resize in resizes {
            switch resize {
            case .shares(let neighborID, let share):
                state.setSplitShares(windowID: windowID, neighborID: neighborID, fraction: share)
            case .tileWidth(let width):
                state.setWidthFraction(width / available.width, for: windowID)
            }
        }
    }
}

private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
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

enum PaneResize: Equatable {
    /// The resized window's side of the split it shares with the neighbor takes
    /// this part of their combined extent.
    case shares(neighborID: String, share: Double)
    /// The tile's new width, in points.
    case tileWidth(CGFloat)
}

/// On each axis, the dragged edge is the leading one only when it alone moved.
/// An edge shared with a neighbor trades extent between the two sides of the
/// split that separates them, and the neighbor's side keeps its known minimum.
/// The tile's left or right edge sets its width; its top or bottom edge changes
/// nothing, as a multi-pane tile always fills the height.
func paneResize(tile: Tile, windowID: String, previous: CGRect, observed: CGRect,
                frame: (String) -> CGRect?, minimumSize: (Tile) -> CGSize) -> [PaneResize] {
    guard tile.windowIDs.contains(windowID), usable(previous), usable(observed) else { return [] }
    var resizes: [PaneResize] = []
    for axis in [SplitAxis.horizontal, .vertical] {
        let before = span(previous, along: axis)
        let after = span(observed, along: axis)
        let growth = after.upperBound - after.lowerBound - (before.upperBound - before.lowerBound)
        guard abs(growth) > 3 else { continue }
        let leadingOnly = abs(after.lowerBound - before.lowerBound) > 3 && abs(after.upperBound - before.upperBound) <= 3
        let direction: PaneDirection = switch axis {
        case .horizontal: leadingOnly ? .left : .right
        case .vertical: leadingOnly ? .up : .down
        }
        guard let neighborID = tile.panes.neighbor(of: windowID, toward: direction) else {
            if axis == .horizontal, let extent = extent(of: tile.windowIDs, along: axis, frame: frame) {
                resizes.append(.tileWidth(extent + growth))
            }
            continue
        }
        guard let sides = tile.panes.separatingSides(windowID, neighborID),
              let ownExtent = extent(of: sides.first.windowIDs, along: axis, frame: frame),
              let neighborExtent = extent(of: sides.second.windowIDs, along: axis, frame: frame) else { continue }
        let neighborMinimum = minimumSize(Tile(panes: sides.second))
        let floor = max(1, axis == .horizontal ? neighborMinimum.width : neighborMinimum.height)
        let total = ownExtent + neighborExtent
        let resized = min(ownExtent + growth, total - floor)
        guard resized > 0 else { continue }
        resizes.append(.shares(neighborID: neighborID, share: Double(resized / total)))
    }
    return resizes
}

private func usable(_ rect: CGRect) -> Bool {
    rect.width.isFinite && rect.width > 0 && rect.height.isFinite && rect.height > 0
        && rect.minX.isFinite && rect.minY.isFinite
}

private func span(_ rect: CGRect, along axis: SplitAxis) -> ClosedRange<CGFloat> {
    axis == .horizontal ? rect.minX...rect.maxX : rect.minY...rect.maxY
}

/// How far the windows reach together along `axis`; nil if any frame is unknown.
private func extent(of windowIDs: [String], along axis: SplitAxis, frame: (String) -> CGRect?) -> CGFloat? {
    var lower = CGFloat.infinity
    var upper = -CGFloat.infinity
    for windowID in windowIDs {
        guard let rect = frame(windowID), usable(rect) else { return nil }
        let range = span(rect, along: axis)
        lower = min(lower, range.lowerBound)
        upper = max(upper, range.upperBound)
    }
    return upper > lower ? upper - lower : nil
}
