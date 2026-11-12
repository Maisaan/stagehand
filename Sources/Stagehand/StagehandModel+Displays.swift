import AppKit
import StagehandCore
import StagehandPlatform

/// The display arrangement in the workspace state: which displays are managed, and
/// what the app bar shows on each.
extension StagehandModel {
    static let unsupportedArrangementWarning = "Stagehand paused: the display it manages has other displays on both sides, so there is no free edge to hide windows at. Arrange displays in System Settings > Displays so it has a free left or right edge, then press Start."

    /// Sets the state's displays from `arrangement`. A new display takes a space only when
    /// `anchoringNewDisplays`, after a change has settled. Returns false when it paused
    /// because no display has a free edge Stagehand could park at.
    @discardableResult
    func applyDisplays(_ arrangement: DisplayArrangement, anchoringNewDisplays: Bool) -> Bool {
        let managed = arrangement.managedDisplays
        guard managed.isManageable else {
            diagnostics.record("display_arrangement_unsupported", details: arrangementDetails(arrangement, managed))
            stop(reason: "display_arrangement_unsupported", automatic: false,
                 details: ["screenCount": String(arrangement.displays.count)])
            warning = Self.unsupportedArrangementWarning
            return false
        }
        let anchored = state.setDisplays(managed.ids, fallback: managed.fallback,
                                         anchoringNewDisplays: anchoringNewDisplays)
        managedDisplayNumbers = Dictionary(
            arrangement.displays.filter { managed.ids.contains($0.id) }.map { ($0.id, $0.number) },
            uniquingKeysWith: { first, _ in first })
        guard managed != managedDisplays || !anchored.isEmpty else { return true }
        if managed.displayWithoutFreeEdge != nil, managed != managedDisplays {
            diagnostics.record("display_arrangement_unsupported", details: arrangementDetails(arrangement, managed))
        }
        managedDisplays = managed
        var details = arrangementDetails(arrangement, managed)
        details["anchored"] = anchored.map { "\($0.key.logPrefix)=\($0.value + 1)" }.sorted().joined(separator: ",")
        details["unmanaged"] = state.displays.ids.filter { state.shownSpaceIndex(on: $0) == nil }
            .map(\.logPrefix).joined(separator: ",")
        details["focused"] = state.focusedDisplay?.logPrefix ?? "none"
        diagnostics.record("display_arrangement", details: details)
        return true
    }

    /// What the app bar needs per managed display; before Start, the fallback display alone.
    func navigationDisplays() -> [NavigationDisplay] {
        guard !state.displays.ids.isEmpty else {
            let arrangement = displayArrangement
            return arrangement.fallback.flatMap(arrangement.display).map {
                [NavigationDisplay(id: $0.id, number: $0.number, spaceIndex: state.activeSpaceIndex, isFocused: true)]
            } ?? []
        }
        return state.displays.ids.compactMap { id in
            guard let number = managedDisplayNumbers[id], let space = state.shownSpaceIndex(on: id) else { return nil }
            return NavigationDisplay(id: id, number: number, spaceIndex: space, isFocused: id == state.focusedDisplay)
        }
    }

    /// The tiles of `index` on screen on the display that shows it, if another one does.
    func visibleTileRange(ofSpace index: Int) -> ClosedRange<Int>? {
        guard let layout = otherDisplayLayouts(in: displayArrangement).first(where: { $0.spaceIndex == index }) else {
            return nil
        }
        let tiles = layout.placements.filter(\.isVisible).compactMap { state.spaces[index].tileIndex(of: $0.windowID) }
        guard let first = tiles.min(), let last = tiles.max() else { return nil }
        return first...last
    }

    private func arrangementDetails(_ arrangement: DisplayArrangement, _ managed: ManagedDisplays) -> [String: String] {
        [
            "displays": arrangement.ids.map(\.logPrefix).joined(separator: ","),
            "managed": managed.ids.map(\.logPrefix).joined(separator: ","),
            "fallback": managed.fallback?.logPrefix ?? "none",
            "withoutFreeEdge": managed.displayWithoutFreeEdge?.id.logPrefix ?? "none"
        ]
    }
}
