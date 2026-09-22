import AppKit
import Combine
import ServiceManagement
import StagehandCore
import StagehandPlatform

private let traceGestures = ProcessInfo.processInfo.arguments.contains("--trace-gestures")

enum RibbonTransitionSource: Equatable {
    case managed
    case observedFocus
    case windowRemoval
}

func shouldSlideRibbon(from previousState: WorkspaceState, to state: WorkspaceState,
                       source: RibbonTransitionSource, hadPreview: Bool, reduceMotion: Bool) -> Bool {
    guard source != .observedFocus,
          !reduceMotion,
          previousState.activeSpaceIndex == state.activeSpaceIndex,
          state.focusedWindowID != nil else { return false }
    if source == .windowRemoval {
        return previousState.currentSpace.windowIDs != state.currentSpace.windowIDs
    }
    return previousState.focusedWindowID != state.focusedWindowID || hadPreview
}

func framesMatch(observed: CGRect, target: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(observed.minX - target.minX) <= tolerance
        && abs(observed.minY - target.minY) <= tolerance
        && abs(observed.width - target.width) <= tolerance
        && abs(observed.height - target.height) <= tolerance
}

func adjustedWindowHeight(current: CGFloat, available: CGFloat, growing: Bool) -> CGFloat? {
    guard current.isFinite, current > 0, available.isFinite, available > 0 else { return nil }
    let limit = available * (growing ? 1 : 0.25)
    guard growing ? current < limit : current > limit else { return nil }
    let adjustment = available * (growing ? 0.05 : -0.05)
    return growing ? min(current + adjustment, limit) : max(current + adjustment, limit)
}

func shouldFollowObservedFocus(observedWindowID: String, discoveredWindowIDs: Set<String>) -> Bool {
    discoveredWindowIDs.contains(observedWindowID)
}

struct WindowFocusHistory {
    private var windowIDs: [String] = []

    mutating func record(windowID: String) {
        windowIDs.removeAll { $0 == windowID }
        windowIDs.append(windowID)
    }

    mutating func remove(windowIDs removedWindowIDs: Set<String>) {
        windowIDs.removeAll { removedWindowIDs.contains($0) }
    }

    func mostRecentWindowID(among availableWindowIDs: Set<String>) -> String? {
        windowIDs.last { availableWindowIDs.contains($0) }
    }
}

func focusMostRecentWindowAfterLoss(
    previousFocusedWindowID: String?,
    history: WindowFocusHistory,
    state: inout WorkspaceState
) {
    guard let previousFocusedWindowID,
          !state.currentSpace.windowIDs.contains(previousFocusedWindowID),
          let windowID = history.mostRecentWindowID(among: Set(state.currentSpace.windowIDs)) else { return }
    state.focus(windowID: windowID)
}

@MainActor
func prepareObservedFocus(
    state: WorkspaceState,
    notificationWindowID: String,
    focusedWindowID: String?
) -> WorkspaceState? {
    guard notificationWindowID == focusedWindowID else { return nil }
    return LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: focusedWindowID)
}

enum RibbonTranslationOutcome: Equatable {
    case readyForFocus
    case superseded
    case failed
}

enum NavigationTransitionOutcome: Equatable {
    case completed
    case superseded
    case failed
}

@MainActor
func runFocusFirstNavigation(
    translate: () async -> RibbonTranslationOutcome,
    focus: () async -> Bool,
    focusConfirmed: () -> Void,
    commitInput: () -> Void,
    revealBorder: () -> Void
) async -> NavigationTransitionOutcome {
    revealBorder()
    guard await focus() else { return .failed }
    focusConfirmed()
    switch await translate() {
    case .superseded: return .superseded
    case .failed: return .failed
    case .readyForFocus: break
    }
    commitInput()
    return .completed
}

@MainActor
func runConcurrentRemovalNavigation(
    translate: @escaping () async -> RibbonTranslationOutcome,
    cancelTranslation: () -> Void,
    focus: () async -> Bool,
    focusConfirmed: () -> Void,
    commitInput: () -> Void,
    revealBorder: () -> Void
) async -> NavigationTransitionOutcome {
    let translation = Task { @MainActor in await translate() }
    await Task.yield()
    let focused = await focus()
    guard focused else {
        cancelTranslation()
        _ = await translation.value
        return .failed
    }
    focusConfirmed()
    let translationOutcome = await translation.value
    switch translationOutcome {
    case .superseded: return .superseded
    case .failed: return .failed
    case .readyForFocus: break
    }
    commitInput()
    revealBorder()
    return .completed
}

func preferredParkingSide(for frame: CGRect?, relativeTo bounds: CGRect) -> WindowParkingSide? {
    guard let frame, !bounds.isEmpty, frame.midX.isFinite, bounds.midX.isFinite else { return nil }
    return frame.midX < bounds.midX ? .left : .right
}

struct RibbonPositionWriteFailure: Equatable {
    let windowID: String
    let requestedFrame: CGRect
    let actualFrame: CGRect?
}

enum WindowParkingOutcome: Equatable {
    case parked
    case deferred
    case failed
}

@discardableResult
func removeTerminatedApplication(
    pid: Int32,
    windows: inout [WindowRecord],
    state: inout WorkspaceState
) -> Set<String> {
    let removedIDs = Set(windows.lazy.filter { $0.pid == pid }.map(\.id))
    guard !removedIDs.isEmpty else { return [] }
    windows.removeAll { removedIDs.contains($0.id) }
    state.reconcile(windowIDs: windows.map(\.id))
    return removedIDs
}

@discardableResult
func removeDestroyedWindow(
    windowID: String,
    windows: inout [WindowRecord],
    state: inout WorkspaceState
) -> Bool {
    guard windows.contains(where: { $0.id == windowID }) else { return false }
    windows.removeAll { $0.id == windowID }
    state.reconcile(windowIDs: windows.map(\.id))
    return true
}

@discardableResult
func removeUnavailableWindow(
    windowID: String,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>
) -> Bool {
    guard windows.contains(where: { $0.id == windowID }) else { return false }
    windows.removeAll { $0.id == windowID }
    restoration.reconcile(
        state: &state,
        windowIDs: windows.map(\.id),
        trackedWindowIDs: trackedWindowIDs
    )
    return true
}

@discardableResult
func restoreAvailableWindow(
    _ window: WindowRecord,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>,
    initialWidthFractions: [String: Double] = [:]
) -> Bool {
    guard !windows.contains(where: { $0.id == window.id }) else { return false }
    windows.append(window)
    restoration.reconcile(
        state: &state,
        windowIDs: windows.map(\.id),
        trackedWindowIDs: trackedWindowIDs,
        initialWidthFractions: initialWidthFractions
    )
    return true
}

@MainActor
func writeRibbonPositions(
    frames: [String: CGRect],
    writtenPositions: inout [String: CGPoint],
    backingScaleFactor: CGFloat,
    setPosition: (String, CGPoint) -> Bool
) {
    for (windowID, frame) in frames {
        let position = RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: backingScaleFactor)
        if writtenPositions[windowID] == position { continue }
        if setPosition(windowID, position) {
            writtenPositions[windowID] = position
        } else {
            // AX writes during animation are presentation hints. Leave the value
            // unwritten so a later display tick can retry, then verify at commit.
            writtenPositions.removeValue(forKey: windowID)
        }
    }
}

@MainActor
func commitRibbonPositions(
    frames: [String: CGRect],
    backingScaleFactor: CGFloat,
    setPosition: (String, CGPoint) -> Bool,
    observedFrame: (String) -> CGRect?
) -> [RibbonPositionWriteFailure] {
    frames.compactMap { windowID, frame in
        let position = RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: backingScaleFactor)
        if let actual = observedFrame(windowID), ribbonPositionMatches(actual.origin, position) { return nil }
        _ = setPosition(windowID, position)
        let actual = observedFrame(windowID)
        guard actual.map({ ribbonPositionMatches($0.origin, position) }) != true else { return nil }
        return RibbonPositionWriteFailure(windowID: windowID, requestedFrame: frame, actualFrame: actual)
    }
}

