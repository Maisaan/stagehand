import AppKit
import StagehandCore
import StagehandPlatform

/// The app bar, focus border, and warnings, as used by the model. Tests use a
/// headless implementation so nothing appears on screen.
@MainActor
protocol NavigationPresenting: AnyObject {
    var onFocusWindow: ((String) -> Void)? { get set }
    var onSelectSpace: ((Int) -> Void)? { get set }
    var onShareWindow: ((String, Int) -> Void)? { get set }
    var onRemoveWindow: ((String) -> Void)? { get set }
    var onReorderWindow: ((String, Int) -> Void)? { get set }
    var canRevealNavigation: (() -> Bool)? { get set }

    func setBorderColor(_ color: NSColor)
    func updateBorder(frame: CGRect, visible: Bool, cornerRadius: CGFloat?,
                      focusChanged: Bool, raiseBorder: Bool)
    func showNavigation(state: WorkspaceState, windows: [WindowRecord])
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord])
    func showWarning(_ message: String)
    func hide()
}

extension NavigationPresenting {
    func updateBorder(frame: CGRect, visible: Bool) {
        updateBorder(frame: frame, visible: visible, cornerRadius: nil, focusChanged: false, raiseBorder: false)
    }
}

extension NavigationOverlays: NavigationPresenting {}
