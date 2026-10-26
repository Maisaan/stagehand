import AppKit
import StagehandCore

/// The window operations Stagehand's model depends on. `WindowSystem` drives real
/// windows through Accessibility; tests supply an in-memory implementation.
@MainActor
public protocol WindowManaging: AnyObject {
    var onChange: (() -> Void)? { get set }
    /// A tracked app created a window; called instead of onChange for that notification.
    var onWindowCreated: (() -> Void)? { get set }
    var onFrameChange: ((String, CGRect) -> Void)? { get set }
    var onFocusedWindowChange: ((String) -> Void)? { get set }
    /// Whether an observed focus change would be used now; unused AX reads are skipped.
    var wantsObservedFocus: (() -> Bool)? { get set }
    /// Whether moved or resized windows' frames would be used now; unused AX reads are skipped.
    var wantsFrameChange: (() -> Bool)? { get set }
    /// Whether the window-list inventory poll may run now; it skips switches and gestures.
    var wantsInventory: (() -> Bool)? { get set }
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
    /// The focus the last read or confirmed focus attempt reported. For diagnostics
    /// that would otherwise read focus again, on the main thread, from a busy app.
    var lastObservedFocusedWindowID: String? { get }
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
    /// Ribbon motion: moves without waiting for the app; finishMotionWrites() waits for the last write.
    @discardableResult func setMotionPosition(windowID: String, position: CGPoint) -> Bool
    func finishMotionWrites() async
    /// Brings a window to the front without activating its app.
    func raiseWithoutActivating(windowID: String)
    func motionWriteStatistics(reset: Bool, focusedWindowID: String?) -> [String: String]
    @discardableResult func setFrame(windowID: String, frame: CGRect) -> Bool
    /// `remnantWidth` is the widest strip that may stay visible at the side for
    /// parking to count as confirmed; `WindowTuning.parkedRemnantWidth` by default.
    @discardableResult func park(windowID: String, preferredSide: WindowParkingSide?, remnantWidth: CGFloat) -> Bool

    func focusedWindowID() -> String?
    /// The same answer, read without waiting on the focused app on the main thread.
    func focusedWindowIDOffMain() async -> String?
    /// Whether the window's app is the active frontmost app, from AppKit without an
    /// Accessibility call. A window of any other app cannot be the focused window.
    func mayHoldFocus(windowID: String) -> Bool
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