private func ribbonPositionMatches(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 1) -> Bool {
    lhs.x.isFinite && lhs.y.isFinite && rhs.x.isFinite && rhs.y.isFinite &&
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

@MainActor
func parkWindow(
    windowID: String,
    park: (String) -> Bool,
    observedFrame: (String) -> CGRect?
) -> WindowParkingOutcome {
    if park(windowID) { return .parked }
    return observedFrame(windowID) == nil ? .deferred : .failed
}

@MainActor
final class StagehandModel: ObservableObject {
    @Published private(set) var state = WorkspaceState()
    @Published private(set) var windows: [WindowRecord] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isSuspended = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var inputIssues: [String] = []
    @Published private(set) var warning: String? {
        didSet {
            if let warning, !isSuspended { overlays.showWarning(warning) }
        }
    }
    @Published var gesturesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gesturesEnabled, forKey: "gesturesEnabled")
            input.gesturesEnabled = gesturesEnabled && !isSuspended
            updateInputStatus()
        }
    }
    @Published var gap: Double {
        didSet {
            UserDefaults.standard.set(gap, forKey: "windowGap")
            if isRunning && !isSuspended { enqueue(.preferences) }
        }
    }
    @Published private(set) var focusBorderColors: [NSColor]
    @Published private(set) var shortcutBindings: [ShortcutBinding]

    var focusBorderColor: NSColor {
        focusBorderColor(forSpace: state.activeSpaceIndex)
    }
    private let ribbonAnimationConfiguration = RibbonAnimationConfiguration.default
    @Published var diagnosticLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticLoggingEnabled, forKey: DiagnosticLogger.preferenceKey)
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
    private let windowSystem = WindowSystem()
    private let desktopScope = DesktopScope()
    private let input: InputController
    private let focusGate = FocusInputGate()
    private let overlays: NavigationOverlays
    private let diagnostics: DiagnosticLogger
    private let ribbonMotion = RibbonMotion()
    private var presentationFrames: [String: CGRect]?
    private var gestureBase: [String: CGRect]?
    private var gesturePrepared: Set<String> = []
    private var gestureAxis: GestureAxis?
    private var motionWrittenPositions: [String: CGPoint] = [:]
    private var motionBackingScaleFactor: CGFloat = 1
    private let emptySpace = EmptySpaceWindow()
    private var refreshTask: Task<Void, Never>?
    private var observedFocusTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: [PendingChange] = []
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var preferredHeights: [String: CGFloat] = [:]
    private var lastTransition = Date.distantPast
    private var workerGeneration = 0
    private var desktopCheckTask: Task<Void, Never>?
    private var transitionRollback: WorkspaceState?
    private var workspaceRestoration = WorkspaceRestoration()
    private var focusHistory = WindowFocusHistory()
    private var lastLayoutMilliseconds = 0
    private var lastFocusTokenExpired = false
    private var pointerInteraction: PointerInteraction?
    private var borderWindowID: String?
    private var borderWindowNumber: CGWindowID?
    private var borderCornerRadius: CGFloat?
    private var borderCornerRadiusResolved = false
    private var borderRadiusFrameSize: CGSize?
    private var isLayingOutWindows = false
    private var preferencesNeedLayout = false
    private var layoutFailureReason: String?
    private var isRecordingShortcut = false
    private static let legacyFocusBorderColorPreferenceKey = "focusBorderColor"
    private static let focusBorderColorsPreferenceKey = "focusBorderColors"

    private struct PointerInteraction {
        let windowID: String
        let placements: [WindowPlacement]
        var needsLayout: Bool
    }

    private enum Change: Equatable {
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

    private struct PendingChange {
        let change: Change
        let token: UInt64?
        let initialHorizontalVelocity: CGFloat?
        let previousState: WorkspaceState?
        let motionStart: [String: CGRect]?
    }

    init(overlays: NavigationOverlays = NavigationOverlays(), diagnostics: DiagnosticLogger? = nil) {
        self.overlays = overlays
        let defaults = UserDefaults.standard
        let shortcutBindings = ShortcutBinding.load(from: defaults)
        self.shortcutBindings = shortcutBindings
        input = InputController(shortcutBindings: shortcutBindings)
        diagnosticLoggingEnabled = defaults.bool(forKey: DiagnosticLogger.preferenceKey)
        self.diagnostics = diagnostics ?? DiagnosticLogger(
            enabled: defaults.bool(forKey: DiagnosticLogger.preferenceKey)
        )
        gesturesEnabled = defaults.object(forKey: "gesturesEnabled") as? Bool ?? false
        gap = GapInput.clamped(defaults.object(forKey: "windowGap") as? Double ?? 8)
        let defaultBorderColor = Self.savedColor(
            forKey: Self.legacyFocusBorderColorPreferenceKey,
            in: defaults,
            alpha: BorderView.defaultColor.alphaComponent
        ) ?? BorderView.defaultColor
        focusBorderColors = Self.savedColors(
            forKey: Self.focusBorderColorsPreferenceKey,
            count: WorkspaceState.spaceCount,
            in: defaults,
            alpha: BorderView.defaultColor.alphaComponent
        ) ?? Array(repeating: defaultBorderColor, count: WorkspaceState.spaceCount)
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
        windowSystem.onFrameChange = { [weak self] id, frame in
            guard let self, self.isRunning, !self.isSuspended,
                  !self.isLayingOutWindows, !self.ribbonMotion.isRunning, self.gestureBase == nil,
                  self.borderWindowID == id, self.state.focusedWindowID == id else { return }
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
                    recognizerAction: completion.recognizerAction
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
            let generation = self.workerGeneration
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.workerGeneration == generation else { return }
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

    private var expiredTokens: Set<UInt64> = []

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

    func start() {
        refreshPermissions()
        guard accessibilityGranted else {
            diagnostics.record("start_failed", details: ["reason": "accessibility_permission_missing"])
            warning = "Allow Stagehand in Accessibility settings, then start it again."
            return
        }
        guard !isRunning else { return }
        guard desktopScope.bindToCurrentDesktop() else {
            diagnostics.record("start_failed", details: ["reason": "desktop_unavailable"])
            warning = "Stagehand couldn't identify the current macOS Desktop, so it left your windows unchanged."
            return
        }
        warning = nil
        windows = windowSystem.start()
        preferredHeights = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame.height) })
        workspaceRestoration.reconcile(state: &state, windowIDs: windows.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs,
                                       initialWidthFractions: initialWidthFractions(for: windows))
        if let focused = windowSystem.focusedWindowID() {
            state.focus(windowID: focused)
            focusHistory.record(windowID: focused)
        }
        isRunning = true
        isSuspended = false
        state.isPaused = false
        input.gesturesEnabled = gesturesEnabled
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

    private func stop(reason: String, automatic: Bool, details: [String: String] = [:]) {
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
        state = workspaceRestoration.pause(state: state, transitionRollback: transitionRollback)
        ribbonMotion.cancel()
        gestureBase = nil
        presentationFrames = nil
        gestureAxis = nil
        gesturePrepared.removeAll()
        workerGeneration += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        expiredTokens.removeAll()
        refreshTask?.cancel()
        observedFocusTask?.cancel()
        desktopCheckTask?.cancel()
        desktopScope.reset()
        transitionRollback = nil
        pointerInteraction = nil
        preferencesNeedLayout = false
        focusGate.cancelAll()
        focusGate.stop()
        input.stop()
        resetFocusBorderCache()
        overlays.hide()
        emptySpace.hide()
        windowSystem.stop()
        lastAppliedFrames.removeAll()
        if let warning { overlays.showWarning(warning) }
        onStateChange?()
    }

    func shutDown() { stop(reason: "application_termination", automatic: false) }

    func revealDiagnosticLog() {
        diagnostics.record("log_revealed")
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.logURL])
    }

    func clearDiagnosticLog() {
        diagnostics.clear()
    }

    private func workspaceDetails() -> [String: String] {
        var details = [
            "activeSpace": String(state.activeSpaceIndex + 1),
            "pendingChanges": String(pending.count),
            "suspended": String(isSuspended),
            "windowCount": String(windows.count),
            "workerActive": String(worker != nil)
        ]
        if let focusedWindow {
            details["focusedBundleIdentifier"] = focusedWindow.bundleIdentifier
            details["focusedPID"] = String(focusedWindow.pid)
            details["focusedWindowID"] = focusedWindow.id
        }
        return details
    }

    private func recordWindowGeometry(
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
            appName: window?.appName,
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
                gestureAxis = nil
                gestureBase = nil
                gesturePrepared.removeAll()
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
        Self.saveColors(focusBorderColors, forKey: Self.focusBorderColorsPreferenceKey)
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

    private func shortcutConflict(key: UInt32, modifiers: UInt32, excluding id: String) -> ShortcutBinding? {
        shortcutBindings.first {
            $0.id != id && $0.isEnabled && $0.key == key && $0.modifiers == modifiers
        }
    }

    private func saveShortcutBindings() {
        ShortcutBinding.save(shortcutBindings)
        input.setShortcutBindings(shortcutBindings)
        focusGate.setShortcutBindings(isRecordingShortcut ? [] : shortcutBindings)
    }

    private static func normalizedColor(_ color: NSColor, alpha: CGFloat = 1) -> NSColor? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        return NSColor(srgbRed: color.redComponent, green: color.greenComponent,
                       blue: color.blueComponent, alpha: alpha)
    }

    private static func saveColors(_ colors: [NSColor], forKey key: String) {
        UserDefaults.standard.set(colors.map {
            [$0.redComponent, $0.greenComponent, $0.blueComponent]
        }, forKey: key)
    }

    private static func savedColor(forKey key: String, in defaults: UserDefaults,
                                   alpha: CGFloat = 1) -> NSColor? {
        guard let values = defaults.array(forKey: key), values.count == 3 else {
            return nil
        }
        let components = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard components.count == 3, components.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2],
                       alpha: alpha)
    }

    private static func savedColors(
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

    /// Closes only a disposable Stagehand window after moving it to its own logical
    /// space. Discovery and empty-space handoff use the real notification path.
    func diagnoseLastClose() async -> String {
        guard accessibilityGranted else {
            return "Accessibility permission is missing for this build. No windows were changed."
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let disposable = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 520, height: 360),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        disposable.isReleasedWhenClosed = false
        disposable.title = "Stagehand disposable close diagnostic"
        disposable.orderFront(nil)
        let disposableID = windowSystem.registerOwnWindow(window: disposable)
        defer {
            pause()
            disposable.close()
            _ = previousApp?.activate(options: [])
        }
        start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while (worker != nil || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, !isSuspended,
              let emptyIndex = state.spaces.indices.last(where: { state.spaces[$0].windowIDs.isEmpty }) else {
            return "Last-close setup failed. Running: \(isRunning). Warning: \(warning ?? "none")"
        }
        focusWindow(disposableID)
        while (worker != nil || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, state.focusedWindowID == disposableID else {
            return "Last-close setup could not focus the disposable window. Warning: \(warning ?? "none")"
        }
        navigate(.moveToSpace(index: emptyIndex, follow: true))
        while (worker != nil || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, state.activeSpaceIndex == emptyIndex, state.currentSpace.windowIDs == [disposableID] else {
            return "Last-close setup did not isolate the disposable window. Warning: \(warning ?? "none")"
        }
        disposable.close()
        // No forced scan or refresh here. Closing the window must notify the model.
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
            if !isRunning || (state.spaces[emptyIndex].windowIDs.isEmpty && worker == nil &&
                (state.focusedWindowID.map { windowSystem.focusedWindowID() == $0 } ?? emptySpace.isFocused)) { break }
        } while ContinuousClock.now < closeDeadline
        return """
        Last-close running: \(isRunning), suspended: \(isSuspended)
        Closed space removed: \(!state.displayedSpaceIndices.contains(emptyIndex))
        Remaining windows in space: \(state.spaces[emptyIndex].windowIDs.count)
        Destination focused: \(state.focusedWindowID.map { windowSystem.focusedWindowID() == $0 } ?? emptySpace.isFocused)
        Warning: \(warning ?? "none")
        """
    }

    /// Runs the actual Start path, prints no window titles or input, then restores all frames.
    func diagnoseStartup(includeSettings: Bool = false) async -> String {
        windowSystem.focusDiagnosticsEnabled = true
        guard accessibilityGranted else {
            return "Accessibility permission is missing for this build. No windows were changed."
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let settings = includeSettings ? SettingsWindow.make(model: self, showOnboarding: {}) : nil
        if let settings {
            settings.makeKeyAndOrderFront(nil)
            NSApp.activate()
            registerSettingsWindow(settings)
        }
        let began = ContinuousClock.now
        start()
        let deadline = began.advanced(by: .seconds(4))
        while (worker != nil || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        var focusChecks: [String] = []
        if includeSettings {
            for id in state.currentSpace.windowIDs {
                guard isRunning, !isSuspended, ContinuousClock.now < deadline else { break }
                focusWindow(id)
                while (worker != nil || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                focusChecks.append("Focus \(id): \(isRunning && windowSystem.focusedWindowID() == id)")
            }
        }
        var sizing: [String] = []
        if isRunning, !isSuspended, let availableFrame {
            windows = windowSystem.scanWindows()
            for record in windows where state.currentSpace.windowIDs.contains(record.id) {
                guard let frame = windowSystem.frame(windowID: record.id) else { continue }
                sizing.append("Window \(record.id): width=\(frame.width), actualPercent=\(Int((frame.width / availableFrame.width * 100).rounded())), labelPercent=\(actualWidthPercent(for: record) ?? -1)")
                if record.id == state.focusedWindowID {
                    sizing.append("Focused frame: \(frame); available frame: \(availableFrame)")
                }
            }
        }
        let result = """
        Startup running: \(isRunning), suspended: \(isSuspended)
        Managed window count: \(windows.count)
        Layout preparation: \(lastLayoutMilliseconds) ms
        Focus token expired: \(lastFocusTokenExpired)
        Border corner radius: \(borderCornerRadius.map { String(describing: $0) } ?? "fallback")
        Warning: \(warning ?? "none")
        \(focusChecks.joined(separator: "\n"))
        \(sizing.joined(separator: "\n"))
        \(windowSystem.lastFocusReport?.summary ?? "No focus report")
        """
        pause()
        settings?.close()
        _ = previousApp?.activate(options: [])
        return result
    }

    /// Launches only our disposable delayed-window fixture and observes the normal refresh path.
    /// The final assertion intentionally does not scan: that would conceal a missed notification.
    func diagnoseDiscovery(probeURL: URL, settlingWindow: Bool = false) async -> String {
        let probeID = "dev.stagehand.DiscoveryProbe"
        guard Bundle(url: probeURL)?.bundleIdentifier == probeID else {
            return "Discovery failed: expected the Stagehand DiscoveryProbe fixture. No windows were changed."
        }
        guard accessibilityGranted else { return "Discovery failed: Accessibility permission is missing." }
        guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == probeID }) else {
            return "Discovery failed: the disposable probe is already running."
        }
        windowSystem.focusDiagnosticsEnabled = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        var probe: NSRunningApplication?
        defer {
            pause()
            _ = probe?.terminate()
            _ = previousApp?.activate(options: [])
        }
        start()
        let preparationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while worker != nil && ContinuousClock.now < preparationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        navigate(.goToSpace(index: WorkspaceState.spaceCount - 1))
        while worker != nil && ContinuousClock.now < preparationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, !isSuspended, state.currentSpace.windowIDs.isEmpty else {
            return "Discovery failed: could not establish the empty-space fixture. Warning: \(warning ?? "none")"
        }
        let emptySpaceIndex = state.activeSpaceIndex
        print("Discovery t=\(ProcessInfo.processInfo.systemUptime) emptySpace=\(emptySpaceIndex + 1) ready")
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = settlingWindow ? ["--settling-window"] : []
            probe = try await NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration)
        } catch {
            return "Discovery failed: could not launch the disposable probe."
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while isRunning, !isSuspended, ContinuousClock.now < deadline {
            let discovered = windows.filter { $0.bundleIdentifier == probeID }
            if !discovered.isEmpty, discovered.allSatisfy({ state.currentSpace.windowIDs.contains($0.id) }),
               worker == nil, !ribbonMotion.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let discovered = windows.filter { $0.bundleIdentifier == probeID }
        let visibleWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let probeVisible = visibleWindows.contains {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == probe?.processIdentifier &&
            ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }
        let joined = isRunning && !isSuspended && state.activeSpaceIndex == emptySpaceIndex &&
            probeVisible && !discovered.isEmpty && discovered.allSatisfy { state.currentSpace.windowIDs.contains($0.id) }
        return "Discovery passed: \(joined); probeVisible=\(probeVisible); freshWindows=\(discovered.count); space=\(state.activeSpaceIndex + 1); running=\(isRunning); warning=\(warning ?? "none")"
    }

    private func updateInputStatus() {
        var issues = input.issues
        if isRunning && !isSuspended && !focusGate.isAvailable {
            issues.append(focusGate.isSecureInputEnabled
                          ? "Secure Input is on, so Stagehand can't protect typing while switching windows."
                          : "Typing protection is unavailable. Re-enable Accessibility for Stagehand, then retry.")
        }
        if gesturesEnabled { issues.append(contentsOf: InputController.nativeGestureConflicts()) }
        var seen = Set<String>()
        inputIssues = issues.filter { seen.insert($0).inserted }
    }

    private func scheduleRefresh(immediately: Bool = false) {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var firstAttempt = true
            while !Task.isCancelled {
                do {
                    if immediately && firstAttempt { await Task.yield() }
                    else { try await Task.sleep(for: .milliseconds(100)) }
                }
                catch { return }
                firstAttempt = false
                guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended else { return }
                guard self.worker == nil, !self.ribbonMotion.isRunning,
                      self.gestureBase == nil, !self.isLayingOutWindows else { continue }
                self.refreshWindows()
                return
            }
        }
    }

    private func applicationTerminated(pid: Int32) {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        let previousState = state
        let motionStart = navigationFrames()
        let focusedWindowID = state.focusedWindowID
        let removedIDs = removeTerminatedApplication(pid: pid, windows: &windows, state: &state)
        guard !removedIDs.isEmpty else { return }
        focusHistory.remove(windowIDs: removedIDs)
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: focusedWindowID,
            history: focusHistory,
            state: &state
        )
        finishRemovingWindows(removedIDs, focusedWindowID: focusedWindowID)
        diagnostics.record("application_removed", details: [
            "pid": String(pid),
            "windowCount": String(removedIDs.count)
        ])
        enqueue(.windowRemoval, transitionFrom: previousState, motionStart: motionStart)
        onStateChange?()
    }

    private func windowDestroyed(windowID: String) {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        let previousState = state
        let motionStart = navigationFrames()
        let focusedWindowID = state.focusedWindowID
        guard removeDestroyedWindow(windowID: windowID, windows: &windows, state: &state) else { return }
        let removedIDs = Set([windowID])
        focusHistory.remove(windowIDs: removedIDs)
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: focusedWindowID,
            history: focusHistory,
            state: &state
        )
        finishRemovingWindows(removedIDs, focusedWindowID: focusedWindowID)
        diagnostics.record("window_removed", details: ["windowID": windowID])
        enqueue(.windowRemoval, transitionFrom: previousState, motionStart: motionStart)
        onStateChange?()
    }

    private func windowMiniaturized(windowID: String) {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        let previousState = state
        let motionStart = navigationFrames()
        let focusedWindowID = state.focusedWindowID
        guard removeUnavailableWindow(
            windowID: windowID,
            windows: &windows,
            state: &state,
            restoration: &workspaceRestoration,
            trackedWindowIDs: windowSystem.trackedWindowIDs
        ) else { return }
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: focusedWindowID,
            history: focusHistory,
            state: &state
        )
        finishRemovingWindows([windowID], focusedWindowID: focusedWindowID)
        diagnostics.record("window_unavailable", details: ["windowID": windowID, "reason": "minimized"])
        enqueue(.windowRemoval, transitionFrom: previousState, motionStart: motionStart)
        onStateChange?()
    }

    private func windowDeminiaturized(windowID: String) {
        guard isRunning, !isSuspended,
              let window = windowSystem.record(windowID: windowID) else { return }
        refreshTask?.cancel()
        guard restoreAvailableWindow(
            window,
            windows: &windows,
            state: &state,
            restoration: &workspaceRestoration,
            trackedWindowIDs: windowSystem.trackedWindowIDs,
            initialWidthFractions: initialWidthFractions(for: [window])
        ) else { return }
        if state.currentSpace.windowIDs.contains(windowID) {
            state.focus(windowID: windowID)
        } else if let spaceIndex = state.spaces.firstIndex(where: { $0.windowIDs.contains(windowID) }) {
            state.focus(windowID: windowID, inSpace: spaceIndex)
        }
        diagnostics.record("window_available", details: ["windowID": windowID, "reason": "restored"])
        enqueue(.refresh)
        onStateChange?()
    }

    private func finishRemovingWindows(_ removedIDs: Set<String>, focusedWindowID: String?) {
        if ribbonMotion.isRunning {
            presentationFrames = ribbonMotion.frames.filter { !removedIDs.contains($0.key) }
            ribbonMotion.cancel()
        }
        if focusedWindowID.map(removedIDs.contains) == true {
            focusGate.cancelAll()
        }
        if var rollback = transitionRollback {
            rollback.reconcile(windowIDs: windows.map(\.id))
            transitionRollback = rollback
        }
        preferredHeights = preferredHeights.filter { !removedIDs.contains($0.key) }
        lastAppliedFrames = lastAppliedFrames.filter { !removedIDs.contains($0.key) }
        motionWrittenPositions = motionWrittenPositions.filter { !removedIDs.contains($0.key) }
        presentationFrames = presentationFrames?.filter { !removedIDs.contains($0.key) }
        gestureBase = gestureBase?.filter { !removedIDs.contains($0.key) }
        gesturePrepared.subtract(removedIDs)
        if borderWindowID.map(removedIDs.contains) == true { hideFocusBorder() }
    }

    private func observedFocusChanged(windowID: String) {
        guard isRunning, !isSuspended, worker == nil, gestureBase == nil,
              windows.contains(where: { $0.id == windowID }), desktopScope.refresh() == .home else { return }
        if windowID == state.focusedWindowID {
            // Activating the already-selected app can raise its window above the
            // still-visible border without changing logical focus.
            if let frame = windowSystem.frame(windowID: windowID) {
                updateFocusBorder(
                    windowID: windowID,
                    frame: frame,
                    refreshShape: false,
                    reorderAboveTarget: true
                )
            }
            return
        }
        observedFocusTask?.cancel()
        if ribbonMotion.isRunning { presentationFrames = ribbonMotion.frames }
        ribbonMotion.cancel()
        let original = windowSystem.frame(windowID: windowID)
        observedFocusTask = Task { [weak self] in
            // Let the click finish before moving its target. During a title-bar drag,
            // leave geometry to the existing drop/reorder path instead.
            while NSEvent.pressedMouseButtons & 1 != 0 {
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, self.worker == nil,
                  self.desktopScope.refresh() == .home,
                  self.windowSystem.focusedWindowID() == windowID else { return }
            if self.windowSystem.frame(windowID: windowID) != original {
                self.refreshWindows()
                return
            }
            self.refreshTask?.cancel()
            // macOS already owns the click/focus handoff. Do not activate again or
            // intercept typing to follow an observed, verified focus change.
            self.enqueue(.observedFocus(windowID))
        }
    }

    private func refreshWindows() {
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        let motionStart = navigationFrames()
        let current = windowSystem.scanWindows()
        let oldState = state
        windows = current
        workspaceRestoration.reconcile(state: &state, windowIDs: current.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs,
                                       initialWidthFractions: initialWidthFractions(for: current))
        if oldState.activeSpaceIndex == state.activeSpaceIndex,
           let focused = windowSystem.focusedWindowID(),
           shouldFollowObservedFocus(
               observedWindowID: focused,
               discoveredWindowIDs: Set(current.map(\.id))
           ) {
            // External app activation follows an existing membership; shared windows stay in this space.
            if !state.currentSpace.windowIDs.contains(focused),
               let space = state.spaces.firstIndex(where: { $0.windowIDs.contains(focused) }) {
                state.apply(.goToSpace(index: space))
            }
            state.focus(windowID: focused)
        }
        // Do not fight a title-bar drag or resize. Observe the window while the
        // mouse is held, then apply its drop to the ribbon after mouse-up.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            if pointerInteraction == nil, let focused = focusedWindow, let frame = availableFrame {
                pointerInteraction = PointerInteraction(
                    windowID: focused.id,
                    placements: WindowLayout.placements(for: oldState, availableFrame: frame, gap: gap),
                    needsLayout: oldState != state
                )
            } else if oldState != state {
                pointerInteraction?.needsLayout = true
            }
            if let focused = focusedWindow {
                updateFocusBorder(windowID: focused.id, frame: focused.frame, refreshShape: false)
            }
            scheduleRefresh()
            return
        }
        let interaction = pointerInteraction
        pointerInteraction = nil
        var needsLayout = interaction?.needsLayout ?? false
        if let focused = focusedWindow,
           let previous = lastAppliedFrames[focused.id],
           let frame = availableFrame {
            let resized = abs(focused.frame.width - previous.width) > 3 ||
                abs(focused.frame.height - previous.height) > 3
            let moved = abs(focused.frame.minX - previous.minX) > 3 ||
                abs(focused.frame.minY - previous.minY) > 3
            if (resized || moved) && (interaction != nil || Date().timeIntervalSince(lastTransition) > 0.4) {
                if resized {
                    state.setWidthFraction(focused.frame.width / frame.width, for: focused.id)
                    preferredHeights[focused.id] = focused.frame.height
                }
                if moved && !resized {
                    let placements: [WindowPlacement]
                    if let interaction, interaction.windowID == focused.id {
                        placements = interaction.placements
                    } else {
                        placements = WindowLayout.placements(for: oldState, availableFrame: frame, gap: gap)
                    }
                    let destination = placements.filter {
                        $0.windowID != focused.id && $0.frame.midX < focused.frame.midX
                    }.count
                    state.reorderWindow(windowID: focused.id, to: destination)
                }
                needsLayout = true
            } else if resized || moved {
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, self.worker == nil else { return }
                    self.refreshWindows()
                }
            }
        }
        if oldState != state || needsLayout {
            let removedFromCurrentSpace = Set(oldState.currentSpace.windowIDs)
                .subtracting(current.map(\.id))
            if !removedFromCurrentSpace.isEmpty {
                enqueue(.windowRemoval, transitionFrom: oldState, motionStart: motionStart)
            } else {
                enqueue(preferencesNeedLayout ? .preferences : .refresh)
            }
        } else if preferencesNeedLayout,
                  LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: windowSystem.focusedWindowID()) != nil {
            enqueue(.preferences)
        } else if let id = state.focusedWindowID, let frame = windowSystem.frame(windowID: id) {
            updateFocusBorder(windowID: id, frame: frame)
        }
        onStateChange?()
    }

    private func initialWidthFractions(for windows: [WindowRecord]) -> [String: Double] {
        guard let availableFrame, availableFrame.width.isFinite, availableFrame.width > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            guard window.frame.width.isFinite, window.frame.width > 0 else { return nil }
            return (window.id, Double(window.frame.width / availableFrame.width))
        })
    }

    private func enqueue(
        _ change: Change,
        initialHorizontalVelocity: CGFloat? = nil,
        transitionFrom previousState: WorkspaceState? = nil,
        motionStart: [String: CGRect]? = nil
    ) {
        if traceGestures, gestureAxis != nil {
            NSLog("[DEBUG-gesture] layout requested during drag: %@", String(describing: change))
        }
        guard isRunning, !isSuspended else { return }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        if change == .preferences, pending.contains(where: { $0.change == .preferences }) { return }
        // Capture typing before the asynchronous AX activation starts.
        let token = change.policy.beginInputTransfer {
            focusGate.isAvailable ? focusGate.beginTransfer() : nil
        }
        pending.append(PendingChange(
            change: change,
            token: token,
            initialHorizontalVelocity: initialHorizontalVelocity,
            previousState: previousState,
            motionStart: motionStart
        ))
        diagnostics.record("change_queued", details: [
            "operation": change.diagnosticName,
            "pendingChanges": String(pending.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        if change.isWindowNavigation, worker != nil, ribbonMotion.isAnimating {
            ribbonMotion.cancel()
        }
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            var batchMotionStart: [String: CGRect]?
            var batchInitialHorizontalVelocity: CGFloat?
            while self.isRunning && !self.isSuspended && !Task.isCancelled && !self.pending.isEmpty {
                let pendingChange = self.pending.removeFirst()
                let change = pendingChange.change
                let token = pendingChange.token
                self.diagnostics.record("change_started", details: [
                    "operation": change.diagnosticName,
                    "pendingChanges": String(self.pending.count),
                    "transferToken": token.map(String.init) ?? "none"
                ])
                let rollbackState = self.transitionRollback ?? self.state
                let previousState = pendingChange.previousState ?? rollbackState
                self.transitionRollback = rollbackState
                let hadPreview = self.presentationFrames != nil
                let motionStart = pendingChange.motionStart ?? batchMotionStart ?? self.navigationFrames()
                let initialHorizontalVelocity = batchInitialHorizontalVelocity
                    ?? pendingChange.initialHorizontalVelocity
                self.ribbonMotion.cancel()
                self.presentationFrames = nil
                if self.gestureAxis != nil { self.input.cancelGestureSequence() }
                self.gestureBase = nil
                self.gestureAxis = nil
                self.gesturePrepared.removeAll()
                switch change {
                case .action(let action) where action == .shrinkHeight || action == .growHeight:
                    guard self.adjustFocusedWindowHeight(growing: action == .growHeight) else {
                        if let token { self.focusGate.cancelTransfer(token: token) }
                        self.transitionRollback = nil
                        continue
                    }
                case .action(let action):
                    guard self.state.apply(action) else {
                        if let token { self.focusGate.cancelTransfer(token: token) }
                        self.transitionRollback = nil
                        continue
                    }
                case .remove(let id): self.state.removeFromCurrentSpace(windowID: id)
                case .share(let id, let index): self.state.share(windowID: id, toSpace: index)
                case .focus(let id): self.state.focus(windowID: id)
                case .moveMembership(let id, let sourceIndex, let destinationIndex):
                    self.state.move(windowID: id, fromSpace: sourceIndex, toSpace: destinationIndex)
                case .shareMembership(let id, let sourceIndex, let destinationIndex):
                    self.state.share(windowID: id, fromSpace: sourceIndex, toSpace: destinationIndex)
                case .removeMembership(let id, let sourceIndex):
                    self.state.remove(windowID: id, fromSpace: sourceIndex)
                case .reorderWindow(let id, let index, let spaceIndex):
                    self.state.reorderWindow(windowID: id, to: index, inSpace: spaceIndex)
                case .focusInSpace(let id, let spaceIndex):
                    self.state.focus(windowID: id, inSpace: spaceIndex)
                case .windowRemoval, .refresh, .preferences, .observedFocus: break
                }
                if change.isWindowNavigation, self.pending.first?.change.isWindowNavigation == true,
                   let token, self.focusGate.cancelTransferIfEmpty(token: token) {
                    // Keep every navigation step in state, but avoid flashing intermediate
                    // windows when no typing belongs to them. Never merge input tokens.
                    batchMotionStart = motionStart
                    batchInitialHorizontalVelocity = initialHorizontalVelocity
                    continue
                }
                batchMotionStart = nil
                batchInitialHorizontalVelocity = nil
                if change.policy == .preferences {
                    let focusedWindowID = self.windowSystem.focusedWindowID()
                    let prepared: WorkspaceState?
                    if case .observedFocus(let notificationWindowID) = change {
                        prepared = prepareObservedFocus(
                            state: self.state,
                            notificationWindowID: notificationWindowID,
                            focusedWindowID: focusedWindowID
                        )
                    } else {
                        self.preferencesNeedLayout = true
                        prepared = change.policy.prepare(state: self.state, focusedWindowID: focusedWindowID)
                    }
                    guard let prepared else {
                        if case .observedFocus = change {
                            self.diagnostics.record("change_skipped", details: [
                                "operation": change.diagnosticName,
                                "reason": "focus_changed_before_layout"
                            ])
                        }
                        self.transitionRollback = nil
                        continue
                    }
                    self.preferencesNeedLayout = true
                    self.state = prepared
                }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let canSlide = shouldSlideRibbon(
                    from: previousState,
                    to: self.state,
                    source: change.ribbonTransitionSource,
                    hadPreview: hadPreview,
                    reduceMotion: reduceMotion
                )
                if change.policy == .navigation, self.diagnostics.isEnabled {
                    let destinationID = self.state.focusedWindowID
                    let observedFocus = self.windowSystem.focusedWindowID()
                    let membershipCount = destinationID.map { id in
                        self.state.spaces.count { $0.windowIDs.contains(id) }
                    } ?? 0
                    self.diagnostics.record("navigation_motion_planned", details: [
                        "destinationFocusedWindowID": destinationID ?? "none",
                        "destinationMembershipCount": String(membershipCount),
                        "destinationParked": String(destinationID.map { self.windowSystem.isParked(windowID: $0) } ?? false),
                        "destinationSpace": String(self.state.activeSpaceIndex + 1),
                        "destinationWasSystemFocused": String(destinationID != nil && destinationID == observedFocus),
                        "hadGesturePreview": String(hadPreview),
                        "motionStartWindowCount": String(motionStart.count),
                        "observedFocusedWindowID": observedFocus ?? "none",
                        "operation": change.diagnosticName,
                        "previousFocusedWindowID": previousState.focusedWindowID ?? "none",
                        "previousSpace": String(previousState.activeSpaceIndex + 1),
                        "reduceMotion": String(reduceMotion),
                        "slideEnabled": String(canSlide)
                    ])
                }
                self.layoutFailureReason = nil
                let succeeded = await self.applyLayout(token: token, request: change.policy,
                                                       operation: change.diagnosticName,
                                                       slideFrom: canSlide ? motionStart : nil,
                                                       initialHorizontalVelocity: canSlide
                                                        ? initialHorizontalVelocity : nil,
                                                       focusAlongsideSlide: change.focusesAlongsideRibbon)
                guard generation == self.workerGeneration, !Task.isCancelled else { return }
                if !succeeded {
                    self.state = rollbackState
                    self.stop(
                        reason: self.layoutFailureReason ?? "layout_stopped_unexpectedly",
                        automatic: true,
                        details: ["operation": change.diagnosticName]
                    )
                    return
                }
                if let focusedWindowID = self.state.focusedWindowID {
                    self.focusHistory.record(windowID: focusedWindowID)
                }
                self.diagnostics.record("change_completed", details: ["operation": change.diagnosticName])
                self.transitionRollback = nil
            }
            guard generation == self.workerGeneration, !Task.isCancelled else { return }
            self.worker = nil
            self.onStateChange?()
            self.scheduleRefresh()
        }
    }

    private func adjustFocusedWindowHeight(growing: Bool) -> Bool {
        guard let windowID = state.focusedWindowID,
              let availableFrame else { return false }
        let currentHeight = windowSystem.frame(windowID: windowID)?.height
            ?? preferredHeights[windowID]
            ?? availableFrame.height
        guard let height = adjustedWindowHeight(
            current: currentHeight,
            available: availableFrame.height,
            growing: growing
        ) else { return false }
        preferredHeights[windowID] = height
        return true
    }

    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
    }

    private var availableFrame: CGRect? {
        guard let screen = builtInScreen, let primary = NSScreen.screens.first else { return nil }
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func failLayout(_ reason: String, details: [String: String] = [:]) -> Bool {
        layoutFailureReason = reason
        var context = workspaceDetails()
        context["reason"] = reason
        context.merge(details) { _, new in new }
        diagnostics.record("layout_failed", details: context)
        return false
    }

    private func focusManagedWindow(_ record: WindowRecord, token: UInt64?,
                                    request: LayoutRequestPolicy, operation: String) async -> Bool {
        let observedFocusBefore = diagnostics.isEnabled ? windowSystem.focusedWindowID() : nil
        let focused = await request.confirmFocus(
            windowID: record.id,
            currentFocus: { windowSystem.focusedWindowID() },
            activate: { await windowSystem.focus(windowID: record.id) }
        )
        if request == .navigation, diagnostics.isEnabled {
            let observedFocusAfter = windowSystem.focusedWindowID()
            var details = [
                "focusConfirmed": String(focused),
                "membershipCount": String(state.spaces.count { $0.windowIDs.contains(record.id) }),
                "observedFocusedWindowIDAfter": observedFocusAfter ?? "none",
                "observedFocusedWindowIDBefore": observedFocusBefore ?? "none",
                "operation": operation,
                "parkedAfter": String(windowSystem.isParked(windowID: record.id)),
                "systemFocusedAfter": String(observedFocusAfter == record.id),
                "systemFocusedBefore": String(observedFocusBefore == record.id),
                "windowID": record.id
            ]
            if observedFocusBefore != record.id, let report = windowSystem.lastFocusReport {
                details["focusReport"] = report.summary
            }
            diagnostics.record("navigation_focus_confirmed", details: details)
        }
        if request == .preferences, !focused { return true }
        lastFocusTokenExpired = token.map { expiredTokens.contains($0) } ?? false
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return false
        }
        guard isRunning, !isSuspended, !Task.isCancelled else {
            if let token { focusGate.cancelTransfer(token: token) }
            return false
        }
        guard focused, token.map({ expiredTokens.contains($0) }) != true else {
            if let token { focusGate.cancelTransfer(token: token) }
            warning = "Stagehand couldn't focus \(record.appName). It paused and restored your windows. Check for an open dialog or changed permissions."
            var details = [
                "bundleIdentifier": record.bundleIdentifier,
                "focusConfirmed": String(focused),
                "pid": String(record.pid),
                "transferExpired": String(token.map { expiredTokens.contains($0) } ?? false),
                "windowID": record.id
            ]
            if let report = windowSystem.lastFocusReport { details["focusReport"] = report.summary }
            return failLayout("focus_confirmation_failed", details: details)
        }
        return true
    }

    private func applyLayout(token: UInt64?, request: LayoutRequestPolicy, operation: String,
                             slideFrom: [String: CGRect]? = nil,
                             initialHorizontalVelocity: CGFloat? = nil,
                             focusAlongsideSlide: Bool = false) async -> Bool {
        let layoutStart = ContinuousClock.now
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return false
        }
        guard let availableFrame else {
            if let token { focusGate.cancelTransfer(token: token) }
            return failLayout("display_frame_unavailable")
        }
        // Native frame setters and focus confirmation are separate operations. Never
        // leave the old outline on screen or follow their intermediate notifications.
        isLayingOutWindows = true
        overlays.updateBorder(frame: .zero, visible: false)
        defer { isLayingOutWindows = false }
        var placements: [WindowPlacement] = []
        // Capture a new window's preferred height before the first managed size write.
        // Accepted constraints belong to this layout pass, not the saved preference.
        let knownIDs = Set(windows.map(\.id))
        preferredHeights = preferredHeights.filter { knownIDs.contains($0.key) }
        for window in windows where preferredHeights[window.id] == nil {
            preferredHeights[window.id] = windowSystem.frame(windowID: window.id)?.height ?? window.frame.height
        }
        var observedWidths: [String: CGFloat] = [:]
        var observedHeights: [String: CGFloat] = [:]
        var acceptedFrames: [String: CGRect] = [:]
        var constraintObservations: [(pass: Int, windowID: String, requested: CGRect,
                                      actual: CGRect, axes: String)] = []
        var destinationPID: Int32?
        // Read accepted sizes after focus, then repack and center app-constrained windows.
        // Repacking may reveal another window. Bound this by the number of windows;
        // the input gate's deadline also applies to the whole transition.
        let maximumPass = state.currentSpace.windowIDs.count
        for pass in 0...maximumPass {
            guard preferenceFocusStillMatches(request) else { return true }
            placements = WindowLayout.placements(for: state, availableFrame: availableFrame, gap: gap,
                                                 observedWidths: observedWidths, preferredHeights: preferredHeights,
                                                 observedHeights: observedHeights)
            let visible = placements.filter { $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true }
            // Position neighbors first. Raising the focused real window last keeps clamped neighbors behind it.
            for placement in visible.sorted(by: { !$0.isFocused && $1.isFocused }) {
                // A correction pass only writes windows whose geometry actually changed.
                var preparedFrame = placement.frame
                if let start = slideFrom?[placement.windowID] { preparedFrame.origin.x = start.minX }
                if pass > 0, acceptedFrames[placement.windowID] == preparedFrame { continue }
                if !windowSystem.isParked(windowID: placement.windowID),
                   let current = windowSystem.frame(windowID: placement.windowID),
                   framesMatch(observed: current, target: preparedFrame) {
                    acceptedFrames[placement.windowID] = current
                    lastAppliedFrames[placement.windowID] = current
                    continue
                }
                let frameWritten = windowSystem.setFrame(windowID: placement.windowID, frame: preparedFrame)
                let actualFrame = windowSystem.frame(windowID: placement.windowID)
                if !frameWritten, placement.isFocused {
                    recordWindowGeometry(
                        event: "frame_write_constrained",
                        windowID: placement.windowID,
                        requestedFrame: preparedFrame,
                        actualFrame: actualFrame,
                        details: ["pass": String(pass + 1)]
                    )
                }
                lastAppliedFrames[placement.windowID] = actualFrame
            }
            if let focusedID = state.focusedWindowID,
               let record = windows.first(where: { $0.id == focusedID }) {
                let preparation = layoutStart.duration(to: .now).components
                lastLayoutMilliseconds = Int(preparation.seconds * 1_000 + preparation.attoseconds / 1_000_000_000_000_000)
                if request == .navigation { emptySpace.hide() }
                if slideFrom == nil {
                    guard await focusManagedWindow(
                        record,
                        token: token,
                        request: request,
                        operation: operation
                    ) else { return false }
                    destinationPID = record.pid
                }
                var constrained = false
                for placement in visible {
                    guard let actual = windowSystem.frame(windowID: placement.windowID) else { continue }
                    acceptedFrames[placement.windowID] = actual
                    var constrainedAxes: [String] = []
                    if actual.width.isFinite, actual.width > 0,
                       abs(actual.width - placement.frame.width) > 1 {
                        observedWidths[placement.windowID] = actual.width
                        state.setWidthFraction(actual.width / availableFrame.width, for: placement.windowID)
                        constrained = true
                        constrainedAxes.append("width")
                    }
                    if actual.height.isFinite, actual.height > 0,
                       abs(actual.height - placement.frame.height) > 1 {
                        observedHeights[placement.windowID] = actual.height
                        constrained = true
                        constrainedAxes.append("height")
                    }
                    if !constrainedAxes.isEmpty {
                        constraintObservations.append((
                            pass: pass + 1,
                            windowID: placement.windowID,
                            requested: placement.frame,
                            actual: actual,
                            axes: constrainedAxes.joined(separator: ",")
                        ))
                    }
                }
                if constrained {
                    guard pass < maximumPass else {
                        if let token { focusGate.cancelTransfer(token: token) }
                        warning = "Window sizes kept changing. Stagehand paused and restored your windows."
                        for observation in constraintObservations {
                            recordWindowGeometry(
                                event: "window_size_constraint_observed",
                                windowID: observation.windowID,
                                requestedFrame: observation.requested,
                                actualFrame: observation.actual,
                                details: [
                                    "constraintAxes": observation.axes,
                                    "pass": String(observation.pass)
                                ]
                            )
                        }
                        return failLayout("window_size_constraints_unstable", details: [
                            "constraintObservationCount": String(constraintObservations.count),
                            "layoutPasses": String(pass + 1)
                        ])
                    }
                    continue
                }
            } else {
                guard request == .navigation else { return true }
                // An empty space owns a real blank window so typing cannot leak to a parked app.
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return false
                }
                let focused = await emptySpace.show(space: state.activeSpaceIndex + 1, frame: availableFrame)
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return false
                }
                guard focused, isRunning, !isSuspended, !Task.isCancelled else {
                    if let token { focusGate.cancelTransfer(token: token) }
                    warning = "Stagehand couldn't open the empty space. It paused and restored your windows."
                    return failLayout("empty_space_focus_failed", details: [
                        "focusConfirmed": String(focused),
                        "taskCancelled": String(Task.isCancelled)
                    ])
                }
                destinationPID = ProcessInfo.processInfo.processIdentifier
            }
            break
        }
        let visibleIDs = Set(placements.filter(\.isVisible).map(\.windowID))
        let motionCandidates = placements.filter {
            $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true
        }
        let sliding = motionCandidates
        let animatedWindowIDs = slideFrom == nil ? Set<String>() : Set(sliding.map(\.windowID))
        guard preferenceFocusStillMatches(request) else { return true }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return false
        }
        for window in windows where !visibleIDs.contains(window.id) && !animatedWindowIDs.contains(window.id) {
            let parkingSide = preferredParkingSide(
                for: placements.first(where: { $0.windowID == window.id })?.frame,
                relativeTo: availableFrame
            )
            if parkWindow(
                windowID: window.id,
                park: { windowSystem.park(windowID: $0, preferredSide: parkingSide) },
                observedFrame: { windowSystem.observedFrame(windowID: $0) }
            ) == .failed {
                warning = "Stagehand couldn't move \(window.appName) out of this space. It paused and restored your windows."
                return failLayout("window_parking_failed", details: [
                    "bundleIdentifier": window.bundleIdentifier,
                    "pid": String(window.pid),
                    "windowID": window.id
                ])
            }
        }
        guard preferenceFocusStillMatches(request) else { return true }
        preferencesNeedLayout = false
        if slideFrom != nil {
            let starts = Dictionary(uniqueKeysWithValues: sliding.compactMap { placement in
                windowSystem.frame(windowID: placement.windowID).map { (placement.windowID, $0) }
            })
            let targets = Dictionary(uniqueKeysWithValues: sliding.map { ($0.windowID, $0.frame) })
            let translate = {
                let completed = await self.settleRibbon(
                    from: starts,
                    to: targets,
                    visibleIDs: visibleIDs,
                    operation: operation,
                    initialHorizontalVelocity: initialHorizontalVelocity
                )
                if completed { return RibbonTranslationOutcome.readyForFocus }
                guard self.isRunning, !self.isSuspended, !Task.isCancelled else {
                    return RibbonTranslationOutcome.failed
                }
                guard !self.pending.isEmpty else { return RibbonTranslationOutcome.readyForFocus }
                guard let token else { return RibbonTranslationOutcome.superseded }
                return self.focusGate.cancelTransferIfEmpty(token: token)
                    ? RibbonTranslationOutcome.superseded : RibbonTranslationOutcome.readyForFocus
            }
            let focus = {
                guard let focusedID = self.state.focusedWindowID,
                      let record = self.windows.first(where: { $0.id == focusedID }),
                      await self.focusManagedWindow(
                        record,
                        token: token,
                        request: request,
                        operation: operation
                      ) else { return false }
                destinationPID = record.pid
                if !focusAlongsideSlide,
                   let target = placements.first(where: { $0.windowID == focusedID })?.frame,
                   let actual = self.windowSystem.frame(windowID: focusedID),
                   !framesMatch(observed: actual, target: target) {
                    _ = self.windowSystem.setFrame(windowID: focusedID, frame: target)
                    self.lastAppliedFrames[focusedID] = self.windowSystem.frame(windowID: focusedID)
                }
                if !focusAlongsideSlide,
                   let frame = self.windowSystem.frame(windowID: focusedID) {
                    self.updateFocusBorder(windowID: focusedID, frame: frame, reorderAboveTarget: true)
                }
                return true
            }
            let focusConfirmed = {
                if request == .navigation {
                    self.overlays.showNavigation(state: self.state, windows: self.windows)
                }
            }
            let commitInput = {
                if let token, let destinationPID {
                    self.focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                }
            }
            let revealBorder = {
                if let focused = self.state.focusedWindowID,
                   let frame = self.windowSystem.frame(windowID: focused) {
                    self.updateFocusBorder(windowID: focused, frame: frame)
                } else {
                    self.hideFocusBorder()
                }
            }
            let outcome = if focusAlongsideSlide {
                await runConcurrentRemovalNavigation(
                    translate: translate,
                    cancelTranslation: { self.ribbonMotion.cancel() },
                    focus: focus,
                    focusConfirmed: focusConfirmed,
                    commitInput: commitInput,
                    revealBorder: revealBorder
                )
            } else {
                await runFocusFirstNavigation(
                    translate: translate,
                    focus: focus,
                    focusConfirmed: focusConfirmed,
                    commitInput: commitInput,
                    revealBorder: revealBorder
                )
            }
            switch outcome {
            case .superseded: return true
            case .failed: return false
            case .completed: break
            }
            if token != nil, destinationPID != nil {
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return false }
            }
        } else {
            lastTransition = Date()
            if let token, let destinationPID {
                focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                // Posting to a process is asynchronous, not an OS delivery acknowledgement.
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return false }
            }
            if let focused = state.focusedWindowID, let frame = windowSystem.frame(windowID: focused) {
                updateFocusBorder(windowID: focused, frame: frame, reorderAboveTarget: true)
            } else {
                hideFocusBorder()
            }
        }
        overlays.setBorderColor(focusBorderColor)
        if request == .navigation { overlays.showNavigation(state: state, windows: windows) }
        else { overlays.updateNavigation(state: state, windows: windows) }
        return true
    }

    private func navigationFrames() -> [String: CGRect] {
        guard let availableFrame else { return [:] }
        let members = Set(state.currentSpace.windowIDs)
        let actual = Dictionary(uniqueKeysWithValues: windows.filter { members.contains($0.id) }.compactMap { window in
            windowSystem.frame(windowID: window.id).map { (window.id, $0) }
        })
        let placements = WindowLayout.placements(for: state, availableFrame: availableFrame, gap: gap,
                                                 observedWidths: actual.mapValues(\.width),
                                                 observedHeights: actual.mapValues(\.height))
        var frames = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.windowID, $0.isVisible ? actual[$0.windowID] ?? $0.frame : $0.frame)
        })
        if ribbonMotion.isRunning { frames.merge(ribbonMotion.frames) { _, moving in moving } }
        if let presentationFrames { frames.merge(presentationFrames) { _, moving in moving } }
        return frames
    }

    private func applyMotionFrames(_ frames: [String: CGRect]) {
        guard isRunning, !isSuspended, desktopScope.relation == .home else {
            ribbonMotion.cancel()
            if isRunning { nativeDesktopChanged() }
            return
        }
        if gestureBase == nil, NSEvent.pressedMouseButtons & 1 != 0 {
            // A real pointer interaction takes over from decorative settling.
            presentationFrames = ribbonMotion.frames
            ribbonMotion.cancel()
            scheduleRefresh()
            return
        }
        writeRibbonPositions(
            frames: frames,
            writtenPositions: &motionWrittenPositions,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) }
        )
        // The border is a Stagehand overlay, so it can follow the destination at
        // display cadence without activating that app or disturbing ribbon motion.
        if gestureBase == nil,
           let focused = state.focusedWindowID,
           borderWindowID == focused,
           var frame = frames[focused] {
            frame.origin = motionWrittenPositions[focused]
                ?? RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: motionBackingScaleFactor)
            updateFocusBorder(windowID: focused, frame: frame)
        }
    }

    private func settleRibbon(from: [String: CGRect], to: [String: CGRect], visibleIDs: Set<String>,
                              operation: String, initialHorizontalVelocity: CGFloat? = nil) async -> Bool {
        motionBackingScaleFactor = builtInScreen?.backingScaleFactor ?? 1
        motionWrittenPositions = from.mapValues {
            RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
        }
        let animationConfiguration = RibbonAnimationConfiguration(
            duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : ribbonAnimationConfiguration.duration,
            curve: ribbonAnimationConfiguration.curve,
            tracking: ribbonAnimationConfiguration.tracking,
            commitProgress: ribbonAnimationConfiguration.commitProgress,
            flickDistance: ribbonAnimationConfiguration.flickDistance,
            flickVelocity: ribbonAnimationConfiguration.flickVelocity,
            edgeResistance: ribbonAnimationConfiguration.edgeResistance
        )
        if diagnostics.isEnabled {
            diagnostics.record("ribbon_animation_started", details: [
                "curve": animationConfiguration.curve.diagnosticDescription,
                "durationMilliseconds": String(Int((animationConfiguration.duration * 1_000).rounded())),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "initialHorizontalVelocity": initialHorizontalVelocity.map { String(Double($0)) } ?? "none",
                "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ])
        }
        let animationStart = ProcessInfo.processInfo.systemUptime
        let completed = await ribbonMotion.animate(
            from: from,
            to: to,
            configuration: animationConfiguration,
            initialHorizontalVelocity: initialHorizontalVelocity,
            update: { [weak self] in self?.applyMotionFrames($0) }
        )
        guard completed, isRunning, !isSuspended, desktopScope.refresh() == .home else { return false }
        var visibleFrames = to.filter { visibleIDs.contains($0.key) }
        var commitFailures = commitRibbonPositions(
            frames: visibleFrames,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
            observedFrame: { windowSystem.observedFrame(windowID: $0) }
        )
        for delay in [8, 24, 56] where !commitFailures.isEmpty {
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { return false }
            guard isRunning, !isSuspended, !Task.isCancelled,
                  desktopScope.refresh() == .home else { return false }
            let failedIDs = Set(commitFailures.map(\.windowID))
            visibleFrames = visibleFrames.filter { failedIDs.contains($0.key) }
            commitFailures = commitRibbonPositions(
                frames: visibleFrames,
                backingScaleFactor: motionBackingScaleFactor,
                setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
                observedFrame: { windowSystem.observedFrame(windowID: $0) }
            )
        }
        if let failure = commitFailures.first {
            recordWindowGeometry(
                event: "ribbon_position_commit_failed",
                windowID: failure.windowID,
                requestedFrame: failure.requestedFrame,
                actualFrame: failure.actualFrame,
                details: ["attempts": "4"]
            )
            warning = "Stagehand couldn't place the destination window safely. It paused and restored your windows."
            layoutFailureReason = "ribbon_position_commit_failed"
            return false
        }
        if diagnostics.isEnabled {
            let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - animationStart) * 1_000).rounded())
            diagnostics.record("ribbon_animation_completed", details: [
                "elapsedMilliseconds": String(elapsedMilliseconds),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ])
        }
        for window in windows where !visibleIDs.contains(window.id) {
            let parkingSide = availableFrame.flatMap {
                    preferredParkingSide(for: to[window.id], relativeTo: $0)
            }
            if parkWindow(
                windowID: window.id,
                park: { windowSystem.park(windowID: $0, preferredSide: parkingSide) },
                observedFrame: { windowSystem.observedFrame(windowID: $0) }
            ) == .failed {
                warning = "Stagehand couldn't move \(window.appName) out of this space. It paused and restored your windows."
                stop(
                    reason: "ribbon_parking_failed",
                    automatic: true,
                    details: [
                        "bundleIdentifier": window.bundleIdentifier,
                        "pid": String(window.pid),
                        "windowID": window.id
                    ]
                )
                return false
            }
        }
        for id in visibleIDs { lastAppliedFrames[id] = windowSystem.frame(windowID: id) }
        lastTransition = Date()
        return true
    }

    private func handleGesture(_ event: GestureNavigationEvent) {
        if traceGestures {
            switch event {
            case .changed: break
            default:
                NSLog("[DEBUG-gesture] delivered %@ running=%d suspended=%d worker=%d axis=%@", String(describing: event),
                      isRunning, isSuspended, worker != nil, String(describing: gestureAxis))
            }
        }
        guard isRunning, !isSuspended else { return }
        switch event {
        case .began(let axis, let displacement):
            guard desktopScope.refresh() == .home else { return }
            gestureAxis = axis
            if worker == nil, axis == .horizontal, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let frames = navigationFrames()
                ribbonMotion.cancel()
                gestureBase = frames
                presentationFrames = frames.filter { $0.value.intersects(availableFrame ?? .zero) }
                gesturePrepared = Set(presentationFrames?.keys.map { $0 } ?? [])
                motionBackingScaleFactor = builtInScreen?.backingScaleFactor ?? 1
                motionWrittenPositions = presentationFrames?.mapValues {
                    RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
                } ?? [:]
                if diagnostics.isEnabled {
                    diagnostics.record("gesture_motion_started", details: [
                        "focusedWindowID": state.focusedWindowID ?? "none",
                        "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                        "preparedWindowCount": String(gesturePrepared.count),
                        "trackedWindowCount": String(frames.count)
                    ])
                }
                overlays.updateBorder(frame: .zero, visible: false)
                previewGesture(displacement: displacement)
            }
        case .changed(let displacement, _):
            previewGesture(displacement: displacement)
        case .ended(let displacement, let velocity, let action):
            guard let gestureAxis else { return }
            finishGesture(axis: gestureAxis, displacement: displacement,
                          velocity: velocity, recognizerAction: action)
        case .cancelled:
            gestureAxis = nil
            restoreGesturePreview()
        }
    }

    private func finishGesture(axis: GestureAxis, displacement: Double, velocity: Double,
                               recognizerAction: NavigationAction?) {
        let resolvedAction: NavigationAction?
        if axis == .horizontal, let gestureBase, let availableFrame {
            resolvedAction = RibbonMotion.horizontalCompletionAction(
                state: state,
                from: gestureBase,
                availableFrame: availableFrame,
                gap: gap,
                displacement: displacement,
                velocity: velocity,
                configuration: ribbonAnimationConfiguration
            )
        } else {
            resolvedAction = recognizerAction
        }
        if diagnostics.isEnabled {
            diagnostics.record("gesture_motion_resolved", details: [
                "displacement": String(displacement),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                "resolvedAction": resolvedAction.map { String(describing: $0) } ?? "none",
                "velocity": String(velocity)
            ])
        }
        gestureAxis = nil
        let initialHorizontalVelocity = axis == .horizontal && velocity.isFinite
            ? availableFrame.map {
                CGFloat(velocity * Double($0.width) * ribbonAnimationConfiguration.tracking)
            }
            : nil
        if let resolvedAction {
            var destination = state
            guard destination.apply(resolvedAction) else {
                restoreGesturePreview(initialHorizontalVelocity: initialHorizontalVelocity)
                return
            }
            gestureBase = nil
            gesturePrepared.removeAll()
            navigate(resolvedAction, initialHorizontalVelocity: initialHorizontalVelocity)
        } else {
            restoreGesturePreview(initialHorizontalVelocity: initialHorizontalVelocity)
        }
    }

    private func previewGesture(displacement: Double) {
        guard let base = gestureBase, let availableFrame, gestureAxis == .horizontal,
              worker == nil, displacement.isFinite else { return }
        ribbonMotion.follow(frames: { [weak self] in
            guard let self, self.gestureBase != nil, self.desktopScope.relation == .home else { return [:] }
            return self.gesturePreviewFrames(
                from: base,
                availableFrame: availableFrame,
                displacement: displacement
            )
        }, update: { [weak self] in self?.applyMotionFrames($0) })
    }

    private func gesturePreviewFrames(from base: [String: CGRect], availableFrame: CGRect,
                                      displacement: Double) -> [String: CGRect] {
        let preview = RibbonMotion.dragFrames(state: state, from: base, availableFrame: availableFrame,
                                              gap: gap, displacement: displacement,
                                              configuration: ribbonAnimationConfiguration)
        var frames: [String: CGRect] = [:]
        for (id, shifted) in preview {
            guard shifted.intersects(availableFrame) || gesturePrepared.contains(id) else { continue }
            if !gesturePrepared.contains(id) {
                let beforeFrame = diagnostics.isEnabled ? windowSystem.observedFrame(windowID: id) : nil
                let parkedBefore = diagnostics.isEnabled ? windowSystem.isParked(windowID: id) : false
                let observedFocusBefore = diagnostics.isEnabled ? windowSystem.focusedWindowID() : nil
                let frameWritten = windowSystem.setFrame(windowID: id, frame: shifted)
                if diagnostics.isEnabled {
                    let observedFocusAfter = windowSystem.focusedWindowID()
                    recordWindowGeometry(
                        event: "gesture_window_frame_applied",
                        windowID: id,
                        requestedFrame: shifted,
                        beforeFrame: beforeFrame,
                        actualFrame: windowSystem.observedFrame(windowID: id),
                        details: [
                            "displacement": String(displacement),
                            "frameWriteAccepted": String(frameWritten),
                            "isLogicalFocused": String(state.focusedWindowID == id),
                            "membershipCount": String(state.spaces.count { $0.windowIDs.contains(id) }),
                            "observedFocusedWindowIDAfter": observedFocusAfter ?? "none",
                            "observedFocusedWindowIDBefore": observedFocusBefore ?? "none",
                            "parkedAfter": String(windowSystem.isParked(windowID: id)),
                            "parkedBefore": String(parkedBefore),
                            "systemFocusedAfter": String(observedFocusAfter == id),
                            "systemFocusedBefore": String(observedFocusBefore == id)
                        ]
                    )
                }
                guard frameWritten else { continue }
                gesturePrepared.insert(id)
                let acceptedPosition = windowSystem.observedFrame(windowID: id)?.origin ?? shifted.origin
                motionWrittenPositions[id] = RibbonMotion.pixelAligned(
                    acceptedPosition,
                    backingScaleFactor: motionBackingScaleFactor
                )
            }
            frames[id] = shifted
        }
        presentationFrames = frames
        return frames
    }

    private func restoreGesturePreview(initialHorizontalVelocity: CGFloat? = nil) {
        guard let base = gestureBase, let availableFrame else { return }
        let starts = presentationFrames ?? [:]
        let targets = base.filter { gesturePrepared.contains($0.key) }
        gestureBase = nil
        presentationFrames = nil
        gesturePrepared.removeAll()
        let visibleIDs = Set(base.filter { $0.value.intersects(availableFrame) }.keys)
        Task { [weak self] in
            guard let self else { return }
            let completed = await self.settleRibbon(
                from: starts,
                to: targets,
                visibleIDs: visibleIDs,
                operation: "gesture.preview.restore",
                initialHorizontalVelocity: initialHorizontalVelocity
            )
            guard completed else { return }
            if let focused = self.state.focusedWindowID,
               let frame = self.windowSystem.frame(windowID: focused) {
                self.updateFocusBorder(windowID: focused, frame: frame)
            }
            self.scheduleRefresh()
        }
    }

    private func preferenceFocusStillMatches(_ request: LayoutRequestPolicy) -> Bool {
        request == .navigation || (state.focusedWindowID != nil && windowSystem.focusedWindowID() == state.focusedWindowID)
    }

    func updateFocusBorder(
        windowID: String,
        frame: CGRect,
        refreshShape: Bool = true,
        reorderAboveTarget: Bool = false
    ) {
        overlays.setBorderColor(focusBorderColor)
        let changed = borderWindowID != windowID
        let windowNumber = windowSystem.windowNumber(for: windowID)
        let identityChanged = changed || borderWindowNumber != windowNumber
        let sizeChanged = borderRadiusFrameSize != frame.size
        if identityChanged || (refreshShape && (!borderCornerRadiusResolved || sizeChanged)) {
            borderWindowID = windowID
            borderWindowNumber = windowNumber
            borderRadiusFrameSize = frame.size
            if let radius = windowNumber.flatMap({ WindowCornerRadius.cornerRadius(windowNumber: $0) }) {
                borderCornerRadius = radius
                borderCornerRadiusResolved = true
            } else {
                if identityChanged { borderCornerRadius = nil }
                borderCornerRadiusResolved = false
            }
        }
        overlays.updateBorder(
            frame: frame,
            visible: true,
            relativeTo: windowNumber,
            cornerRadius: borderCornerRadius,
            focusChanged: changed,
            reorderAboveTarget: reorderAboveTarget || identityChanged
        )
    }

    private func hideFocusBorder() {
        resetFocusBorderCache()
        overlays.updateBorder(frame: .zero, visible: false)
    }

    private func resetFocusBorderCache() {
        borderWindowID = nil
        borderWindowNumber = nil
        borderCornerRadius = nil
        borderCornerRadiusResolved = false
        borderRadiusFrameSize = nil
    }

    private func nativeDesktopChanged() {
        guard isRunning else { return }
        desktopCheckTask?.cancel()
        switch desktopScope.refresh() {
        case .home:
            guard isSuspended else { return }
            isSuspended = false
            diagnostics.record("desktop_resumed", details: workspaceDetails())
            input.gesturesEnabled = gesturesEnabled
            focusGate.start()
            input.start()
            // Reconcile only after returning to the bound Desktop; away windows never enter state.
            refreshWindows()
            if worker == nil { enqueue(.refresh) }
            onStateChange?()
        case .away, .unknown:
            if !isSuspended {
                diagnostics.record("desktop_suspended", details: [
                    "relation": String(describing: desktopScope.relation)
                ])
                isSuspended = true
                workerGeneration += 1
                worker?.cancel()
                worker = nil
                pending.removeAll()
                refreshTask?.cancel()
                if let transitionRollback { state = transitionRollback }
                transitionRollback = nil
                pointerInteraction = nil
                ribbonMotion.cancel()
                gestureBase = nil
                presentationFrames = nil
                gestureAxis = nil
                gesturePrepared.removeAll()
                observedFocusTask?.cancel()
                focusGate.cancelAll()
                focusGate.stop()
                input.stop()
                resetFocusBorderCache()
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

    private func screenParametersChanged() {
        guard isRunning, !isSuspended else { return }
        diagnostics.record("screen_parameters_changed")
        ribbonMotion.cancel()
        resetFocusBorderCache()
        enqueue(.preferences)
    }
}
