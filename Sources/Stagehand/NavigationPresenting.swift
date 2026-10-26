import AppKit
import StagehandCore
import StagehandPlatform

/// The app bar, focus border, shortcut ribbon, and warnings, as used by the model. Tests use a
/// headless implementation so nothing appears on screen.
@MainActor
protocol NavigationPresenting: AnyObject {
    var onFocusWindow: ((String) -> Void)? { get set }
    var onSelectSpace: ((Int) -> Void)? { get set }
    var onShareWindow: ((String, Int) -> Void)? { get set }
    var onRemoveWindow: ((String) -> Void)? { get set }
    var onReorderWindow: ((String, Int) -> Void)? { get set }
    var canRevealNavigation: (() -> Bool)? { get set }
    /// True while the pointer carries another app's drag-and-drop; the app bar then
    /// ignores the pointer so a drop near the notch reaches the window under it.
    var pointerCarriesDrop: (() -> Bool)? { get set }

    func setBorderColor(_ color: NSColor)
    func updateBorder(frame: CGRect, visible: Bool, cornerRadius: CGFloat?,
                      focusChanged: Bool, raiseBorder: Bool)
    func showNavigation(state: WorkspaceState, windows: [WindowRecord])
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord])
    func showWarning(_ message: String)
    func setShortcutHints(_ bindings: [ShortcutBinding], swipeTip: String?)
    func toggleShortcutHints()
    /// Hides and releases the panels; the next presentation creates them on the current Desktop.
    func hide()
    /// Hides the panels and keeps them for a resume on the same Desktop.
    func suspend()
}

extension NavigationPresenting {
    func updateBorder(frame: CGRect, visible: Bool) {
        updateBorder(frame: frame, visible: visible, cornerRadius: nil, focusChanged: false, raiseBorder: false)
    }
}

extension NavigationOverlays: NavigationPresenting {}
