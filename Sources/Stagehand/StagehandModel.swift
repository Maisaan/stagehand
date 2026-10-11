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
            updateInputStatus()
        }
    }
    @Published var reverseShortcutSwipeDirection: Bool {
        didSet {
            UserDefaults.standard.set(reverseShortcutSwipeDirection, forKey: PreferenceKey.reverseShortcutSwipeDirection)
            input.reverseShortcutSwipeDirection = reverseShortcutSwipeDirection
            updateInputStatus()
        }
    }
    @Published var gap: Double {
        didSet {
            UserDefaults.standard.set(gap, forKey: PreferenceKey.windowGap)
            if isRunning && !isSuspended { enqueue(.preferences) }
        }
    }
    @Published private(set) var focusBorderColors: [NSColor]
    @Published private(set) var shortcutBindings: [ShortcutBinding]

    var focusBorderColor: NSColor {
        focusBorderColor(forSpace: state.activeSpaceIndex)
    }
    let ribbonAnimationConfiguration = RibbonAnimationConfiguration.default
    @Published var diagnosticLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticLoggingEnabled, forKey: PreferenceKey.diagnosticLoggingEnabled)
            windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
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
    var presentationFrames: [String: CGRect]?
    var gestureBase: [String: CGRect]? {
        didSet { gesturePreviewCache = nil }
    }
    /// The last complete preview. Resting fingers repeat a displacement every display tick.
    var gesturePreviewCache: (displacement: Double, frames: [String: CGRect])?
    var gesturePrepared: Set<String> = []
    var gestureAxis: GestureAxis?
    var motionWrittenPositions: [String: CGPoint] = [:]
    var motionBackingScaleFactor: CGFloat = 1
    let emptySpace: any EmptySpacePresenting
    var refreshTask: Task<Void, Never>?
    let layoutStore: WorkspaceLayoutStore?
    var layoutSaveTask: Task<Void, Never>?
    /// The saved layout is applied only to the first start after launch. Later
    /// starts resume the in-memory layout.
    var savedLayoutConsidered = false
    var observedFocusTask: Task<Void, Never>?
    let changes = ChangeQueue<PendingChange>()
    var lastAppliedFrames: [String: CGRect] = [:]
    var preferredHeights: [String: CGFloat] = [:]
    var lastTransition = Date.distantPast
    var automaticResumeTask: Task<Void, Never>?
    var automaticResumeAttempted = false
    var recoveryInProgress = false
    var desktopCheckTask: Task<Void, Never>?
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
        self.overlays = overlays
        let defaults = UserDefaults.standard
        let shortcutBindings = ShortcutBinding.load(from: defaults)
        self.shortcutBindings = shortcutBindings
        input = injectedInput ?? InputController(shortcutBindings: shortcutBindings)
        diagnosticLoggingEnabled = defaults.bool(forKey: PreferenceKey.diagnosticLoggingEnabled)
        self.diagnostics = diagnostics ?? DiagnosticLogger(
            enabled: defaults.bool(forKey: PreferenceKey.diagnosticLoggingEnabled)
        )
        gesturesEnabled = defaults.object(forKey: PreferenceKey.gesturesEnabled) as? Bool ?? false
        shortcutSwipesEnabled = defaults.bool(forKey: PreferenceKey.shortcutSwipesEnabled)
        reverseShortcutSwipeDirection = defaults.object(forKey: PreferenceKey.reverseShortcutSwipeDirection) as? Bool ?? true
        gap = GapInput.clamped(defaults.object(forKey: PreferenceKey.windowGap) as? Double ?? 8)
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
        overlays.onReorderWindow = { [weak self] id, index in
            guard let self else { return }
            self.reorderWindow(windowID: id, toIndex: index, spaceIndex: self.state.activeSpaceIndex)
        }
        overlays.canRevealNavigation = { [weak self] in
            guard let self, self.isRunning, !self.isSuspended else { return false }
            return self.desktopScope.refresh() == .home
        }
        overlays.setBorderColor(focusBorderColor)
        input.onStatusChange = { [weak self] in self?.updateInputStatus() }
        windowSystem.onChange = { [weak self] in self?.scheduleRefresh() }
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
        windowSystem.onFrameChange = { [weak self] id, frame in
            guard let self, self.isRunning, !self.isSuspended,
                  !self.isLayingOutWindows, !self.ribbonMotion.isRunning, self.gestureBase == nil,
                  self.focusBorder.windowID == id, self.state.focusedWindowID == id else { return }
            guard self.desktopScope.refresh() == .home else {
                self.nativeDesktopChanged()
                return
            }
            // Geometry follows native notifications immediately. Corner metadata is
            // refreshed by the coalesced reconciliation after the resize settles.
            self.updateFocusBorder(windowID: id, frame: frame, refreshShape: false)
        }
        windowSystem.onNativeDesktopChange = { [weak self] in
            self?.nativeDesktopChanged()
        }
        windowSystem.onScreenParametersChange = { [weak self] in
            self?.screenParametersChanged()
        }
        windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
        refreshLaunchAtLogin()
        focusGate.onNavigationAction = { [weak self] action in self?.navigate(action) }
        focusGate.setShortcutBindings(shortcutBindings)
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
        focusGate.onInputDiscarded = { [weak self] count in
            self?.warning = "Stagehand couldn't confirm the new window, so it did not send \(count) buffered key \(count == 1 ? "event" : "events"). Check your last input."
            NSSound.beep()
        }
        focusGate.onTransferExpired = { [weak self] token in
            guard let self else { return }
            self.expiredTokens.insert(token)
            let generation = self.changes.generation
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.changes.generation == generation else { return }
                self.stop(
                    reason: "input_transfer_expired",
                    automatic: true,
                    details: ["token": String(token)]
                )
                if self.warning == nil {
                    self.warning = "Stagehand couldn't finish switching windows. It paused and restored your windows."
                }
            }
        }
        self.diagnostics.record("session_started")
        refreshPermissions()
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
        accessibilityGranted = windowSystem.isAccessibilityTrusted
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
        if interrupted {
            diagnostics.record("crash_recovery", details: [
                "pending": String(windowSystem.hasPendingRecovery)
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
                case .restored(let saved):
                    state = saved
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
        preferredHeights = Dictionary(windows.map { ($0.id, $0.frame.height) }, uniquingKeysWith: { first, _ in first })
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
        recoveryInProgress = automaticRecovery
        isSuspended = false
        state.isPaused = false
        input.gesturesEnabled = gesturesEnabled
        input.shortcutSwipesEnabled = shortcutSwipesEnabled
        focusGate.start()
        input.start()
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
        if !automatic { desktopScope.reset() }
        pointerInteraction = nil
        preferencesNeedLayout = false
        focusGate.cancelAll()
        focusGate.stop()
        input.stop()
        focusBorder.reset()
        overlays.hide()
        emptySpace.hide()
        windowSystem.stop()
        lastAppliedFrames.removeAll()
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
            try layoutStore.save(state, windows: windows)
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
        guard modifiers & ShortcutBinding.supportedModifiers != 0 else {
            return "Add Control, Option, Shift, Command, or Caps Lock to the shortcut."
        }
        if shortcutBindings[index].isEnabled,
           let conflict = shortcutConflict(key: key, modifiers: modifiers, excluding: id) {
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
        shortcutBindings.first {
            $0.id != id && $0.isEnabled && $0.key == key && $0.modifiers == modifiers
        }
    }

    func saveShortcutBindings() {
        ShortcutBinding.save(shortcutBindings)
        input.setShortcutBindings(shortcutBindings)
        focusGate.setShortcutBindings(isRecordingShortcut ? [] : shortcutBindings)
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

    func nativeDesktopChanged() {
        guard isRunning else { return }
        desktopCheckTask?.cancel()
        switch desktopScope.refresh() {
        case .home:
            guard isSuspended else { return }
            isSuspended = false
            diagnostics.record("desktop_resumed", details: workspaceDetails())
            input.gesturesEnabled = gesturesEnabled
            input.shortcutSwipesEnabled = shortcutSwipesEnabled
            focusGate.start()
            input.start()
            // Reconcile only after returning to the bound Desktop; away windows never enter state.
            refreshWindows()
            if !changes.isProcessing { enqueue(.refresh) }
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
                overlays.hide()
                emptySpace.hide()
                updateInputStatus()
                onStateChange?()
            }
            // WindowServer can report an unavailable Desktop throughout the lock
            // screen and briefly after unlock. Keep checking until it reports the
            // bound Desktop instead of relying on one early session notification.
            if desktopScope.relation == .unknown {
                desktopCheckTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self?.nativeDesktopChanged()
                }
            }
        }
    }

    func screenParametersChanged() {
        guard isRunning, !isSuspended else { return }
        diagnostics.record("screen_parameters_changed")
        ribbonMotion.cancel()
        focusBorder.reset()
        enqueue(.preferences)
    }
}
