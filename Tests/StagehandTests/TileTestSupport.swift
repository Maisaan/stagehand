@testable import StagehandCore

extension PaneTree {
    static func h(_ children: PaneTree..., weights: [Double]? = nil) -> PaneTree {
        .split(axis: .horizontal, children: children, weights: weights ?? children.map { _ in 1 })
    }

    static func v(_ children: PaneTree..., weights: [Double]? = nil) -> PaneTree {
        .split(axis: .vertical, children: children, weights: weights ?? children.map { _ in 1 })
    }

    static func p(_ windowID: String) -> PaneTree { .pane(windowID: windowID) }

    /// Windows top to bottom: one pane, or a vertical split of them.
    static func stack(_ windowIDs: [String], weights: [Double] = []) -> PaneTree {
        guard windowIDs.count != 1 else { return .pane(windowID: windowIDs[0]) }
        return .split(axis: .vertical, children: windowIDs.map { .pane(windowID: $0) },
                      weights: windowIDs.indices.map { weights.indices.contains($0) ? weights[$0] : 1 })
    }

    /// The weight of a window's pane in its parent split; nil for a lone pane.
    func weight(of windowID: String) -> Double? {
        guard case .split(_, let children, let weights) = self,
              let index = children.firstIndex(where: { $0.contains(windowID) }) else { return nil }
        if case .pane = children[index] { return weights[index] }
        return children[index].weight(of: windowID)
    }
}

extension Tile {
    init(id: String? = nil, stacking windowIDs: [String], widthFraction: Double = SpaceState.defaultWidthFraction,
         activeWindowID: String? = nil, weights: [Double] = []) {
        self.init(id: id, panes: .stack(windowIDs, weights: weights), widthFraction: widthFraction,
                  activeWindowID: activeWindowID)
    }
}
