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
    /// A column of one window is placed as a lone window always was: its observed
    /// or requested width, its observed or preferred height, centered vertically.
    /// A stack fills the available height, split by the members' height weights
    /// with a vertical gap of `max(0, gap)` (a negative gap only overlaps columns).
    /// A member with an observed height keeps it and the others share the rest;
    /// a stack shorter or taller than the available height stays centered. Each
    /// member is left-aligned in the column, whose slot is as wide as its widest
    /// member. `preferredHeights` apply only to a window alone in its column.
    public static func placements(
        for state: WorkspaceState,
        availableFrame: CGRect,
        gap: CGFloat = 8,
        observedWidths: [String: CGFloat] = [:],
        preferredHeights: [String: CGFloat] = [:],
        observedHeights: [String: CGFloat] = [:]
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
        for column in space.columns {
            let requestedWidth = availableFrame.width * column.widthFraction
            var slotWidth: CGFloat = 0
            var holdsFocus = false
            if column.windowIDs.count == 1 {
                let windowID = column.windowIDs[0]
                let width = observed(observedWidths[windowID]) ?? requestedWidth
                // Accepted app constraints take precedence over either requested size.
                let preferredHeight = preferredHeights[windowID] ?? availableFrame.height
                let requestedHeight = preferredHeight.isFinite && preferredHeight > 0
                    ? preferredHeight : availableFrame.height
                let height = observed(observedHeights[windowID]) ?? requestedHeight
                let frame = CGRect(x: cursor, y: availableFrame.midY - height / 2, width: width, height: height)
                holdsFocus = windowID == space.focusedWindowID
                slotWidth = width
                totalWidth = max(totalWidth, frame.maxX)
                ribbon.append((windowID: windowID, frame: frame))
            } else {
                let gaps = stackGap * CGFloat(column.windowIDs.count - 1)
                var fixedHeight: CGFloat = 0
                var flexibleWeight = 0.0
                for (offset, windowID) in column.windowIDs.enumerated() {
                    if let height = observed(observedHeights[windowID]) {
                        fixedHeight += height
                    } else {
                        flexibleWeight += column.heightWeights[offset]
                    }
                }
                let flexibleHeight = flexibleWeight > 0 ? max(0, availableFrame.height - gaps - fixedHeight) : 0
                var y = availableFrame.midY - (fixedHeight + flexibleHeight + gaps) / 2
                for (offset, windowID) in column.windowIDs.enumerated() {
                    let width = observed(observedWidths[windowID]) ?? requestedWidth
                    let height = observed(observedHeights[windowID])
                        ?? flexibleHeight * CGFloat(column.heightWeights[offset] / flexibleWeight)
                    let frame = CGRect(x: cursor, y: y, width: width, height: height)
                    y += height + stackGap
                    if windowID == space.focusedWindowID { holdsFocus = true }
                    slotWidth = max(slotWidth, width)
                    totalWidth = max(totalWidth, frame.maxX)
                    ribbon.append((windowID: windowID, frame: frame))
                }
            }
            // A focus change inside a column keeps the column's slot, so it never
            // scrolls the ribbon.
            if holdsFocus {
                focusedStart = cursor
                focusedWidth = slotWidth
            }
            cursor += max(1, slotWidth + gap)
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
}
