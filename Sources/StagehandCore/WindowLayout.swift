import CoreGraphics
import Foundation

public struct WindowPlacement: Equatable, Sendable {
    public let windowID: String
    public let frame: CGRect
    public let isVisible: Bool
    public let isFocused: Bool
}

public enum WindowLayout {
    /// Uses the caller's coordinate system without converting between AppKit and
    /// Accessibility. A stack's members run in increasing y, top to bottom in
    /// Accessibility coordinates.
    ///
    /// A tile of one window is placed as a lone window always was: its observed
    /// or requested width, its observed or preferred height, centered vertically.
    /// A stack fills the available height, split by the members' height weights
    /// with a vertical gap of `max(0, gap)` (a negative gap only overlaps tiles).
    /// A member with an observed height keeps it and the others share the rest;
    /// a stack shorter or taller than the available height stays centered. Each
    /// member is left-aligned in the tile, which is as wide as its widest
    /// member. `preferredHeights` apply only to a window alone in its tile.
    /// `minimumHeights` are heights apps refused to go below; a stack member's
    /// share never falls under its own, and the other members share the rest.
    public static func placements(
        for state: WorkspaceState,
        availableFrame: CGRect,
        gap: CGFloat = 8,
        observedWidths: [String: CGFloat] = [:],
        preferredHeights: [String: CGFloat] = [:],
        observedHeights: [String: CGFloat] = [:],
        minimumHeights: [String: CGFloat] = [:]
    ) -> [WindowPlacement] {
        guard !availableFrame.isEmpty, !availableFrame.isInfinite,
              availableFrame.origin.x.isFinite, availableFrame.origin.y.isFinite,
              availableFrame.width.isFinite, availableFrame.height.isFinite else { return [] }
        let space = state.currentSpace
        let gap: CGFloat = gap.isFinite ? gap : 8
        let stackGap = max(0, gap)

        func observed(_ value: CGFloat?) -> CGFloat? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }

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
                let gaps = stackGap * CGFloat(tile.windowIDs.count - 1)
                var fixedHeight: CGFloat = 0
                var flexibleWeight = 0.0
                // Members held at their minimum height, found below; nil until one is.
                var heldAtMinimum: [Bool]?
                for (offset, windowID) in tile.windowIDs.enumerated() {
                    if let height = observed(observedHeights[windowID]) {
                        fixedHeight += height
                    } else {
                        flexibleWeight += tile.heightWeights[offset]
                    }
                }
                var flexibleHeight = flexibleWeight > 0 ? max(0, availableFrame.height - gaps - fixedHeight) : 0
                if !minimumHeights.isEmpty, flexibleWeight > 0 {
                    // A member whose share is below its minimum takes the minimum, and
                    // the rest is shared again, until every share is at least its minimum.
                    var held = [Bool](repeating: false, count: tile.windowIDs.count)
                    var changed = true
                    while changed {
                        changed = false
                        for (offset, windowID) in tile.windowIDs.enumerated()
                        where !held[offset] && observed(observedHeights[windowID]) == nil {
                            guard let minimum = observed(minimumHeights[windowID]) else { continue }
                            let share = flexibleWeight > 0
                                ? flexibleHeight * CGFloat(tile.heightWeights[offset] / flexibleWeight) : 0
                            guard share < minimum else { continue }
                            held[offset] = true
                            heldAtMinimum = held
                            fixedHeight += minimum
                            changed = true
                        }
                        // Summed again rather than subtracted, so no rounding residue
                        // is left to share once every member is held.
                        flexibleWeight = 0
                        for (offset, windowID) in tile.windowIDs.enumerated()
                        where !held[offset] && observed(observedHeights[windowID]) == nil {
                            flexibleWeight += tile.heightWeights[offset]
                        }
                        flexibleHeight = flexibleWeight > 0 ? max(0, availableFrame.height - gaps - fixedHeight) : 0
                    }
                }
                var y = availableFrame.midY - (fixedHeight + flexibleHeight + gaps) / 2
                for (offset, windowID) in tile.windowIDs.enumerated() {
                    let width = observed(observedWidths[windowID]) ?? requestedWidth
                    let minimum = heldAtMinimum?[offset] == true ? observed(minimumHeights[windowID]) : nil
                    let height = observed(observedHeights[windowID]) ?? minimum
                        ?? flexibleHeight * CGFloat(tile.heightWeights[offset] / flexibleWeight)
                    let frame = CGRect(x: cursor, y: y, width: width, height: height)
                    y += height + stackGap
                    if windowID == space.focusedWindowID { holdsFocus = true }
                    tileWidth = max(tileWidth, width)
                    totalWidth = max(totalWidth, frame.maxX)
                    ribbon.append((windowID: windowID, frame: frame))
                }
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

    /// The least height a stack of `windowIDs` can take: each member's known
    /// minimum height (none counts as zero) and the vertical gaps between them.
    public static func minimumStackHeight(
        windowIDs: [String],
        gap: CGFloat,
        minimumHeights: [String: CGFloat]
    ) -> CGFloat {
        let stackGap = gap.isFinite ? max(0, gap) : 8
        var height = stackGap * CGFloat(max(0, windowIDs.count - 1))
        for windowID in windowIDs {
            if let minimum = minimumHeights[windowID], minimum.isFinite, minimum > 0 { height += minimum }
        }
        return height
    }
}
