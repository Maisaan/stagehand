import AppKit
import StagehandCore

/// The window operations Stagehand's model depends on. `WindowSystem` drives real
/// windows through Accessibility; tests supply an in-memory implementation.
@MainActor
public protocol WindowManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    var onFrameChange: ((String, CGRect) -> Void)? { get set }
    var onFocusedWindowChange: ((String) -> Void)? { get set }
    /// Whether an observed focus change would be used now; unused AX reads are skipped.
    var wantsObservedFocus: (() -> Bool)? { get set }
    /// Whether a moved or resized window's frame would be used now; unused AX reads are skipped.
    var wantsFrameChange: ((String) -> Bool)? { get set }
    var onTitleChange: ((String, String) -> Void)? { get set }
    var onApplicationTerminated: ((pid_t) -> Void)? { get set }
    var onWindowDestroyed: ((String) -> Void)? { get set }
    var onWindowMiniaturized: ((String) -> Void)? { get set }
    var onWindowDeminiaturized: ((String) -> Void)? { get set }
    var onNativeDesktopChange: (() -> Void)? { get set }
    var onScreenParametersChange: (() -> Void)? { get set }
    /// A process without a Dock presence became active, usually to present a
    /// panel on behalf of the focused window.
    var onAccessoryActivation: ((pid_t) -> Void)? { get set }

    var isAccessibilityTrusted: Bool { get }
    var focusDiagnosticsEnabled: Bool { get set }
    var lastFocusReport: WindowFocusReport? { get }
    var trackedWindowIDs: Set<String> { get }
    var hasPendingRecovery: Bool { get }
    var pendingRecoveryWindowIDs: Set<String> { get }

    @discardableResult func registerOwnWindow(window: NSWindow) -> String
    func requestAccessibilityPermission()
    func recoverInterruptedSession() -> Bool
    @discardableResult func start() -> [WindowRecord]
    func stop()
    func scanWindows() -> [WindowRecord]
    /// Reads off the main thread; nil when windows changed during the read.
    func scanWindowsOffMain() async -> [WindowRecord]?
    func record(windowID: String) -> WindowRecord?

    func frame(windowID: String) -> CGRect?
    func observedFrame(windowID: String) -> CGRect?
    func windowNumber(for windowID: String) -> CGWindowID?
    func isParked(windowID: String) -> Bool
    func unavailability(windowID: String) -> WindowUnavailability?
    @discardableResult func setPosition(windowID: String, position: CGPoint) -> Bool
    @discardableResult func setFrame(windowID: String, frame: CGRect) -> Bool
    /// `remnantWidth` is the widest strip that may stay visible at the side for
    /// parking to count as confirmed; `WindowTuning.parkedRemnantWidth` by default.
    @discardableResult func park(windowID: String, preferredSide: WindowParkingSide?, remnantWidth: CGFloat) -> Bool

    func focusedWindowID() -> String?
    func focus(windowID: String) async -> Bool
    /// Centers the accessory process's frontmost panel over `anchor`, kept inside `bounds`.
    func centerCompanionPanel(pid: pid_t, over anchor: CGRect, within bounds: CGRect)
}

extension WindowSystem: WindowManaging {}

/// Keyboard shortcuts and trackpad gestures, as used by the model.
@MainActor
public protocol InputControlling: AnyObject {
    var onAction: ((NavigationAction) -> Void)? { get set }
    var onGesture: ((GestureNavigationEvent) -> Void)? { get set }
    var onStatusChange: (() -> Void)? { get set }
    var gesturesEnabled: Bool { get set }
    var shortcutSwipesEnabled: Bool { get set }
    var reverseShortcutSwipeDirection: Bool { get set }
    var issues: [String] { get }
    func start()
    func stop()
    func setShortcutBindings(_ bindings: [ShortcutBinding])
    func setShortcutCaptureActive(_ active: Bool)
    func takePendingGestureCompletion() -> GestureNavigationCompletion?
    func cancelGestureSequence()
}

extension InputController: InputControlling {}

public extension WindowManaging {
    @discardableResult
    func park(windowID: String, preferredSide: WindowParkingSide? = nil) -> Bool {
        park(windowID: windowID, preferredSide: preferredSide, remnantWidth: WindowTuning.parkedRemnantWidth)
    }
}
