import CoreGraphics
import Foundation

public struct WindowPlacement: Equatable, Sendable {
    public let windowID: String
    public let frame: CGRect
    public let isVisible: Bool
    public let isFocused: Bool
}

public enum WindowLayout {
    public static func placements(
        for state: WorkspaceState,
        availableFrame: CGRect,
        gap: CGFloat = 8,
        paneGap: CGFloat = 8,
        observedWidths: [String: CGFloat] = [:],
        preferredHeights: [String: CGFloat] = [:],
        observedHeights: [String: CGFloat] = [:],
        minimumWidths: [String: CGFloat] = [:],
        minimumHeights: [String: CGFloat] = [:]
    ) -> [WindowPlacement] {
        placements(for: state.currentSpace, availableFrame: availableFrame, tileGap: gap, paneGap: paneGap,
                   observedWidths: observedWidths, preferredHeights: preferredHeights,
                   observedHeights: observedHeights, minimumWidths: minimumWidths,
                   minimumHeights: minimumHeights)
    }

    /// Uses the caller's coordinate system without converting between AppKit and
    /// Accessibility; y grows downward, as in Accessibility coordinates.
    ///
    /// A tile of one window is placed as a lone window always was: its observed
    /// or requested width, its observed or preferred height, centered vertically.
    /// A multi-pane tile fills the available height and its requested width,
    /// widened to its panes' minimums up to the available width. Each split
    /// divides its extent by weight, less `max(0, paneGap)` between children, and
    /// no child gets less than its minimum. A pane's minimum is the larger of its
    /// window's minimum and observed size. A window smaller than its pane is
    /// centered in it; a larger one starts at the pane's origin.
    public static func placements(
        for space: SpaceState,
        availableFrame: CGRect,
        tileGap: CGFloat = 8,
        paneGap: CGFloat = 8,
        observedWidths: [String: CGFloat] = [:],
        preferredHeights: [String: CGFloat] = [:],
        observedHeights: [String: CGFloat] = [:],
        minimumWidths: [String: CGFloat] = [:],
        minimumHeights: [String: CGFloat] = [:]
    ) -> [WindowPlacement] {
        guard !availableFrame.isEmpty, !availableFrame.isInfinite,
              availableFrame.origin.x.isFinite, availableFrame.origin.y.isFinite,
              availableFrame.width.isFinite, availableFrame.height.isFinite else { return [] }
        let gap: CGFloat = tileGap.isFinite ? tileGap : 8
        let paneGap = max(0, paneGap.isFinite ? paneGap : 8)
        let panes = PaneMetrics(paneGap: paneGap, observedWidths: observedWidths,
                                observedHeights: observedHeights, minimumWidths: minimumWidths,
                                minimumHeights: minimumHeights)

        var cursor: CGFloat = 0
        var focusedStart: CGFloat = 0
        var focusedWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var ribbon: [(windowID: String, frame: CGRect)] = []
        ribbon.reserveCapacity(space.windowIDs.count)
        for tile in space.tiles {
            let requestedWidth = availableFrame.width * tile.widthFraction
            var tileWidth: CGFloat = 0
            var holdsFocus = false
            if tile.windowIDs.count == 1 {
                let windowID = tile.windowIDs[0]
                let width = observed(observedWidths[windowID]) ?? requestedWidth
                // Accepted app constraints take precedence over either requested size.
                let preferredHeight = preferredHeights[windowID] ?? availableFrame.height
                let requestedHeight = preferredHeight.isFinite && preferredHeight > 0
                    ? preferredHeight : availableFrame.height
                let height = observed(observedHeights[windowID]) ?? requestedHeight
                let frame = CGRect(x: cursor, y: availableFrame.midY - height / 2, width: width, height: height)
                holdsFocus = windowID == space.focusedWindowID
                tileWidth = width
                totalWidth = max(totalWidth, frame.maxX)
                ribbon.append((windowID: windowID, frame: frame))
            } else {
                let minimum = panes.minimumSize(of: tile.panes)
                tileWidth = min(max(requestedWidth, minimum.width), availableFrame.width)
                let tileFrame = CGRect(x: cursor, y: availableFrame.minY, width: tileWidth,
                                       height: availableFrame.height)
                let start = ribbon.count
                panes.place(tile.panes, in: tileFrame, into: &ribbon)
                for item in ribbon[start...] {
                    if item.windowID == space.focusedWindowID { holdsFocus = true }
                    totalWidth = max(totalWidth, item.frame.maxX)
                }
                totalWidth = max(totalWidth, tileFrame.maxX)
            }
            // A focus change inside a tile keeps the tile's place, so it never
            // scrolls the ribbon.
            if holdsFocus {
                focusedStart = cursor
                focusedWidth = tileWidth
            }
            cursor += max(1, tileWidth + gap)
        }
        let desiredOffset = gap < 0 ? focusedStart - (availableFrame.width - focusedWidth) / 2 : focusedStart
        let offset = min(max(0, desiredOffset), max(0, totalWidth - availableFrame.width))

        var placements: [WindowPlacement] = []
        placements.reserveCapacity(ribbon.count)
        for item in ribbon {
            let frame = item.frame.offsetBy(dx: availableFrame.minX - offset, dy: 0)
            placements.append(WindowPlacement(
                windowID: item.windowID,
                frame: frame,
                isVisible: frame.intersects(availableFrame),
                isFocused: item.windowID == space.focusedWindowID
            ))
        }
        return placements
    }

