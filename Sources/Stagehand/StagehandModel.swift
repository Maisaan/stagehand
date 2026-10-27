import AppKit
import Combine
import ServiceManagement
import StagehandCore
import StagehandPlatform

/// UserDefaults keys owned by the model. Keep every literal here so a renamed
/// key cannot silently split a preference between its reader and writer.
enum PreferenceKey {
    static let gesturesEnabled = "gesturesEnabled"
    static let shortcutSwipesEnabled = "shortcutSwipesEnabled"
    static let reverseShortcutSwipeDirection = "reverseShortcutSwipeDirection"
    static let windowGap = "windowGap"
    static let diagnosticLoggingEnabled = "diagnosticLoggingEnabled"
    static let legacyFocusBorderColor = "focusBorderColor"
    static let focusBorderColors = "focusBorderColors"
    static let widthPresets = "widthPresets"
    static let wideParkedEdgeBundleIdentifiers = "wideParkedEdgeBundleIdentifiers"
    static let wideParkedEdgeWidth = "wideParkedEdgeWidth"
}

@MainActor
final class StagehandModel: ObservableObject {
    // Written only by StagehandModel and its extensions; views treat these as read-only.
    @Published internal(set) var state = WorkspaceState() {
        didSet { if isRunning, state != oldValue { scheduleLayoutSave() } }
    }
    @Published internal(set) var windows: [WindowRecord] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isSuspended = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var inputIssues: [String] = []
    @Published internal(set) var warning: String? {
        didSet {
            if let warning, !isSuspended { overlays.showWarning(warning) }
        }
    }
    @Published var gesturesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gesturesEnabled, forKey: PreferenceKey.gesturesEnabled)
            input.gesturesEnabled = gesturesEnabled && !isSuspended
            updateInputStatus()
        }
    }
    @Published var shortcutSwipesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(shortcutSwipesEnabled, forKey: PreferenceKey.shortcutSwipesEnabled)
            input.shortcutSwipesEnabled = shortcutSwipesEnabled && !isSuspended
            updateShortcutHints()
            updateInputStatus()
        }
    }
    @Published var reverseShortcutSwipeDirection: Bool {
        didSet {
            UserDefaults.standard.set(reverseShortcutSwipeDirection, forKey: PreferenceKey.reverseShortcutSwipeDirection)
            input.reverseShortcutSwipeDirection = reverseShortcutSwipeDirection
            updateShortcutHints()
            updateInputStatus()
        }
    }
    @Published var gap: Double {
        didSet {
            UserDefaults.standard.set(gap, forKey: PreferenceKey.windowGap)
            if isRunning && !isSuspended { enqueue(.preferences) }
        }
    }
    /// Width fractions the preset shortcuts step through; see `SpaceState.normalizedWidthPresets`.
    @Published var widthPresets: [Double] {
        didSet {
            // Observers re-enter on assignment for a wrapped property; normalize once.
            let normalized = SpaceState.normalizedWidthPresets(widthPresets)
            if normalized != widthPresets { widthPresets = normalized; return }
            UserDefaults.standard.set(widthPresets, forKey: PreferenceKey.widthPresets)
        }
    }
    /// Apps whose parked windows may keep a strip up to `wideParkedEdgeWidth` visible
    /// instead of failing the layout. For apps that clamp their windows onscreen.
    @Published var wideParkedEdgeBundleIdentifiers: [String] {
        didSet {
            var seen = Set<String>()
            let normalized = wideParkedEdgeBundleIdentifiers.filter { !$0.isEmpty && seen.insert($0).inserted }
            if normalized != wideParkedEdgeBundleIdentifiers { wideParkedEdgeBundleIdentifiers = normalized; return }
            UserDefaults.standard.set(wideParkedEdgeBundleIdentifiers,
                                      forKey: PreferenceKey.wideParkedEdgeBundleIdentifiers)
        }
    }
    @Published var wideParkedEdgeWidth: Double {
        didSet {
            let clamped = Self.clampedWideParkedEdgeWidth(wideParkedEdgeWidth)
            if clamped != wideParkedEdgeWidth { wideParkedEdgeWidth = clamped; return }
            UserDefaults.standard.set(wideParkedEdgeWidth, forKey: PreferenceKey.wideParkedEdgeWidth)
        }
    }
    @Published private(set) var focusBorderColors: [NSColor]
    @Published private(set) var shortcutBindings: [ShortcutBinding]

    static let wideParkedEdgeWidthBounds: ClosedRange<Double> =
        Double(WindowTuning.parkedRemnantWidth)...Double(WindowTuning.maximumParkedRemnantWidth)
    static let defaultWideParkedEdgeWidth: Double = 240

    static func clampedWideParkedEdgeWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWideParkedEdgeWidth }
        return min(max(value.rounded(), wideParkedEdgeWidthBounds.lowerBound), wideParkedEdgeWidthBounds.upperBound)
    }

    /// The visible strip parking may leave for a window of this app.
    func parkedRemnantWidth(forBundleIdentifier bundleIdentifier: String) -> CGFloat {
        wideParkedEdgeBundleIdentifiers.contains(bundleIdentifier)
            ? CGFloat(wideParkedEdgeWidth) : WindowTuning.parkedRemnantWidth
    }

    var focusBorderColor: NSColor {
        focusBorderColor(forSpace: state.activeSpaceIndex)
    }
    let ribbonAnimationConfiguration = RibbonAnimationConfiguration.default
    @Published var diagnosticLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticLoggingEnabled, forKey: PreferenceKey.diagnosticLoggingEnabled)
            windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
            mainThreadWatchdog?.setEnabled(diagnosticLoggingEnabled)
            resourceSampler?.setEnabled(diagnosticLoggingEnabled)
            if diagnosticLoggingEnabled {
                diagnostics.isEnabled = true
                diagnostics.record("logging_enabled")
            } else {
                diagnostics.record("logging_disabled")
                diagnostics.isEnabled = false
            }
        }
    }

    var showSettings: (() -> Void)?
    var onStateChange: (() -> Void)?
    let windowSystem: any WindowManaging
    let desktopScope: DesktopScope
    let input: any InputControlling
    let focusGate: FocusInputGate
    let overlays: any NavigationPresenting
    let diagnostics: DiagnosticLogger
    let ribbonMotion: RibbonMotion
    /// Whether a held left button is carrying a drag-and-drop or moving a window.
    let pointer: PointerDragTracker
    var presentationFrames: [String: CGRect]?
    var gestureBase: [String: CGRect]? {
        didSet { gesturePreviewCache = nil }
    }
    /// The last complete preview. Resting fingers repeat a displacement every display tick.
    var gesturePreviewCache: (displacement: Double, frames: [String: CGRect])?
    var gesturePrepared: Set<String> = []
    /// Windows whose first preview move was refused and whose frame could not be read:
    /// closing, or their app is not answering. The preview stops retrying them.
    var gestureUnwritable: Set<String> = []
    var gestureAxis: GestureAxis?
    var motionWrittenPositions: [String: CGPoint] = [:]
    var motionBackingScaleFactor: CGFloat = 1
    let emptySpace: any EmptySpacePresenting
    var refreshTask: Task<Void, Never>?
    /// While paused with window recovery pending: notification tokens and a fallback
    /// timer that retry it when the user returns to the windows' Desktop.
    var recoveryWatchTokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var recoveryWatchTask: Task<Void, Never>?
    /// Start once pending recovery completes: set at launch when the previous session
    /// ended by quitting, the case in which launch would have started.
    var startAfterRecovery = false
    /// How the last session ended: a pause or quit reason, written by stop and cleared by
    /// start, so a crash leaves none. Read at launch to decide startAfterRecovery.
    static let lastSessionEndKey = "StagehandLastSessionEnd"
    static var lastSessionEnd: String? { UserDefaults.standard.string(forKey: lastSessionEndKey) }
    /// Which refresh task is reading windows right now, and whether a change arrived
    /// during that read, so it scans once more instead of being cancelled.
    var refreshGeneration = 0
    var refreshScanningGeneration: Int?
    var refreshRescanRequested = false
    /// Refresh attempts (busy waits and stale scans together) before the loop
    /// gives up and logs refresh_starved.
    var refreshRetryLimit = 60
    /// Stale off-main scans before one refresh falls back to a synchronous scan.
    var refreshStaleScanFallback = 3
    let layoutStore: WorkspaceLayoutStore?
    var layoutSaveTask: Task<Void, Never>?
    /// The saved layout is applied only to the first start after launch. Later
    /// starts resume the in-memory layout.
    var savedLayoutConsidered = false
    var observedFocusTask: Task<Void, Never>?
    let changes = ChangeQueue<PendingChange>()
    var lastAppliedFrames: [String: CGRect] = [:]
    /// Where each window is as far as Stagehand knows: the frame its last layout
    /// wrote and verified, or the last scan reported. A slide starts from these
    /// instead of reading every window's frame again from its app.
    var knownFrames: [String: CGRect] = [:]
    var preferredHeights: [String: CGFloat] = [:] {
        didSet { if isRunning, preferredHeights != oldValue { scheduleLayoutSave() } }
    }
    var lastTransition = Date.distantPast
    var automaticResumeTask: Task<Void, Never>?
    var automaticResumeAttempted = false
    var recoveryInProgress = false
    var desktopCheckTask: Task<Void, Never>?
    var sleepObserver: NSObjectProtocol?
    var unlockObserver: NSObjectProtocol?
    var lockObserver: NSObjectProtocol?
    /// Logs main-thread stalls while diagnostic logging is on (the app session only).
    var mainThreadWatchdog: MainThreadWatchdog?
    var resourceSampler: ResourceSampler?
    /// AXIsProcessTrusted() is cheap; macOS sends no notification when the user
    /// revokes Accessibility, and didBecomeActive only fires when Stagehand's own
    /// windows come forward.
    var accessibilityMonitorTask: Task<Void, Never>?
    var accessibilityPollInterval: Duration = .seconds(2)
    static let accessibilityRevokedWarning = "macOS revoked Stagehand's Accessibility permission, so Stagehand paused and restored your windows. Allow Stagehand in Privacy & Security > Accessibility, then press Start."
    static let accessibilityRevokedPendingWarning = "macOS revoked Stagehand's Accessibility permission, so Stagehand paused. Some windows couldn't be moved back without it; they return once you allow Stagehand in Privacy & Security > Accessibility again."
    /// Where the ribbon lives. Tests substitute a screen; the app uses the built-in display only.
    var builtInScreenProvider: @MainActor () -> NSScreen? = StagehandModel.builtInDisplay
    var displayCheckTask: Task<Void, Never>?
    /// Display sets change in steps (clamshell, wake, a cable). Wait this long
    /// after the built-in display disappears before pausing on it.
    var displayCheckDelay: Duration = .seconds(1)
    /// Consecutive checks that found no Desktop identity. The first few repeat
    /// quickly for the unlock case; after that, checks slow down and session
    /// notifications carry the recovery.
    var desktopCheckAttempts = 0
    static let quickDesktopChecks = 6
    /// Checks left at the unlock interval. Unlocking posts a notification, but
    /// WindowServer can keep reporting the lock for a moment after it.
    var unlockDesktopChecks = 0
    static let unlockDesktopCheckCount = 40
    var desktopCheckDelay: Duration {
        if unlockDesktopChecks > 0 { return .milliseconds(50) }
        return desktopCheckAttempts <= Self.quickDesktopChecks ? .milliseconds(500) : .seconds(5)
    }
    var workspaceRestoration = WorkspaceRestoration()
    var focusHistory = WindowFocusHistory()
    /// Windows that left the ribbon by minimizing. When one returns, it joins next
    /// to the focused window instead of its old slot.
    var minimizedWindowIDs: Set<String> = []
    var lastLayoutMilliseconds = 0
    var lastFocusTokenExpired = false
    var pointerInteraction: PointerInteraction?
    lazy var focusBorder = FocusBorderController(overlays: overlays) { [weak self] in
        self?.windowSystem.windowNumber(for: $0)
    }
    var isLayingOutWindows = false
    var preferencesNeedLayout = false
    var isRecordingShortcut = false

    struct PointerInteraction {
        let windowID: String
        let placements: [WindowPlacement]
        var needsLayout: Bool
    }

    enum Change: Equatable {
        case action(NavigationAction)
        case remove(String)
        case share(windowID: String, spaceIndex: Int)
        case focus(String)
        case moveMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int)
        case shareMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int)
        case removeMembership(windowID: String, fromSpaceIndex: Int)
        case reorderWindow(windowID: String, toIndex: Int, spaceIndex: Int)
        case focusInSpace(windowID: String, spaceIndex: Int)
        case observedFocus(String)
        case windowRemoval
        case refresh
        case preferences

        var policy: LayoutRequestPolicy {
            switch self {
            case .preferences, .observedFocus, .moveMembership,
                 .shareMembership, .removeMembership, .reorderWindow: .preferences
            default: .navigation
            }
        }

        var isWindowNavigation: Bool {
            self == .action(.focusNext) || self == .action(.focusPrevious)
        }

        var ribbonTransitionSource: RibbonTransitionSource {
            if case .observedFocus = self { return .observedFocus }
            if case .windowRemoval = self { return .windowRemoval }
            return .managed
        }

        var diagnosticName: String {
            switch self {
            case .action(let action): "action.\(action)"
            case .remove: "removeMembership"
            case .share: "shareMembership"
            case .focus: "focusWindow"
            case .moveMembership: "moveMembershipFromSettings"
            case .shareMembership: "shareMembershipFromSettings"
            case .removeMembership: "removeMembershipFromSettings"
            case .reorderWindow: "reorderWindow"
            case .focusInSpace: "focusWindowFromSettings"
            case .observedFocus: "observedFocus"
            case .windowRemoval: "windowRemoval"
            case .refresh: "refresh"
            case .preferences: "preferences"
            }
        }

        var focusesAlongsideRibbon: Bool { self == .windowRemoval }
    }

    struct PendingChange {
        let change: Change
        let token: UInt64?
        let initialHorizontalVelocity: CGFloat?
        let previousState: WorkspaceState?
        let motionStart: [String: CGRect]?
    }

    /// Whether this model may read and write the user's saved layout.
    enum Persistence: Equatable {
        /// The normal app session.
        case standard
        /// Diagnostic and acceptance runs: they start and pause against
        /// disposable windows and must not replace the real saved layout.
        case ephemeral
    }

    init(
        overlays: any NavigationPresenting = NavigationOverlays(),
        diagnostics: DiagnosticLogger? = nil,
        windowSystem injectedWindowSystem: (any WindowManaging)? = nil,
        input injectedInput: (any InputControlling)? = nil,
        emptySpace injectedEmptySpace: (any EmptySpacePresenting)? = nil,
        desktopScope: DesktopScope = DesktopScope(),
        focusGate: FocusInputGate = FocusInputGate(),
        ribbonMotion: RibbonMotion = RibbonMotion(),
        pointer: PointerDragTracker = PointerDragTracker(),
        layoutStore: WorkspaceLayoutStore? = nil,
        persistence: Persistence = .standard
    ) {
        windowSystem = injectedWindowSystem ?? WindowSystem()
        // An injected window system means a test run and an ephemeral model a
        // diagnostic run; neither may read or replace the user's saved layout
        // unless given a store explicitly.
        self.layoutStore = layoutStore
            ?? (injectedWindowSystem == nil && persistence == .standard ? WorkspaceLayoutStore() : nil)
        emptySpace = injectedEmptySpace ?? EmptySpaceWindow()
        self.desktopScope = desktopScope
        self.focusGate = focusGate
        self.ribbonMotion = ribbonMotion
        self.pointer = pointer
        self.overlays = overlays
        let defaults = UserDefaults.standard
        let shortcutLoad = ShortcutBinding.loadReportingIssues(from: defaults)
        let shortcutBindings = shortcutLoad.bindings
        self.shortcutBindings = shortcutBindings
        input = injectedInput ?? InputController(shortcutBindings: shortcutBindings,
                                                 shortcutLoadIssues: shortcutLoad.issues)
        diagnosticLoggingEnabled = defaults.bool(forKey: PreferenceKey.diagnosticLoggingEnabled)
        self.diagnostics = diagnostics ?? DiagnosticLogger(
            enabled: defaults.bool(forKey: PreferenceKey.diagnosticLoggingEnabled)
        )
        gesturesEnabled = defaults.object(forKey: PreferenceKey.gesturesEnabled) as? Bool ?? false
        shortcutSwipesEnabled = defaults.bool(forKey: PreferenceKey.shortcutSwipesEnabled)
        reverseShortcutSwipeDirection = defaults.object(forKey: PreferenceKey.reverseShortcutSwipeDirection) as? Bool ?? true
        gap = GapInput.clamped(defaults.object(forKey: PreferenceKey.windowGap) as? Double ?? 8)
        widthPresets = SpaceState.normalizedWidthPresets(
            defaults.array(forKey: PreferenceKey.widthPresets) as? [Double] ?? SpaceState.defaultWidthPresets
        )
        wideParkedEdgeBundleIdentifiers = defaults.stringArray(forKey: PreferenceKey.wideParkedEdgeBundleIdentifiers) ?? []
        wideParkedEdgeWidth = Self.clampedWideParkedEdgeWidth(
            defaults.object(forKey: PreferenceKey.wideParkedEdgeWidth) as? Double ?? Self.defaultWideParkedEdgeWidth
        )
        let defaultBorderColor = Self.savedColor(
            forKey: PreferenceKey.legacyFocusBorderColor,
            in: defaults,
            alpha: BorderView.defaultColor.alphaComponent
        ) ?? BorderView.defaultColor
        focusBorderColors = Self.savedColors(
            forKey: PreferenceKey.focusBorderColors,
            count: WorkspaceState.spaceCount,
            in: defaults,
            alpha: BorderView.defaultColor.alphaComponent
        ) ?? Array(repeating: defaultBorderColor, count: WorkspaceState.spaceCount)
        input.reverseShortcutSwipeDirection = reverseShortcutSwipeDirection
        input.onAction = { [weak self] action in self?.navigate(action) }
        input.onGesture = { [weak self] event in self?.handleGesture(event) }
        overlays.onFocusWindow = { [weak self] id in self?.focusWindow(id) }
        overlays.onSelectSpace = { [weak self] index in self?.navigate(.goToSpace(index: index)) }
        overlays.onShareWindow = { [weak self] id, index in
            self?.shareMembership(windowID: id, spaceIndex: index)
        }
        overlays.onRemoveWindow = { [weak self] id in self?.removeMembership(windowID: id) }
        overlays.canRevealNavigation = { [weak self] in
            guard let self, self.isRunning, !self.isSuspended else { return false }
            return self.desktopScope.refresh() == .home
        }
        pointer.onDragAndDropEnded = { [weak self] details in
            self?.diagnostics.record("drag_and_drop_ended", details: details)
        }
        overlays.pointerCarriesDrop = { [weak self] in
            guard let self else { return false }
            return self.pointer.isButtonDown && self.pointer.isDragAndDrop
        }
        overlays.setBorderColor(focusBorderColor)
        updateShortcutHints()
        input.onStatusChange = { [weak self] in self?.updateInputStatus() }
        windowSystem.onChange = { [weak self] in self?.scheduleRefresh() }
        // A new window is what a launch waits for; moves and resizes come in bursts
        // and keep the debounce.
        windowSystem.onWindowCreated = { [weak self] in self?.scheduleRefresh(immediately: true) }
        windowSystem.onApplicationTerminated = { [weak self] pid in
            self?.applicationTerminated(pid: pid)
        }
        windowSystem.onWindowDestroyed = { [weak self] id in
            self?.windowDestroyed(windowID: id)
        }
        windowSystem.onWindowMiniaturized = { [weak self] id in
            self?.windowMiniaturized(windowID: id)
        }
        windowSystem.onWindowDeminiaturized = { [weak self] id in
            self?.windowDeminiaturized(windowID: id)
        }
        windowSystem.onFocusedWindowChange = { [weak self] id in self?.observedFocusChanged(windowID: id) }
        windowSystem.onTitleChange = { [weak self] id, title in self?.windowTitleChanged(windowID: id, title: title) }
        windowSystem.wantsObservedFocus = { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.isSuspended && !self.changes.isProcessing && self.gestureBase == nil
        }
        windowSystem.wantsFrameChange = { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.isSuspended && !self.isLayingOutWindows && !self.ribbonMotion.isRunning
                && self.gestureBase == nil && self.focusBorder.windowID != nil
        }
        windowSystem.wantsInventory = { [weak self] in
            guard let self else { return false }
            return !self.changes.isProcessing && !self.ribbonMotion.isRunning && self.gestureBase == nil
        }
        windowSystem.onFrameChange = { [weak self] id, frame in
            guard let self, self.windowSystem.wantsFrameChange?() == true,
                  self.focusBorder.windowID == id, self.state.focusedWindowID == id else { return }
            guard self.desktopScope.refresh() == .home else {
                self.nativeDesktopChanged()
                return
            }
            // Geometry follows native notifications immediately. Corner metadata is
            // refreshed by the coalesced reconciliation after the resize settles.
            self.updateFocusBorder(windowID: id, frame: frame, refreshShape: false)
        }
        windowSystem.onAccessoryActivation = { [weak self] pid in
            guard let self, self.isRunning, !self.isSuspended, let focused = self.focusedWindow,
                  let anchor = self.windowSystem.frame(windowID: focused.id),
                  let bounds = self.availableFrame else { return }
            self.windowSystem.centerCompanionPanel(pid: pid, over: anchor, within: bounds)
        }
        windowSystem.onNativeDesktopChange = { [weak self] in
            self?.nativeDesktopChanged()
        }
        windowSystem.onScreenParametersChange = { [weak self] in
            self?.screenParametersChanged()
        }
        windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
        if persistence == .standard, injectedWindowSystem == nil {
            mainThreadWatchdog = MainThreadWatchdog { [weak self] waited, activity, measured in
                guard let self else { return }
                let last = self.diagnostics.lastEvent
                self.diagnostics.record("main_thread_stall", details: [
                    "waitedMilliseconds": String(waited),
                    "activity": activity,
                    "lastEvent": last?.name ?? "none",
                    "lastEventAgeMilliseconds": last.map {
                        String(Int((ProcessInfo.processInfo.systemUptime - $0.uptime) * 1_000))
                    } ?? "none",
                    "running": String(self.isRunning),
                    "ribbonMoving": String(self.ribbonMotion.isRunning),
                    "changeRunning": String(self.changes.isProcessing)
                ].merging(measured) { current, _ in current })
            }
            resourceSampler = ResourceSampler { [weak self] name, details in
                self?.diagnostics.record(name, details: details)
            }
            mainThreadWatchdog?.setEnabled(diagnosticLoggingEnabled)
            resourceSampler?.setEnabled(diagnosticLoggingEnabled)
        }
        ribbonMotion.onStall = { [weak self] in
            self?.diagnostics.record("ribbon_animation_stalled")
        }
        refreshLaunchAtLogin()
        focusGate.onNavigationAction = { [weak self] action in self?.navigate(action) }
        focusGate.setShortcutBindings(shortcutBindings)
        focusGate.setPendingGestureCompletionCheck { InputController.hasPendingGestureCompletion() }
        focusGate.onBeforeKeyboardEvent = { [weak self] in
            guard let self, self.isRunning, !self.isSuspended else { return }
            while let completion = self.input.takePendingGestureCompletion() {
                self.finishGesture(
                    axis: completion.axis,
                    displacement: completion.displacement,
                    velocity: completion.velocity,
                    recognizerAction: completion.recognizerAction,
                    mode: completion.mode
                )
            }
        }
        focusGate.onAvailabilityChanged = { [weak self] in self?.updateInputStatus() }
        (input as? InputController)?.navigationChordsHandledByTap = { [weak self] in self?.focusGate.isAvailable ?? false }
        focusGate.onInputDiscarded = { [weak self] count in
            self?.diagnostics.record("held_input_discarded", details: ["eventCount": String(count)])
            self?.warning = "Stagehand couldn't confirm the new window, so it did not send \(count) buffered key \(count == 1 ? "event" : "events"). Check your last input."
            NSSound.beep()
        }
        // The gate has already dropped any held keys, the only thing the deadline
        // protects. The switch itself keeps going: an expired timer means the system
        // was slow, not that Stagehand lost track of its windows.
        focusGate.onTransferExpired = { [weak self] token in
            guard let self else { return }
            self.expiredTokens.insert(token)
            self.diagnostics.record("input_transfer_expired", details: [
                "token": String(token),
                "changeRunning": String(self.changes.isProcessing)
            ])
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        }
        // Unlocking the screen posts no NSWorkspace notification. Without this, a
        // long lock leaves resume to the 5 s backoff check.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.desktopScope.invalidate()
                self?.diagnostics.record("screen_locked", details: [
                    "running": String(self?.isRunning ?? false)
                ])
            }
        }
        self.diagnostics.record("session_started")
        refreshPermissions()
        startAccessibilityMonitor()
    }

    func startAccessibilityMonitor() {
        accessibilityMonitorTask?.cancel()
        accessibilityMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await Task.sleep(for: self.accessibilityPollInterval) } catch { return }
                guard !Task.isCancelled else { return }
                self.checkAccessibility()
            }
        }
    }

    /// One poll. A revocation while running pauses; a grant after a revocation
    /// restores windows the pause could not move back.
    func checkAccessibility() {
        let trusted = windowSystem.isAccessibilityTrusted
        guard trusted != accessibilityGranted else { return }
        if trusted {
            accessibilityGranted = true
            diagnostics.record("accessibility_granted", details: ["running": String(isRunning)])
            if !isRunning, recoverInterruptedSession() == false {
                warning = nil
            }
            updateInputStatus()
            onStateChange?()
        } else {
            accessibilityRevoked()
        }
    }

    func accessibilityRevoked() {
        let wasRunning = isRunning
        diagnostics.record("accessibility_revoked", details: workspaceDetails())
        // Pausing restores frames; without the permission the AX writes fail,
        // the recovery journal keeps the original frames, and the next grant
        // replays them.
        if isRunning { stop(reason: "accessibility_revoked", automatic: false) }
        accessibilityGranted = false
        updateInputStatus()
        if wasRunning {
            warning = windowSystem.hasPendingRecovery
                ? Self.accessibilityRevokedPendingWarning
                : Self.accessibilityRevokedWarning
        }
        onStateChange?()
    }

    /// The Mac is about to sleep. A ribbon animation or a focus confirmation in
    /// flight would otherwise resume against stale frames after wake, or stall
    /// until its deadline. Drop the in-flight work and roll the layout back to
    /// the last completed transition; the wake notification already triggers a
    /// refresh, and the cleared applied frames make that refresh lay out again
    /// instead of reading half-moved windows as a user drag.
    func systemWillSleep() {
        desktopScope.invalidate()
        guard isRunning else { return }
        diagnostics.record("system_will_sleep", details: workspaceDetails())
        guard !isSuspended else { return }
        changes.cancel()
        refreshTask?.cancel()
        observedFocusTask?.cancel()
        ribbonMotion.cancel()
        presentationFrames = nil
        resetGestureTracking()
        focusGate.cancelAll()
        workspaceRestoration.rollBack(state: &state, windowIDs: windows.map(\.id),
                                      trackedWindowIDs: windowSystem.trackedWindowIDs)
        pointerInteraction = nil
        lastAppliedFrames.removeAll()
        knownFrames.removeAll()
        preferencesNeedLayout = true
        onStateChange?()
    }

    var expiredTokens: Set<UInt64> = []

    var focusedWindow: WindowRecord? { windows.first { $0.id == state.focusedWindowID } }

    func registerSettingsWindow(_ window: NSWindow) {
        _ = windowSystem.registerOwnWindow(window: window)
        if isRunning && !isSuspended { scheduleRefresh() }
    }

    func actualWidthPercent(for window: WindowRecord) -> Int? {
        guard isRunning, let availableFrame, availableFrame.width > 0 else { return nil }
        return Int((window.frame.width / availableFrame.width * 100).rounded())
    }

    func refreshPermissions() {
        let trusted = windowSystem.isAccessibilityTrusted
        if isRunning, !trusted {
            accessibilityRevoked()
            return
        }
        accessibilityGranted = trusted
        if isRunning, !isSuspended { focusGate.start() }
        updateInputStatus()
    }

    func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        defer { refreshLaunchAtLogin() }

        if enabled {
            switch service.status {
            case .enabled:
                return
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }

    func requestAccessibility() {
        windowSystem.requestAccessibilityPermission()
        refreshPermissions()
    }

    @discardableResult
    func recoverInterruptedSession() -> Bool {
        guard accessibilityGranted else { return false }
        let interrupted = windowSystem.recoverInterruptedSession()
        if !isRunning, windowSystem.hasPendingRecovery { armRecoveryWatch() }
        if interrupted {
            diagnostics.record("crash_recovery", details: [
                "pending": String(windowSystem.hasPendingRecovery),
                "pendingIDs": windowSystem.pendingRecoveryWindowIDs.sorted().joined(separator: ",")
            ])
            warning = windowSystem.hasPendingRecovery
                ? "Stagehand found an earlier window session but couldn't restore every window. Try Start after its apps respond or the other Stagehand instance exits."
                : "Stagehand restored windows after an interrupted session. Press Start when you're ready."
        }
        return interrupted
    }

    func start() { start(automaticRecovery: false) }

    func start(automaticRecovery: Bool) {
        if !automaticRecovery {
            automaticResumeTask?.cancel()
            automaticResumeTask = nil
            automaticResumeAttempted = false
            recoveryInProgress = false
            if !isRunning { desktopScope.reset() }
        }
        refreshPermissions()
        guard accessibilityGranted else {
            diagnostics.record("start_failed", details: ["reason": "accessibility_permission_missing"])
            warning = "Allow Stagehand in Accessibility settings, then start it again."
            return
        }
        guard !isRunning else { return }
        _ = windowSystem.recoverInterruptedSession()
        guard !windowSystem.hasPendingRecovery else {
            diagnostics.record("start_failed", details: ["reason": "window_recovery_pending"])
            warning = "Stagehand couldn't restore every window from its interrupted session. Try Start again when their apps respond."
            return
        }
        guard builtInScreen != nil else {
            diagnostics.record("start_failed", details: [
                "reason": "built_in_display_unavailable", "screenCount": String(NSScreen.screens.count)
            ])
            warning = "Stagehand manages only the built-in display, and none is available right now. Open the lid or disconnect from clamshell mode, then start it again."
            return
        }
        guard desktopScope.bindToCurrentDesktop() else {
            diagnostics.record("start_failed", details: ["reason": "desktop_unavailable"])
            warning = "Stagehand couldn't identify the current macOS Desktop, so it left your windows unchanged."
            return
        }
        warning = nil
        overlays.hide()
        windows = windowSystem.start()
        if !savedLayoutConsidered {
            savedLayoutConsidered = true
            if state.spaces.allSatisfy(\.windowIDs.isEmpty), let layoutStore {
                switch layoutStore.load(windows: windows) {
                case .restored(let saved, let savedHeights):
                    state = saved
                    preferredHeights.merge(savedHeights) { current, _ in current }
                    diagnostics.record("layout_restored", details: [
                        "windowCount": String(Set(saved.spaces.flatMap(\.windowIDs)).count),
                        "activeSpace": String(saved.activeSpaceIndex + 1)
                    ])
                case .unavailable(let reason):
                    diagnostics.record("layout_not_restored", details: [
                        "reason": reason, "discoveredWindowCount": String(windows.count)
                    ])
                }
            }
        }
        // Pausing returned every window to its frame from before Stagehand, so a
        // known window keeps the height chosen while Stagehand ran; only a window
        // seen for the first time takes its current height.
        preferredHeights = Dictionary(windows.map { ($0.id, preferredHeights[$0.id] ?? $0.frame.height) },
                                      uniquingKeysWith: { first, _ in first })
        workspaceRestoration.reconcile(state: &state, windowIDs: windows.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs,
                                       initialWidthFractions: initialWidthFractions(for: windows))
        // Windows restored while paused keep their saved slots on resume.
        minimizedWindowIDs.subtract(windows.map(\.id))
        if let focused = windowSystem.focusedWindowID() {
            state.focus(windowID: focused)
            focusHistory.record(windowID: focused)
        }
        isRunning = true
        // Running again: no earlier session end applies, and nothing is left to watch for.
        UserDefaults.standard.removeObject(forKey: Self.lastSessionEndKey)
        startAfterRecovery = false
        disarmRecoveryWatch()
        recoveryInProgress = automaticRecovery
        isSuspended = false
        state.isPaused = false
        input.gesturesEnabled = gesturesEnabled
        input.shortcutSwipesEnabled = shortcutSwipesEnabled
        focusGate.start()
        input.start()
        pointer.start()
        updateInputStatus()
        diagnostics.record("started", details: workspaceDetails())
        enqueue(.refresh)
        onStateChange?()
    }

    func pause() {
        stop(reason: "manual", automatic: false)
    }

    func stop(reason: String, automatic: Bool, details: [String: String] = [:]) {
        automaticResumeTask?.cancel()
        automaticResumeTask = nil
        guard isRunning else { return }
        var context = workspaceDetails()
        context["reason"] = reason
        context.merge(details) { _, new in new }
        diagnostics.record(
            automatic ? "automatic_pause" : "paused",
            details: context
        )
        // Away from this Desktop, no window can be read or moved: restore once and let the
        // journal and the recovery watch put them back on return.
        let windowsReachable = !isSuspended
        UserDefaults.standard.set(reason, forKey: Self.lastSessionEndKey)
        isRunning = false
        isSuspended = false
        state = workspaceRestoration.pause(state: state, windowIDs: windows.map(\.id),
                                           trackedWindowIDs: windowSystem.trackedWindowIDs)
        layoutSaveTask?.cancel()
        layoutSaveTask = nil
        saveLayout()
        ribbonMotion.cancel()
        presentationFrames = nil
        resetGestureTracking()
        changes.cancel()
        expiredTokens.removeAll()
        refreshTask?.cancel()
        observedFocusTask?.cancel()
        desktopCheckTask?.cancel()
        desktopCheckAttempts = 0
        displayCheckTask?.cancel()
        displayCheckTask = nil
        if !automatic { desktopScope.reset() }
        pointerInteraction = nil
        preferencesNeedLayout = false
        focusGate.cancelAll()
        focusGate.stop()
        input.stop()
        pointer.stop()
        focusBorder.reset()
        overlays.hide()
        emptySpace.hide()
        windowSystem.stop(windowsReachable: windowsReachable)
        if windowSystem.hasPendingRecovery {
            diagnostics.record("restore_deferred", details: [
                "windowsReachable": String(windowsReachable),
                "pendingIDs": windowSystem.pendingRecoveryWindowIDs.sorted().joined(separator: ",")
            ])
            armRecoveryWatch()
        }
        lastAppliedFrames.removeAll()
        knownFrames.removeAll()
        recoveryInProgress = false
        if automatic {
            if automaticResumeAttempted {
                warning = (warning ?? "Stagehand paused and restored your windows.") + " Press Start to retry."
            } else {
                automaticResumeAttempted = true
                let generation = changes.generation
                automaticResumeTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, !self.isRunning, self.changes.generation == generation else { return }
                    self.automaticResumeTask = nil
                    self.diagnostics.record("automatic_resume_attempt", details: ["reason": reason])
                    self.start(automaticRecovery: true)
                    if !self.isRunning {
                        self.diagnostics.record("automatic_resume_failed")
                        self.warning = (self.warning ?? "Stagehand couldn't resume automatically.") + " Press Start to retry."
                    }
                }
            }
        } else {
            automaticResumeAttempted = false
        }
        if let warning { overlays.showWarning(warning) }
        onStateChange?()
    }

    func scheduleLayoutSave() {
        guard layoutStore != nil, layoutSaveTask == nil else { return }
        layoutSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            self.layoutSaveTask = nil
            guard self.isRunning else { return }
            self.saveLayout()
        }
    }

    /// A failed save is recorded so a layout that does not come back after a
    /// relaunch can be traced; the session itself continues.
    func saveLayout() {
        guard let layoutStore else { return }
        do {
            try MainThreadActivity.during("layout save") {
                try layoutStore.save(state, windows: windows, preferredHeights: preferredHeights)
            }
        } catch {
            diagnostics.record("layout_save_failed", details: ["error": error.localizedDescription])
            NSLog("Stagehand layout save failed: %@", error.localizedDescription)
        }
    }

    func shutDown() { stop(reason: "application_termination", automatic: false) }

    func revealDiagnosticLog() {
        diagnostics.record("log_revealed")
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.logURL])
    }

    func clearDiagnosticLog() {
        diagnostics.clear()
    }

    func workspaceDetails() -> [String: String] {
        var details = [
            "activeSpace": String(state.activeSpaceIndex + 1),
            "pendingChanges": String(changes.count),
            "suspended": String(isSuspended),
            "windowCount": String(windows.count),
            "workerActive": String(changes.isProcessing)
        ]
        if let focusedWindow {
            details["focusedBundleIdentifier"] = focusedWindow.bundleIdentifier
            details["focusedPID"] = String(focusedWindow.pid)
            details["focusedWindowID"] = focusedWindow.id
        }
        return details
    }

    func recordWindowGeometry(
        event: String,
        windowID: String,
        requestedFrame: CGRect,
        beforeFrame: CGRect? = nil,
        actualFrame: CGRect?,
        details: @autoclosure () -> [String: String] = [:]
    ) {
        guard diagnostics.isEnabled else { return }
        let window = windows.first { $0.id == windowID }
        diagnostics.recordWindowGeometry(
            event: event,
            bundleIdentifier: window?.bundleIdentifier,
            pid: window?.pid,
            windowID: windowID,
            requestedFrame: requestedFrame,
            beforeFrame: beforeFrame,
            actualFrame: actualFrame,
            details: details()
        )
    }

    func navigate(_ action: NavigationAction, initialHorizontalVelocity: CGFloat? = nil) {
        switch action {
        case .showSettings: showSettings?()
        case .togglePause: isRunning ? pause() : start()
        case .toggleShortcutHints: overlays.toggleShortcutHints()
        default:
            guard isRunning, !isSuspended else { return }
            if gestureAxis != nil {
                input.cancelGestureSequence()
                resetGestureTracking()
            }
            enqueue(.action(action), initialHorizontalVelocity: initialHorizontalVelocity)
        }
    }

    func focusBorderColor(forSpace index: Int) -> NSColor {
        guard focusBorderColors.indices.contains(index) else { return BorderView.defaultColor }
        return focusBorderColors[index]
    }

    func setFocusBorderColor(_ color: NSColor, forSpace index: Int? = nil) {
        let index = index ?? state.activeSpaceIndex
        guard focusBorderColors.indices.contains(index) else { return }
        guard let normalized = Self.normalizedColor(
            color,
            alpha: BorderView.defaultColor.alphaComponent
        ) else { return }
        focusBorderColors[index] = normalized
        Self.saveColors(focusBorderColors, forKey: PreferenceKey.focusBorderColors)
        if index == state.activeSpaceIndex { overlays.setBorderColor(normalized) }
    }

    func setShortcutEnabled(id: String, enabled: Bool) -> String? {
        guard let index = shortcutBindings.firstIndex(where: { $0.id == id }),
              shortcutBindings[index].isEnabled != enabled else { return nil }
        if enabled, let conflict = shortcutConflict(
            key: shortcutBindings[index].key,
            modifiers: shortcutBindings[index].modifiers,
            excluding: id
        ) {
            return "That shortcut is already assigned to \(conflict.title)."
        }
        shortcutBindings[index].isEnabled = enabled
        saveShortcutBindings()
        return nil
    }

    func setShortcut(id: String, key: UInt32, modifiers: UInt32, keyLabel: String) -> String? {
        guard let index = shortcutBindings.firstIndex(where: { $0.id == id }) else { return nil }
        if let issue = ShortcutBinding.validationIssue(key: key, modifiers: modifiers, keyLabel: keyLabel) {
            return issue
        }
        if shortcutBindings[index].isEnabled,
           let conflict = ShortcutBinding.conflict(in: shortcutBindings, key: key, modifiers: modifiers, excluding: id) {
            return "That shortcut is already assigned to \(conflict.title)."
        }
        shortcutBindings[index].key = key
        shortcutBindings[index].modifiers = modifiers
        shortcutBindings[index].keyLabel = keyLabel
        saveShortcutBindings()
        return nil
    }

    func resetShortcut(id: String) {
        guard let defaultBinding = ShortcutBinding.defaultBinding(id: id),
              let index = shortcutBindings.firstIndex(where: { $0.id == id }) else { return }
        for conflictIndex in shortcutBindings.indices where
            shortcutBindings[conflictIndex].id != id &&
            shortcutBindings[conflictIndex].isEnabled &&
            shortcutBindings[conflictIndex].key == defaultBinding.key &&
            shortcutBindings[conflictIndex].modifiers == defaultBinding.modifiers {
            shortcutBindings[conflictIndex].isEnabled = false
        }
        shortcutBindings[index] = defaultBinding
        saveShortcutBindings()
    }

    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        input.setShortcutCaptureActive(recording)
        focusGate.setShortcutBindings(recording ? [] : shortcutBindings)
    }

    func shortcutConflict(key: UInt32, modifiers: UInt32, excluding id: String) -> ShortcutBinding? {
        ShortcutBinding.conflict(in: shortcutBindings, key: key, modifiers: modifiers, excluding: id)
    }

    func saveShortcutBindings() {
        ShortcutBinding.save(shortcutBindings)
        input.setShortcutBindings(shortcutBindings)
        updateShortcutHints()
        focusGate.setShortcutBindings(isRecordingShortcut ? [] : shortcutBindings)
    }

    func updateShortcutHints() {
        overlays.setShortcutHints(shortcutBindings, swipeTip: ShortcutHintsModel.swipeTip(
            enabled: shortcutSwipesEnabled, reversed: reverseShortcutSwipeDirection))
    }

    static func normalizedColor(_ color: NSColor, alpha: CGFloat = 1) -> NSColor? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return NSColor(srgbRed: color.redComponent, green: color.greenComponent,
                       blue: color.blueComponent, alpha: alpha)
    }

    static func saveColors(_ colors: [NSColor], forKey key: String) {
        UserDefaults.standard.set(colors.map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent]
        }, forKey: key)
    }

    static func savedColor(forKey key: String, in defaults: UserDefaults,
                                   alpha: CGFloat = 1) -> NSColor? {
        guard let values = defaults.array(forKey: key), values.count == 3 else {
            return nil
        }
        let components = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard components.count == 3, components.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2],
                       alpha: alpha)
    }

    static func savedColors(
        forKey key: String,
        count: Int,
        in defaults: UserDefaults,
        alpha: CGFloat = 1
    ) -> [NSColor]? {
        guard let saved = defaults.array(forKey: key), saved.count == count else { return nil }
        let colors = saved.compactMap { value -> NSColor? in
            guard let values = value as? [NSNumber], values.count == 3 else { return nil }
            let components = values.map(\.doubleValue)
            guard components.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
            return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: alpha)
        }
        return colors.count == count ? colors : nil
    }

    func removeMembership(windowID: String) {
        guard isRunning, !isSuspended else { return }
        enqueue(.remove(windowID))
    }

    func shareMembership(windowID: String, spaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.share(windowID: windowID, spaceIndex: spaceIndex))
    }

    func focusWindow(_ id: String) {
        guard isRunning, !isSuspended else { return }
        enqueue(.focus(id))
    }

    func moveMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.moveMembership(windowID: windowID, fromSpaceIndex: fromSpaceIndex,
                                toSpaceIndex: toSpaceIndex))
    }

    func shareMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.shareMembership(windowID: windowID, fromSpaceIndex: fromSpaceIndex,
                                 toSpaceIndex: toSpaceIndex))
    }

    func removeMembership(windowID: String, fromSpaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.removeMembership(windowID: windowID, fromSpaceIndex: fromSpaceIndex))
    }

    func reorderWindow(windowID: String, toIndex: Int, spaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.reorderWindow(windowID: windowID, toIndex: toIndex, spaceIndex: spaceIndex))
    }

    func focusWindow(_ id: String, inSpace spaceIndex: Int) {
        guard isRunning, !isSuspended else { return }
        enqueue(.focusInSpace(windowID: id, spaceIndex: spaceIndex))
    }

    func dismissWarning() { warning = nil }

    func updateInputStatus() {
        var issues = input.issues
        if isRunning && !isSuspended && !focusGate.isAvailable {
            issues.append(focusGate.isSecureInputEnabled
                          ? "Secure Input is on, so Stagehand can't protect typing while switching windows."
                          : "Typing protection is unavailable. Re-enable Accessibility for Stagehand, then retry.")
        }
        if gesturesEnabled || shortcutSwipesEnabled {
            issues.append(contentsOf: InputController.nativeGestureConflicts())
        }
        var seen = Set<String>()
        inputIssues = issues.filter { seen.insert($0).inserted }
    }

    func screenUnlocked() {
        desktopScope.invalidate()
        diagnostics.record("screen_unlocked", details: [
            "running": String(isRunning), "suspended": String(isSuspended)
        ])
        guard isRunning, isSuspended else { return }
        desktopCheckAttempts = 0
        unlockDesktopChecks = Self.unlockDesktopCheckCount
        nativeDesktopChanged()
    }

    func nativeDesktopChanged() {
        desktopScope.invalidate()
        guard isRunning else { return }
        desktopCheckTask?.cancel()
        switch desktopScope.refresh() {
        case .home:
            desktopCheckAttempts = 0
            unlockDesktopChecks = 0
            guard isSuspended else { return }
            isSuspended = false
            diagnostics.record("desktop_resumed", details: workspaceDetails())
            input.gesturesEnabled = gesturesEnabled
            input.shortcutSwipesEnabled = shortcutSwipesEnabled
            focusGate.start()
            input.start()
            // Reconcile only after returning to the bound Desktop; away windows never enter state.
            // One layout after returning: the Desktop may have changed while away. A
            // second, separate reveal of the border before it would flash it.
            let refreshBegan = ProcessInfo.processInfo.systemUptime
            refreshWindows(forceLayout: true)
            diagnostics.record("desktop_resume_refreshed", details: [
                "milliseconds": String(Int((ProcessInfo.processInfo.systemUptime - refreshBegan) * 1_000))
            ])
            onStateChange?()
        case .away, .unknown:
            if !isSuspended {
                diagnostics.record("desktop_suspended", details: [
                    "relation": String(describing: desktopScope.relation)
                ])
                isSuspended = true
                changes.cancel()
                refreshTask?.cancel()
                workspaceRestoration.rollBack(state: &state, windowIDs: windows.map(\.id),
                                              trackedWindowIDs: windowSystem.trackedWindowIDs)
                pointerInteraction = nil
                ribbonMotion.cancel()
                presentationFrames = nil
                resetGestureTracking()
                observedFocusTask?.cancel()
                focusGate.cancelAll()
                focusGate.stop()
                input.stop()
                focusBorder.reset()
                // Resume returns to this Desktop; keep the panels instead of rebuilding them.
                overlays.suspend()
                emptySpace.hide()
                updateInputStatus()
                onStateChange?()
            }
            // WindowServer can report an unavailable Desktop throughout the lock
            // screen and briefly after unlock. Keep checking until it reports the
            // bound Desktop instead of relying on one early session notification,
            // but not at 500 ms forever: a long lock or a broken private API
            // would otherwise poll indefinitely.
            if desktopScope.relation == .unknown {
                desktopCheckAttempts += 1
                if unlockDesktopChecks > 0 { unlockDesktopChecks -= 1 }
                if desktopCheckAttempts == Self.quickDesktopChecks + 1 {
                    diagnostics.record("desktop_check_backoff", details: [
                        "attempts": String(desktopCheckAttempts - 1),
                        "intervalMilliseconds": String(5_000)
                    ])
                }
                let delay = desktopCheckDelay
                desktopCheckTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.nativeDesktopChanged()
                }
            } else {
                desktopCheckAttempts = 0
                unlockDesktopChecks = 0
            }
        }
    }

    func screenParametersChanged() {
        guard isRunning, !isSuspended else { return }
        let hasBuiltInDisplay = builtInScreen != nil
        diagnostics.record("screen_parameters_changed", details: [
            "builtInDisplay": String(hasBuiltInDisplay),
            "screenCount": String(NSScreen.screens.count)
        ])
        ribbonMotion.cancel()
        focusBorder.reset()
        displayCheckTask?.cancel()
        guard hasBuiltInDisplay else {
            // Lid closed or clamshell: there is no frame to lay out in. Give the
            // reconfiguration a moment to finish, then pause and restore rather
            // than manage whatever display macOS moved the windows to.
            let delay = displayCheckDelay
            displayCheckTask = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.displayCheckTask = nil
                self.pauseIfBuiltInDisplayMissing()
            }
            return
        }
        enqueue(.preferences)
    }
}

