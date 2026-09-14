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
        gap: CGFloat = 8
    ) -> [WindowPlacement] {
        guard !availableFrame.isEmpty, !availableFrame.isInfinite,
              availableFrame.origin.x.isFinite, availableFrame.origin.y.isFinite,
              availableFrame.width.isFinite, availableFrame.height.isFinite else { return [] }
        let space = state.currentSpace
        let gap = gap.isFinite ? max(0, gap) : 8

        if state.layoutMode == .monocle {
            return space.windowIDs.map { windowID in
                let focused = windowID == space.focusedWindowID
                return WindowPlacement(
                    windowID: windowID,
                    frame: focused ? availableFrame : CGRect(
                        x: availableFrame.maxX + gap,
                        y: availableFrame.minY,
                        width: availableFrame.width,
                        height: availableFrame.height
                    ),
                    isVisible: focused,
                    isFocused: focused
                )
            }
        }

        var cursor: CGFloat = 0
        var focusedStart: CGFloat = 0
        let ribbon = space.windowIDs.map { windowID in
            let width = availableFrame.width * space.widthFraction(for: windowID)
            let frame = CGRect(x: cursor, y: availableFrame.minY, width: width, height: availableFrame.height)
            if windowID == space.focusedWindowID { focusedStart = cursor }
            cursor += width + gap
            return (windowID: windowID, frame: frame)
        }
        let totalWidth = max(0, cursor - gap)
        let offset = min(focusedStart, max(0, totalWidth - availableFrame.width))

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
