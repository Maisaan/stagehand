import CoreGraphics
import Foundation

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side, left to right.
    case horizontal
    /// Children top to bottom.
    case vertical
}

public enum PaneDirection: Sendable, CaseIterable {
    case left, right, up, down

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var isForward: Bool { self == .right || self == .down }
}

/// The edge of a tile a joining window takes.
public enum TileEdge: Sendable {
    case left, right, top, bottom

    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var isLeading: Bool { self == .left || self == .top }
}

/// A tile's layout. Inner nodes split their extent along one axis by weight;
/// leaves are panes, each holding one window.
public indirect enum PaneTree: Equatable, Sendable, Codable {
    case pane(windowID: String)
    case split(axis: SplitAxis, children: [PaneTree], weights: [Double])

    static let defaultWeight = 1.0

    /// Depth first: horizontal children left to right, vertical ones top to bottom.
    public var windowIDs: [String] {
        var ids: [String] = []
        appendWindowIDs(to: &ids)
        return ids
    }

    private func appendWindowIDs(to ids: inout [String]) {
        switch self {
        case .pane(let windowID): ids.append(windowID)
        case .split(_, let children, _): for child in children { child.appendWindowIDs(to: &ids) }
        }
    }

    public func contains(_ windowID: String) -> Bool {
        switch self {
        case .pane(let id): id == windowID
        case .split(_, let children, _): children.contains { $0.contains(windowID) }
        }
    }

    public func mapWindowIDs(_ transform: (String) -> String) -> PaneTree {
        switch self {
        case .pane(let windowID): .pane(windowID: transform(windowID))
        case .split(let axis, let children, let weights):
            .split(axis: axis, children: children.map { $0.mapWindowIDs(transform) }, weights: weights)
        }
    }

    static func usableWeight(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return defaultWeight }
        return value
    }

    /// The tree with only the panes `keep` accepts, visited in reading order, in
    /// canonical form: every split has two or more children, each with a usable
    /// weight, and none splits along its parent's axis. A removed pane's siblings
    /// keep their relative weights, so they grow into its space; a flattened
    /// split's children share its weight in proportion, so every pane keeps its
    /// size. Nil when no pane is kept.
    func restricted(to keep: (String) -> Bool) -> PaneTree? {
        switch self {
        case .pane(let windowID):
            return keep(windowID) ? self : nil
        case .split(let axis, let children, let weights):
            var keptChildren: [PaneTree] = []
            var keptWeights: [Double] = []
            for (offset, child) in children.enumerated() {
                guard let kept = child.restricted(to: keep) else { continue }
                let weight = Self.usableWeight(weights.indices.contains(offset) ? weights[offset] : nil)
                if case .split(let childAxis, let grandchildren, let childWeights) = kept, childAxis == axis {
                    let total = childWeights.reduce(0, +)
                    for (grandchild, childWeight) in zip(grandchildren, childWeights) {
                        keptChildren.append(grandchild)
                        keptWeights.append(Self.usableWeight(weight * childWeight / total))
                    }
                } else {
                    keptChildren.append(kept)
                    keptWeights.append(weight)
                }
            }
            if keptChildren.count < 2 { return keptChildren.first }
            return .split(axis: axis, children: keptChildren, weights: keptWeights)
        }
    }

    func removing(_ windowID: String) -> PaneTree? {
        restricted { $0 != windowID }
    }

    /// The window that takes over a removed pane's role: the first pane of the
    /// sibling that absorbs its space, the next one or else the previous one.
    func successor(ofRemoved windowID: String) -> String? {
        guard case .split(_, let children, _) = self,
              let index = children.firstIndex(where: { $0.contains(windowID) }) else { return nil }
        if case .pane = children[index] {
            let sibling = children.indices.contains(index + 1) ? children[index + 1] : children[index - 1]
            return sibling.windowIDs.first
        }
        return children[index].successor(ofRemoved: windowID)
    }

    func swapping(_ first: String, _ second: String) -> PaneTree {
        mapWindowIDs { $0 == first ? second : $0 == second ? first : $0 }
    }

    /// Adds `windowID` beside the pane of `mate`, along `axis`, after it or
    /// before it. Within a split along that axis it becomes the mate's sibling
    /// with `weight`, or the average of its new siblings' weights; otherwise the
    /// mate's pane becomes a split of the two.
    func inserting(_ windowID: String, beside mate: String, along axis: SplitAxis, after: Bool,
                   weight: Double? = nil) -> PaneTree {
        switch self {
        case .pane(let id):
            guard id == mate else { return self }
            let pair: [PaneTree] = after ? [self, .pane(windowID: windowID)] : [.pane(windowID: windowID), self]
            return .split(axis: axis, children: pair, weights: [Self.defaultWeight, Self.defaultWeight])
        case .split(let splitAxis, var children, var weights):
            guard let index = children.firstIndex(where: { $0.contains(mate) }) else { return self }
            if splitAxis == axis, case .pane = children[index] {
                let newWeight = weight.map { Self.usableWeight($0) } ?? weights.reduce(0, +) / Double(weights.count)
                children.insert(.pane(windowID: windowID), at: after ? index + 1 : index)
                weights.insert(newWeight, at: after ? index + 1 : index)
                return .split(axis: splitAxis, children: children, weights: weights)
            }
            children[index] = children[index].inserting(windowID, beside: mate, along: axis, after: after,
                                                        weight: weight)
            return .split(axis: splitAxis, children: children, weights: weights)
        }
    }

    /// Adds `windowID` as a pane spanning the whole `edge` of the tree. Its
    /// weight is the average of its new siblings'.
    func joining(_ windowID: String, at edge: TileEdge) -> PaneTree {
        let joiner = PaneTree.pane(windowID: windowID)
        if case .split(let axis, var children, var weights) = self, axis == edge.axis {
            let weight = weights.reduce(0, +) / Double(weights.count)
            children.insert(joiner, at: edge.isLeading ? 0 : children.endIndex)
            weights.insert(weight, at: edge.isLeading ? 0 : weights.endIndex)
            return .split(axis: axis, children: children, weights: weights)
        }
        return .split(axis: edge.axis, children: edge.isLeading ? [joiner, self] : [self, joiner],
                      weights: [Self.defaultWeight, Self.defaultWeight])
    }

    /// Moves the pane of `windowID` to `position` among its parent split's
    /// children. Its weight moves with it.
    func reordering(_ windowID: String, to position: Int) -> PaneTree? {
        guard case .split(let axis, var children, var weights) = self,
              let index = children.firstIndex(where: { $0.contains(windowID) }) else { return nil }
        if case .pane = children[index] {
            let destination = min(max(position, 0), children.count - 1)
            guard destination != index else { return nil }
            children.insert(children.remove(at: index), at: destination)
            weights.insert(weights.remove(at: index), at: destination)
            return .split(axis: axis, children: children, weights: weights)
        }
        guard let child = children[index].reordering(windowID, to: position) else { return nil }
        children[index] = child
        return .split(axis: axis, children: children, weights: weights)
    }

    /// Gives the child holding `windowID` `fraction` of the weight it shares
    /// with the child holding `neighborID`, in the split that separates them.
    func settingShares(_ windowID: String, _ neighborID: String, fraction: Double) -> PaneTree? {
        guard case .split(let axis, var children, var weights) = self,
              let index = children.firstIndex(where: { $0.contains(windowID) }),
              let neighbor = children.firstIndex(where: { $0.contains(neighborID) }) else { return nil }
        if index == neighbor {
            guard let child = children[index].settingShares(windowID, neighborID, fraction: fraction) else {
                return nil
            }
            children[index] = child
            return .split(axis: axis, children: children, weights: weights)
        }
        let pair = weights[index] + weights[neighbor]
        let weight = pair * fraction
        let neighborWeight = pair - weight
        guard weight.isFinite, weight > 0, neighborWeight.isFinite, neighborWeight > 0,
              weights[index] != weight else { return nil }
        weights[index] = weight
        weights[neighbor] = neighborWeight
        return .split(axis: axis, children: children, weights: weights)
    }

    /// The axis of the split that separates two panes, if any.
    func separatingAxis(_ first: String, _ second: String) -> SplitAxis? {
        guard case .split(let axis, let children, _) = self,
              let index = children.firstIndex(where: { $0.contains(first) }),
              let other = children.firstIndex(where: { $0.contains(second) }) else { return nil }
        return index == other ? children[index].separatingAxis(first, second) : axis
    }

    // MARK: - The unit square

    /// Each pane's rectangle in the unit square, from the weights alone, in
    /// reading order. y grows downward.
    func unitFrames() -> [(windowID: String, frame: CGRect)] {
        var frames: [(windowID: String, frame: CGRect)] = []
        appendFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1), to: &frames)
        return frames
    }

    private func appendFrames(in rect: CGRect, to frames: inout [(windowID: String, frame: CGRect)]) {
        switch self {
        case .pane(let windowID):
            frames.append((windowID, rect))
        case .split(let axis, let children, let weights):
            let total = weights.reduce(0, +)
            var start: CGFloat = 0
            for (child, weight) in zip(children, weights) {
                let share = CGFloat(weight / total)
                let childRect = axis == .horizontal
                    ? CGRect(x: rect.minX + start * rect.width, y: rect.minY,
                             width: share * rect.width, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + start * rect.height,
                             width: rect.width, height: share * rect.height)
                child.appendFrames(in: childRect, to: &frames)
                start += share
            }
        }
    }

    func unitFrame(of windowID: String) -> CGRect? {
        unitFrames().first { $0.windowID == windowID }?.frame
    }

    private static let edgeTolerance: CGFloat = 1e-9

    private static func overlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
        min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound)
    }

    /// The pane on `direction`'s side of `windowID`'s pane: its facing edge
    /// touches that pane's edge and it overlaps that pane across the move. Ties go
    /// to the greatest overlap, then to the topmost or leftmost pane.
    func neighbor(of windowID: String, toward direction: PaneDirection) -> String? {
        let frames = unitFrames()
        guard let origin = frames.first(where: { $0.windowID == windowID })?.frame else { return nil }
        let across = { (frame: CGRect) in
            direction.axis == .horizontal ? frame.minY...frame.maxY : frame.minX...frame.maxX
        }
        let originSpan = across(origin)
        var best: (windowID: String, overlap: CGFloat, start: CGFloat)?
        for candidate in frames where candidate.windowID != windowID {
            let gap = switch direction {
            case .right: candidate.frame.minX - origin.maxX
            case .left: origin.minX - candidate.frame.maxX
            case .down: candidate.frame.minY - origin.maxY
            case .up: origin.minY - candidate.frame.maxY
            }
            let span = across(candidate.frame)
            let overlap = Self.overlap(originSpan, span)
            guard abs(gap) < Self.edgeTolerance, overlap > Self.edgeTolerance else { continue }
            if let current = best,
               overlap < current.overlap - Self.edgeTolerance
                || (abs(overlap - current.overlap) <= Self.edgeTolerance && span.lowerBound >= current.start) {
                continue
            }
            best = (candidate.windowID, overlap, span.lowerBound)
        }
        return best?.windowID
    }

    /// The pane focus enters when it comes into the tile moving `direction`:
    /// `active` if it touches the entered edge, else the edge pane overlapping
    /// `verticalRange` (in the unit square) the most, then the topmost.
    func entryPane(movingToward direction: PaneDirection, verticalRange: ClosedRange<CGFloat>,
                   active: String) -> String? {
        let edge: [(windowID: String, frame: CGRect)] = unitFrames().filter {
            switch direction {
            case .right: $0.frame.minX < Self.edgeTolerance
            case .left: $0.frame.maxX > 1 - Self.edgeTolerance
            case .down: $0.frame.minY < Self.edgeTolerance
            case .up: $0.frame.maxY > 1 - Self.edgeTolerance
            }
        }
        if edge.contains(where: { $0.windowID == active }) { return active }
        var best: (windowID: String, overlap: CGFloat, top: CGFloat)?
        for pane in edge {
            let overlap = Self.overlap(verticalRange, pane.frame.minY...pane.frame.maxY)
            if let current = best,
               overlap < current.overlap - Self.edgeTolerance
                || (abs(overlap - current.overlap) <= Self.edgeTolerance && pane.frame.minY >= current.top) {
                continue
            }
            best = (pane.windowID, overlap, pane.frame.minY)
        }
        return best?.windowID
    }

    /// The pane whose unit rectangle holds `point`.
    func pane(at point: CGPoint) -> String? {
        unitFrames().first { frame in
            (frame.frame.minX...frame.frame.maxX).contains(point.x)
                && (frame.frame.minY...frame.frame.maxY).contains(point.y)
        }?.windowID
    }
}