/// Window recovery that has to wait for the user to come back. Accessibility reaches only
/// the current Space's windows: a pause or quit while the user is on another Space or the
/// lock screen cannot put windows back, and before this nothing tried again until Start
/// (2026-10-26 11:56Z: seven windows stayed parked at the screen edges).
extension StagehandModel {
    func armRecoveryWatch() {
        guard recoveryWatchTask == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.didWakeNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryRecovery(trigger: name.rawValue) }
            }
            recoveryWatchTokens.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        let unlock = distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryRecovery(trigger: "screenIsUnlocked") }
        }
        recoveryWatchTokens.append((distributed, unlock))
        recoveryWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.retryRecovery(trigger: "timer")
            }
        }
    }

    func disarmRecoveryWatch() {
        for (center, token) in recoveryWatchTokens { center.removeObserver(token) }
        recoveryWatchTokens.removeAll()
        recoveryWatchTask?.cancel()
        recoveryWatchTask = nil
    }

    func retryRecovery(trigger: String) {
        guard !isRunning else {
            disarmRecoveryWatch()
            return
        }
        let pendingBefore = windowSystem.pendingRecoveryWindowIDs.count
        _ = windowSystem.recoverInterruptedSession()
        let pendingAfter = windowSystem.pendingRecoveryWindowIDs.count
        if pendingAfter != pendingBefore || pendingAfter == 0 {
            diagnostics.record("recovery_retry", details: [
                "trigger": trigger, "pendingBefore": String(pendingBefore), "pendingAfter": String(pendingAfter)
            ])
        }
        finishRecoveryIfReady()
    }

    /// Once nothing is pending: stop watching, and start if launch was waiting for it.
    func finishRecoveryIfReady() {
        guard !windowSystem.hasPendingRecovery else { return }
        disarmRecoveryWatch()
        if warning?.hasPrefix("Stagehand found an earlier window session") == true
            || warning?.hasPrefix("Stagehand couldn't restore every window") == true {
            warning = nil
        }
        guard startAfterRecovery, !isRunning, accessibilityGranted else { return }
        startAfterRecovery = false
        diagnostics.record("recovery_completed_start")
        start()
    }
}

