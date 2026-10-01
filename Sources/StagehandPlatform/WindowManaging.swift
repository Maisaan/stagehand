import AppKit
import StagehandCore

/// The window operations Stagehand's model depends on. `WindowSystem` drives real
/// windows through Accessibility; tests supply an in-memory implementation.
@MainActor
public protocol WindowManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    var onFrameChange: ((String, CGRect) -> Void)? { get set }
    var onFocusedWindowChange: ((String) -> Void)? { get set }
    var onTitleChange: ((String, String) -> Void)? { get set }
    var onApplicationTerminated: ((pid_t) -> Void)? { get set }
    var onWindowDestroyed: ((String) -> Void)? { get set }
    var onWindowMiniaturized: ((String) -> Void)? { get set }
    var onWindowDeminiaturized: ((String) -> Void)? { get set }
    var onNativeDesktopChange: (() -> Void)? { get set }
    var onScreenParametersChange: (() -> Void)? { get set }

    var isAccessibilityTrusted: Bool { get }
    var focusDiagnosticsEnabled: Bool { get set }
    var lastFocusReport: WindowFocusReport? { get }
    var trackedWindowIDs: Set<String> { get }
    var hasPendingRecovery: Bool { get }

    @discardableResult func registerOwnWindow(window: NSWindow) -> String
    func requestAccessibilityPermission()
    func recoverInterruptedSession() -> Bool
    @discardableResult func start() -> [WindowRecord]
    func stop()
    func scanWindows() -> [WindowRecord]
    func record(windowID: String) -> WindowRecord?

    func frame(windowID: String) -> CGRect?
    func observedFrame(windowID: String) -> CGRect?
    func windowNumber(for windowID: String) -> CGWindowID?
    func isParked(windowID: String) -> Bool
    func unavailability(windowID: String) -> WindowUnavailability?
    @discardableResult func setPosition(windowID: String, position: CGPoint) -> Bool
    @discardableResult func setFrame(windowID: String, frame: CGRect) -> Bool
    @discardableResult func park(windowID: String, preferredSide: WindowParkingSide?) -> Bool

    func focusedWindowID() -> String?
    func focus(windowID: String) async -> Bool
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