/// Ready-made tile layouts. Each builds a tree from windows in reading order.
public enum PaneLayout: String, Codable, Sendable, CaseIterable {
    case single, sideBySide, stacked, grid, wideOverTwo

    public var paneCount: Int {
        switch self {
        case .single: 1
        case .sideBySide, .stacked: 2
        case .wideOverTwo: 3
        case .grid: 4
        }
    }

    /// Whether the layout has two pane columns, so its tile takes the whole width.
    var spansTwoColumns: Bool { self == .sideBySide || self == .grid || self == .wideOverTwo }

    /// Nil unless there are exactly `paneCount` windows.
    public func tree(_ windowIDs: [String]) -> PaneTree? {
        guard windowIDs.count == paneCount else { return nil }
        let panes = windowIDs.map { PaneTree.pane(windowID: $0) }
        func split(_ axis: SplitAxis, _ children: [PaneTree]) -> PaneTree {
            .split(axis: axis, children: children, weights: children.map { _ in PaneTree.defaultWeight })
        }
        return switch self {
        case .single: panes[0]
        case .sideBySide: split(.horizontal, panes)
        case .stacked: split(.vertical, panes)
        case .grid: split(.vertical, [split(.horizontal, [panes[0], panes[1]]),
                                      split(.horizontal, [panes[2], panes[3]])])
        case .wideOverTwo: split(.vertical, [panes[0], split(.horizontal, [panes[1], panes[2]])])
        }
    }
}

/// A display's identity: its CoreGraphics UUID string, stable across reconnects.
public struct DisplayID: Hashable, Codable, Sendable, RawRepresentable, CodingKeyRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The connected displays, left to right, and the one that holds spaces whose
/// anchor is not connected. Empty means one display, as before displays were modeled.
public struct DisplayList: Equatable, Sendable {
    public var ids: [DisplayID] = []
    public var fallback: DisplayID?

    public init(ids: [DisplayID] = [], fallback: DisplayID? = nil) {
        self.ids = ids
        self.fallback = fallback
    }
}