    /// The least size a tile's panes can take: each window's known minimum (none
    /// counts as zero) and the pane gaps between them.
    public static func minimumTileSize(_ tile: Tile, paneGap: CGFloat, minimumWidths: [String: CGFloat],
                                       minimumHeights: [String: CGFloat]) -> CGSize {
        PaneMetrics(paneGap: max(0, paneGap.isFinite ? paneGap : 8), observedWidths: [:], observedHeights: [:],
                    minimumWidths: minimumWidths, minimumHeights: minimumHeights)
            .minimumSize(of: tile.panes)
    }

    private static func observed(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private struct PaneMetrics {
        let paneGap: CGFloat
        let observedWidths: [String: CGFloat]
        let observedHeights: [String: CGFloat]
        let minimumWidths: [String: CGFloat]
        let minimumHeights: [String: CGFloat]

        func minimumSize(of tree: PaneTree) -> CGSize {
            switch tree {
            case .pane(let windowID):
                return CGSize(
                    width: max(observed(minimumWidths[windowID]) ?? 0, observed(observedWidths[windowID]) ?? 0),
                    height: max(observed(minimumHeights[windowID]) ?? 0, observed(observedHeights[windowID]) ?? 0)
                )
            case .split(let axis, let children, _):
                let gaps = paneGap * CGFloat(max(0, children.count - 1))
                var along = gaps
                var across: CGFloat = 0
                for child in children {
                    let size = minimumSize(of: child)
                    along += axis == .horizontal ? size.width : size.height
                    across = max(across, axis == .horizontal ? size.height : size.width)
                }
                return axis == .horizontal ? CGSize(width: along, height: across)
                    : CGSize(width: across, height: along)
            }
        }

        func place(_ tree: PaneTree, in rect: CGRect, into ribbon: inout [(windowID: String, frame: CGRect)]) {
            switch tree {
            case .pane(let windowID):
                let width = observed(observedWidths[windowID]) ?? rect.width
                let height = observed(observedHeights[windowID]) ?? rect.height
                ribbon.append((windowID, CGRect(
                    x: width < rect.width ? rect.midX - width / 2 : rect.minX,
                    y: height < rect.height ? rect.midY - height / 2 : rect.minY,
                    width: width, height: height
                )))
            case .split(let axis, let children, let weights):
                let extent = axis == .horizontal ? rect.width : rect.height
                let minimums = children.map { child in
                    let size = minimumSize(of: child)
                    return axis == .horizontal ? size.width : size.height
                }
                let gaps = paneGap * CGFloat(children.count - 1)
                let sizes = Self.shares(of: max(0, extent - gaps), weights: weights, minimums: minimums)
                var start = axis == .horizontal ? rect.minX : rect.minY
                for (child, size) in zip(children, sizes) {
                    let childRect = axis == .horizontal
                        ? CGRect(x: start, y: rect.minY, width: size, height: rect.height)
                        : CGRect(x: rect.minX, y: start, width: rect.width, height: size)
                    place(child, in: childRect, into: &ribbon)
                    start += size + paneGap
                }
            }
        }

        /// Divides `extent` by weight. A child whose share is below its minimum
        /// takes the minimum, and the rest is shared again, until every share is
        /// at least its minimum.
        private static func shares(of extent: CGFloat, weights: [Double], minimums: [CGFloat]) -> [CGFloat] {
            var held = [Bool](repeating: false, count: weights.count)
            var fixed: CGFloat = 0
            var flexibleWeight = 0.0
            var flexible: CGFloat = 0
            var changed = true
            while changed {
                changed = false
                // Summed again rather than subtracted, so no rounding residue is
                // left to share once every child is held.
                flexibleWeight = 0
                for index in weights.indices where !held[index] { flexibleWeight += weights[index] }
                flexible = flexibleWeight > 0 ? max(0, extent - fixed) : 0
                for index in weights.indices where !held[index] {
                    let share = flexible * CGFloat(weights[index] / flexibleWeight)
                    guard share < minimums[index] else { continue }
                    held[index] = true
                    fixed += minimums[index]
                    changed = true
                }
            }
            return weights.indices.map { index in
                held[index] ? minimums[index] : flexible * CGFloat(weights[index] / flexibleWeight)
            }
        }
    }
}
