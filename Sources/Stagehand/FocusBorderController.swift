import AppKit
import StagehandPlatform

/// Draws the focus border over one window and caches that window's native corner shape.
@MainActor
final class FocusBorderController {
    private let overlays: any NavigationPresenting
    private let windowNumber: (String) -> CGWindowID?
    private(set) var windowID: String?
    private(set) var cornerRadius: CGFloat?
    private var cachedWindowNumber: CGWindowID?
    private var cornerRadiusResolved = false
    private var radiusFrameSize: CGSize?

    init(overlays: any NavigationPresenting, windowNumber: @escaping (String) -> CGWindowID?) {
        self.overlays = overlays
        self.windowNumber = windowNumber
    }

    /// `refreshShape` re-reads the corner radius when the size changed or it is still
    /// unresolved. A new window identity always reads it.
    func show(windowID: String, frame: CGRect, color: NSColor,
              refreshShape: Bool = true, raise: Bool = false) {
        overlays.setBorderColor(color)
        let changed = self.windowID != windowID
        let number = windowNumber(windowID)
        let identityChanged = changed || cachedWindowNumber != number
        let sizeChanged = radiusFrameSize != frame.size
        if identityChanged || (refreshShape && (!cornerRadiusResolved || sizeChanged)) {
            self.windowID = windowID
            cachedWindowNumber = number
            radiusFrameSize = frame.size
            if let radius = number.flatMap({ WindowCornerRadius.cornerRadius(windowNumber: $0) }) {
                cornerRadius = radius
                cornerRadiusResolved = true
            } else {
                if identityChanged { cornerRadius = nil }
                cornerRadiusResolved = false
            }
        }
        overlays.updateBorder(
            frame: frame,
            visible: true,
            cornerRadius: cornerRadius,
            focusChanged: changed,
            raiseBorder: raise || identityChanged
        )
    }

    func hide() {
        reset()
        overlays.updateBorder(frame: .zero, visible: false)
    }

    /// Forgets the cached window without changing what is on screen.
    func reset() {
        windowID = nil
        cachedWindowNumber = nil
        cornerRadius = nil
        cornerRadiusResolved = false
        radiusFrameSize = nil
    }
}
