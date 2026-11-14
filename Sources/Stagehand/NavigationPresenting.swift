import AppKit
import StagehandCore
import StagehandPlatform

/// A managed display as the app bar sees it: its screen and the space it shows.
struct NavigationDisplay: Equatable {
    let id: DisplayID
    let number: CGDirectDisplayID
    let spaceIndex: Int
    let isFocused: Bool
}

/// The app bar, focus border, shortcut ribbon, and warnings, as used by the model. Tests use a
/// headless implementation so nothing appears on screen.
@MainActor
protocol NavigationPresenting: AnyObject {
    /// The space index is set when the bar showed another display's space, not the focused one.
    var onFocusWindow: ((String, Int?) -> Void)? { get set }
    var onSelectSpace: ((Int) -> Void)? { get set }
    var onShareWindow: ((String, Int) -> Void)? { get set }
    var onRemoveWindow: ((String, Int?) -> Void)? { get set }
    /// The managed displays: navigation shows the bar on the focused one, hover on the one hovered.
    var navigationDisplays: (() -> [NavigationDisplay])? { get set }
    var canRevealNavigation: (() -> Bool)? { get set }
    /// True while the pointer carries another app's drag-and-drop; the app bar then
    /// ignores the pointer so a drop near the notch reaches the window under it.
    var pointerCarriesDrop: (() -> Bool)? { get set }
    /// Called on every pointer move while set; setting it installs the pointer monitor.
    var onPointerMoved: (() -> Void)? { get set }

    func setBorderColor(_ color: NSColor)
    /// `sheet` is an attached sheet; the outline stops at its edge instead of crossing it.
    func updateBorder(frame: CGRect, sheet: CGRect?, visible: Bool, cornerRadius: CGFloat?,
                      focusChanged: Bool, raiseBorder: Bool)
    func showNavigation(state: WorkspaceState, windows: [WindowRecord])
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord])
    func showWarning(_ message: String)
    /// A brief note in the app bar, such as a refused tile change: shorter-lived than a
    /// warning, never takes focus, and the next navigation replaces it.
    func showNotice(_ message: String)
    func setShortcutHints(_ bindings: [ShortcutBinding], swipeTip: String?)
    func toggleShortcutHints()
    /// Hides and releases the panels; the next presentation creates them on the current Desktop.
    func hide()
    /// Hides the panels and keeps them for a resume on the same Desktop.
    func suspend()
}

extension NavigationPresenting {
    func updateBorder(frame: CGRect, visible: Bool) {
        updateBorder(frame: frame, sheet: nil, visible: visible, cornerRadius: nil,
                     focusChanged: false, raiseBorder: false)
    }
}

extension NavigationOverlays: NavigationPresenting {}
