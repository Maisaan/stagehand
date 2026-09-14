import CoreGraphics
import Foundation

public struct WindowPlacement: Equatable, Sendable {
    public let windowID: String
    public let frame: CGRect
    public let isVisible: Bool
    public let isFocused: Bool
}

public enum WindowLayout {
    /// Uses the caller's coordinate system without converting between AppKit and Accessibility.
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
        let gap: CGFloat = state.maximizeWindows ? 0 : (gap.isFinite ? gap : 8)

        var cursor: CGFloat = 0
        var focusedStart: CGFloat = 0
        var focusedWidth: CGFloat = 0
        let ribbon = space.windowIDs.map { windowID in
            let requestedWidth = availableFrame.width * (state.maximizeWindows ? 1 : space.widthFraction(for: windowID))
            let width: CGFloat
            if let observedWidth = observedWidths[windowID], observedWidth.isFinite, observedWidth > 0 {
                width = observedWidth
            } else {
                width = requestedWidth
            }
            // Accepted app constraints take precedence over either requested size.
            // Keep the user's preferred height separate so maximizing cannot erase it.
            let preferredHeight = preferredHeights[windowID] ?? availableFrame.height
            let requestedHeight = !state.maximizeWindows && preferredHeight.isFinite && preferredHeight > 0
                ? preferredHeight : availableFrame.height
            let height: CGFloat
            if let observedHeight = observedHeights[windowID], observedHeight.isFinite, observedHeight > 0 {
                height = observedHeight
            } else {
                height = requestedHeight
            }
            let frame = CGRect(x: cursor, y: availableFrame.midY - height / 2, width: width, height: height)
            if windowID == space.focusedWindowID {
                focusedStart = cursor
                focusedWidth = width
            }
            cursor += max(1, width + gap)
            return (windowID: windowID, frame: frame)
        }
        let totalWidth = ribbon.map { $0.frame.maxX }.max() ?? 0
        let desiredOffset = gap < 0 ? focusedStart - (availableFrame.width - focusedWidth) / 2 : focusedStart
        let offset = min(max(0, desiredOffset), max(0, totalWidth - availableFrame.width))

        return ribbon.map { item in
            let frame = item.frame.offsetBy(dx: availableFrame.minX - offset, dy: 0)
            return WindowPlacement(
                windowID: item.windowID,
                frame: frame,
                isVisible: frame.intersects(availableFrame),
                isFocused: item.windowID == space.focusedWindowID
            )
        }
    }
}
