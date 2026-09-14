import AppKit
import Combine
import StagehandCore
import StagehandPlatform

func shouldSlideRibbon(from previousState: WorkspaceState, to state: WorkspaceState,
                       hadPreview: Bool, reduceMotion: Bool) -> Bool {
    guard !reduceMotion,
          previousState.activeSpaceIndex == state.activeSpaceIndex,
          previousState.focusedWindowID != state.focusedWindowID || hadPreview else { return false }
    return state.focusedWindowID != nil
}

func motionPresentationKeepsPace(
    previousPosition: CGPoint,
    requestedPosition: CGPoint,
    displayedFrame: CGRect
) -> Bool {
    guard abs(requestedPosition.y - displayedFrame.minY) <= 1 else { return false }
    let lowerX = min(previousPosition.x, requestedPosition.x) - 1
    let upperX = max(previousPosition.x, requestedPosition.x) + 1
    return displayedFrame.minX >= lowerX && displayedFrame.minX <= upperX
}

struct RibbonPositionWriteFailure: Equatable {
    let windowID: String
    let requestedFrame: CGRect
    let actualFrame: CGRect
}

enum WindowParkingOutcome: Equatable {
    case parked
    case deferred
    case failed
}

@MainActor
func writeRibbonPositions(
    frames: [String: CGRect],
    writtenPositions: inout [String: CGPoint],
    backingScaleFactor: CGFloat,
    setPosition: (String, CGPoint) -> Bool,
    observedFrame: (String) -> CGRect?
) -> RibbonPositionWriteFailure? {
    for (windowID, frame) in frames {
        let position = RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: backingScaleFactor)
        if writtenPositions[windowID] == position { continue }
        guard setPosition(windowID, position) else {
            guard let actualFrame = observedFrame(windowID) else { continue }
            return RibbonPositionWriteFailure(
                windowID: windowID,
                requestedFrame: frame,
                actualFrame: actualFrame
            )
        }
        writtenPositions[windowID] = position
    }
    return nil
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
    @Published private(set) var inputIssues: [String] = []
    @Published private(set) var warning: String? {
        didSet {
            if let warning, !isSuspended { overlays.showWarning(warning) }
            onStateChange?()
        }
    }
    @Published var gesturesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gesturesEnabled, forKey: "gesturesEnabled")
            input.gesturesEnabled = gesturesEnabled && !isSuspended
            updateInputStatus()
        }
    }
    @Published var gestureFingerCount: Int {
        didSet {
            UserDefaults.standard.set(gestureFingerCount, forKey: "gestureFingerCount")
            input.gestureFingerCount = gestureFingerCount
            updateInputStatus()
        }
    }
    @Published var gap: Double {
        didSet {
            UserDefaults.standard.set(gap, forKey: "windowGap")
            if isRunning && !isSuspended { enqueue(.preferences) }
        }
    }
    @Published private(set) var focusBorderColor: NSColor
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
    private let input = InputController()
    private let focusGate = FocusInputGate()
    private let overlays: NavigationOverlays
    private let diagnostics: DiagnosticLogger
    private let ribbonMotion = RibbonMotion()
    private var presentationFrames: [String: CGRect]?
    private var gestureBase: [String: CGRect]?
    private var gesturePrepared: Set<String> = []
    private var gestureAxis: GestureAxis?
    private var motionWrittenPositions: [String: CGPoint] = [:]
    private var motionPreviousPositions: [String: CGPoint] = [:]
    private var motionPresentationMisses: [String: Int] = [:]
    private var motionLaggingWindowIDs = Set<String>()
    private var motionBackingScaleFactor: CGFloat = 1
    private let emptySpace = EmptySpaceWindow()
    private var refreshTask: Task<Void, Never>?
    private var observedFocusTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: [(Change, UInt64?)] = []
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var preferredHeights: [String: CGFloat] = [:]
    private var lastTransition = Date.distantPast
    private var workerGeneration = 0
    private var desktopCheckTask: Task<Void, Never>?
    private var transitionRollback: WorkspaceState?
    private var workspaceRestoration = WorkspaceRestoration()
    private var lastLayoutMilliseconds = 0
    private var lastFocusTokenExpired = false
    private var pointerInteraction: PointerInteraction?
    private var borderWindowID: String?
    private var borderCornerRadius: CGFloat?
    private var isLayingOutWindows = false
    private var preferencesNeedLayout = false
    private var layoutFailureReason: String?
    private static let focusBorderColorPreferenceKey = "focusBorderColor"

    private struct PointerInteraction {
        let windowID: String
        let placements: [WindowPlacement]
        var needsLayout: Bool
    }

    private enum Change: Equatable {
        case action(NavigationAction)
        case maximize(Bool)
        case remove(String)
        case share(windowID: String, spaceIndex: Int)
        case focus(String)
        case moveMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int)
        case shareMembership(windowID: String, fromSpaceIndex: Int, toSpaceIndex: Int)
        case removeMembership(windowID: String, fromSpaceIndex: Int)
        case reorderWindow(windowID: String, toIndex: Int, spaceIndex: Int)
        case focusInSpace(windowID: String, spaceIndex: Int)
        case observedFocus(String)
        case refresh
        case preferences

        var policy: LayoutRequestPolicy {
            switch self {
            case .maximize, .preferences, .observedFocus, .moveMembership,
                 .shareMembership, .removeMembership, .reorderWindow: .preferences
            default: .navigation
            }
        }

        var isWindowNavigation: Bool {
            self == .action(.focusNext) || self == .action(.focusPrevious)
        }

        var diagnosticName: String {
            switch self {
            case .action(let action): "action.\(action)"
            case .maximize: "maximize"
            case .remove: "removeMembership"
            case .share: "shareMembership"
            case .focus: "focusWindow"
            case .moveMembership: "moveMembershipFromSettings"
            case .shareMembership: "shareMembershipFromSettings"
            case .removeMembership: "removeMembershipFromSettings"
            case .reorderWindow: "reorderWindow"
            case .focusInSpace: "focusWindowFromSettings"
            case .observedFocus: "observedFocus"
            case .refresh: "refresh"
            case .preferences: "preferences"
            }
        }
    }

    init(overlays: NavigationOverlays = NavigationOverlays(), diagnostics: DiagnosticLogger? = nil) {
        self.overlays = overlays
        let defaults = UserDefaults.standard
        diagnosticLoggingEnabled = defaults.bool(forKey: DiagnosticLogger.preferenceKey)
        self.diagnostics = diagnostics ?? DiagnosticLogger(
            enabled: defaults.bool(forKey: DiagnosticLogger.preferenceKey)
        )
        gesturesEnabled = defaults.object(forKey: "gesturesEnabled") as? Bool ?? false
        gestureFingerCount = defaults.integer(forKey: "gestureFingerCount") == 3 ? 3 : 4
        gap = GapInput.clamped(defaults.object(forKey: "windowGap") as? Double ?? 8)
        focusBorderColor = Self.savedFocusBorderColor(in: defaults) ?? BorderView.defaultColor
        state.maximizeWindows = defaults.object(forKey: "maximizeWindows") as? Bool
            ?? (defaults.string(forKey: "layoutMode") == "monocle")
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
        input.gestureFingerCount = gestureFingerCount
        overlays.setBorderColor(focusBorderColor)
        input.onStatusChange = { [weak self] in self?.updateInputStatus() }
        windowSystem.onChange = { [weak self] in self?.scheduleRefresh() }
        windowSystem.onFocusedWindowChange = { [weak self] id in self?.observedFocusChanged(windowID: id) }
        windowSystem.onFrameChange = { [weak self] id, frame in
            guard let self, self.isRunning, !self.isSuspended,
                  !self.isLayingOutWindows, !self.ribbonMotion.isRunning, self.gestureBase == nil,
                  self.borderWindowID == id, self.state.focusedWindowID == id else { return }
            guard self.desktopScope.refresh() == .home else {
                self.nativeDesktopChanged()
                return
            }
            // Geometry follows native notifications immediately. Do not scan windows,
            // query corner metadata, or wait for layout reconciliation during a resize.
            self.updateFocusBorder(windowID: id, frame: frame)
        }
        windowSystem.onNativeDesktopChange = { [weak self] in
            self?.nativeDesktopChanged()
        }
        windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
        focusGate.onNavigationAction = { [weak self] action in self?.navigate(action) }
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
        updateInputStatus()
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
        windowSystem.start()
        windows = windowSystem.scanWindows()
        preferredHeights = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame.height) })
        workspaceRestoration.reconcile(state: &state, windowIDs: windows.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs)
        if let focused = windowSystem.focusedWindowID() { state.focus(windowID: focused) }
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
        borderWindowID = nil
        borderCornerRadius = nil
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
        details: [String: String] = [:]
    ) {
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
            details: details
        )
    }

    func navigate(_ action: NavigationAction) {
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
            enqueue(.action(action))
        }
    }

    func setMaximizeWindows(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "maximizeWindows")
        if enabled { hideFocusBorder() }
        if isRunning && !isSuspended { enqueue(.maximize(enabled)) }
        else { state.maximizeWindows = enabled }
    }

    func setFocusBorderColor(_ color: NSColor) {
        guard let color = color.usingColorSpace(.sRGB) else { return }
        let normalized = NSColor(srgbRed: color.redComponent, green: color.greenComponent,
                                 blue: color.blueComponent, alpha: BorderView.defaultColor.alphaComponent)
        focusBorderColor = normalized
        UserDefaults.standard.set(
            [normalized.redComponent, normalized.greenComponent, normalized.blueComponent],
            forKey: Self.focusBorderColorPreferenceKey
        )
        overlays.setBorderColor(normalized)
    }

    private static func savedFocusBorderColor(in defaults: UserDefaults) -> NSColor? {
        guard let values = defaults.array(forKey: focusBorderColorPreferenceKey), values.count == 3 else {
            return nil
        }
        let components = values.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard components.count == 3, components.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2],
                       alpha: BorderView.defaultColor.alphaComponent)
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
        let settings = includeSettings ? SettingsWindow.make(model: self) : nil
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
        if gesturesEnabled { issues.append(contentsOf: InputController.nativeGestureConflicts(fingerCount: gestureFingerCount)) }
        var seen = Set<String>()
        inputIssues = issues.filter { seen.insert($0).inserted }
    }

    private func scheduleRefresh() {
        guard isRunning, !isSuspended, !ribbonMotion.isRunning, gestureBase == nil, !isLayingOutWindows else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended else { return }
            if self.worker != nil || self.ribbonMotion.isRunning || self.gestureBase != nil { return }
            self.refreshWindows()
        }
    }

    private func observedFocusChanged(windowID: String) {
        guard isRunning, !isSuspended, worker == nil, gestureBase == nil, windowID != state.focusedWindowID,
              windows.contains(where: { $0.id == windowID }), desktopScope.refresh() == .home else { return }
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
        let current = windowSystem.scanWindows()
        let oldState = state
        let oldIDs = Set(windows.map(\.id))
        windows = current
        motionLaggingWindowIDs.formIntersection(current.map(\.id))
        workspaceRestoration.reconcile(state: &state, windowIDs: current.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs)
        let hasNewWindows = current.contains { !oldIDs.contains($0.id) }
        if !hasNewWindows, oldState.activeSpaceIndex == state.activeSpaceIndex,
           let focused = windowSystem.focusedWindowID(),
           current.contains(where: { $0.id == focused }) {
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
                updateFocusBorder(windowID: focused.id, frame: focused.frame)
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
                if resized && !state.maximizeWindows {
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
            enqueue(preferencesNeedLayout ? .preferences : .refresh)
        } else if preferencesNeedLayout,
                  LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: windowSystem.focusedWindowID()) != nil {
            enqueue(.preferences)
        } else if let id = state.focusedWindowID, let frame = windowSystem.frame(windowID: id) {
            updateFocusBorder(windowID: id, frame: frame)
        }
        onStateChange?()
    }

    private func enqueue(_ change: Change) {
        if ProcessInfo.processInfo.arguments.contains("--trace-gestures"), gestureAxis != nil {
            NSLog("[DEBUG-gesture] layout requested during drag: %@", String(describing: change))
        }
        guard isRunning, !isSuspended else { return }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        if change == .preferences, pending.contains(where: { $0.0 == .preferences }) { return }
        // Capture typing before the asynchronous AX activation starts.
        let token = change.policy.beginInputTransfer {
            focusGate.isAvailable ? focusGate.beginTransfer() : nil
        }
        pending.append((change, token))
        diagnostics.record("change_queued", details: [
            "operation": change.diagnosticName,
            "pendingChanges": String(pending.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            var batchMotionStart: [String: CGRect]?
            while self.isRunning && !self.isSuspended && !Task.isCancelled && !self.pending.isEmpty {
                let (change, token) = self.pending.removeFirst()
                self.diagnostics.record("change_started", details: [
                    "operation": change.diagnosticName,
                    "pendingChanges": String(self.pending.count),
                    "transferToken": token.map(String.init) ?? "none"
                ])
                let previousState = self.transitionRollback ?? self.state
                self.transitionRollback = previousState
                let hadPreview = self.presentationFrames != nil
                let motionStart = batchMotionStart ?? self.navigationFrames()
                self.ribbonMotion.cancel()
                self.presentationFrames = nil
                if self.gestureAxis != nil { self.input.cancelGestureSequence() }
                self.gestureBase = nil
                self.gestureAxis = nil
                self.gesturePrepared.removeAll()
                switch change {
                case .action(let action): self.state.apply(action)
                case .maximize(let enabled):
                    if enabled && !self.state.maximizeWindows {
                        // A resize may finish before the debounced refresh observes it.
                        // Capture live heights before this transition replaces them.
                        for window in self.windows {
                            if let height = self.windowSystem.frame(windowID: window.id)?.height,
                               height.isFinite, height > 0 {
                                self.preferredHeights[window.id] = height
                            }
                        }
                    }
                    self.state.maximizeWindows = enabled
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
                case .refresh, .preferences, .observedFocus: break
                }
                if change.isWindowNavigation, self.pending.first?.0.isWindowNavigation == true,
                   let token, self.focusGate.cancelTransferIfEmpty(token: token) {
                    // Keep every navigation step in state, but avoid flashing intermediate
                    // windows when no typing belongs to them. Never merge input tokens.
                    batchMotionStart = motionStart
                    continue
                }
                batchMotionStart = nil
                if change.policy == .preferences {
                    self.preferencesNeedLayout = true
                    guard let prepared = change.policy.prepare(
                        state: self.state, focusedWindowID: self.windowSystem.focusedWindowID()
                    ) else {
                        self.transitionRollback = nil
                        continue
                    }
                    self.state = prepared
                }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let canSlide = shouldSlideRibbon(
                    from: previousState,
                    to: self.state,
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
                                                       slideFrom: canSlide ? motionStart : nil)
                guard generation == self.workerGeneration, !Task.isCancelled else { return }
                if !succeeded {
                    self.state = previousState
                    self.stop(
                        reason: self.layoutFailureReason ?? "layout_stopped_unexpectedly",
                        automatic: true,
                        details: ["operation": change.diagnosticName]
                    )
                    return
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

    private func applyLayout(token: UInt64?, request: LayoutRequestPolicy, operation: String,
                             slideFrom: [String: CGRect]? = nil) async -> Bool {
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
        // Capture a new window's preferred height before any maximized size writes.
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
        var destinationFocusedBeforeFrame = false
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
            // Once WindowServer shows that an app animates AX moves while inactive,
            // focus its destination before moving it and do not drive more animation frames.
            if pass == 0, request == .navigation, let focusedID = state.focusedWindowID,
               motionLaggingWindowIDs.contains(focusedID) {
                let observedFocus = windowSystem.focusedWindowID()
                if focusedID != observedFocus {
                    destinationFocusedBeforeFrame = await windowSystem.focus(windowID: focusedID)
                    if diagnostics.isEnabled {
                        var details = [
                            "focusConfirmed": String(destinationFocusedBeforeFrame),
                            "observedFocusedWindowIDAfter": windowSystem.focusedWindowID() ?? "none",
                            "observedFocusedWindowIDBefore": observedFocus ?? "none",
                            "operation": operation,
                            "windowID": focusedID
                        ]
                        if let report = windowSystem.lastFocusReport { details["focusReport"] = report.summary }
                        diagnostics.record("navigation_focus_before_frame", details: details)
                    }
                    guard desktopScope.refresh() == .home else {
                        nativeDesktopChanged()
                        return false
                    }
                    guard isRunning, !isSuspended, !Task.isCancelled else {
                        if let token { focusGate.cancelTransfer(token: token) }
                        return false
                    }
                }
            }
            // Position neighbors first. Raising the focused real window last keeps clamped neighbors behind it.
            for placement in visible.sorted(by: { !$0.isFocused && $1.isFocused }) {
                guard preferenceFocusStillMatches(request) else { return true }
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return false
                }
                if request == .navigation, motionLaggingWindowIDs.contains(placement.windowID) {
                    continue
                }
                // A correction pass only writes windows whose geometry actually changed.
                var preparedFrame = placement.frame
                if let start = slideFrom?[placement.windowID] { preparedFrame.origin.x = start.minX }
                if pass > 0, acceptedFrames[placement.windowID] == preparedFrame { continue }
                let recordsNavigationMotion = request == .navigation && diagnostics.isEnabled
                let beforeFrame = recordsNavigationMotion
                    ? windowSystem.observedFrame(windowID: placement.windowID) : nil
                let parkedBefore = recordsNavigationMotion
                    ? windowSystem.isParked(windowID: placement.windowID) : false
                let observedFocusBefore = recordsNavigationMotion ? windowSystem.focusedWindowID() : nil
                let frameWritten = windowSystem.setFrame(windowID: placement.windowID, frame: preparedFrame)
                let actualFrame = windowSystem.frame(windowID: placement.windowID)
                if recordsNavigationMotion {
                    let observedFocusAfter = windowSystem.focusedWindowID()
                    let membershipCount = state.spaces.count { $0.windowIDs.contains(placement.windowID) }
                    recordWindowGeometry(
                        event: "navigation_window_frame_applied",
                        windowID: placement.windowID,
                        requestedFrame: preparedFrame,
                        beforeFrame: beforeFrame,
                        actualFrame: windowSystem.observedFrame(windowID: placement.windowID),
                        details: [
                            "frameWriteAccepted": String(frameWritten),
                            "isDestinationFocused": String(placement.isFocused),
                            "membershipCount": String(membershipCount),
                            "observedFocusedWindowIDAfter": observedFocusAfter ?? "none",
                            "observedFocusedWindowIDBefore": observedFocusBefore ?? "none",
                            "operation": operation,
                            "parkedAfter": String(windowSystem.isParked(windowID: placement.windowID)),
                            "parkedBefore": String(parkedBefore),
                            "pass": String(pass + 1),
                            "slidePrepared": String(slideFrom?[placement.windowID] != nil),
                            "systemFocusedAfter": String(observedFocusAfter == placement.windowID),
                            "systemFocusedBefore": String(observedFocusBefore == placement.windowID),
                            "targetHeight": String(Double(placement.frame.height)),
                            "targetWidth": String(Double(placement.frame.width)),
                            "targetX": String(Double(placement.frame.minX)),
                            "targetY": String(Double(placement.frame.minY))
                        ]
                    )
                }
                if !frameWritten, placement.isFocused {
                    recordWindowGeometry(
                        event: "frame_write_constrained",
                        windowID: placement.windowID,
                        requestedFrame: preparedFrame,
                        actualFrame: actualFrame,
                        details: ["pass": String(pass + 1)]
                    )
                    warning = "This app controls its window size. Stagehand will use the size it allows."
                }
                lastAppliedFrames[placement.windowID] = actualFrame
            }
            if let focusedID = state.focusedWindowID,
               let record = windows.first(where: { $0.id == focusedID }) {
                let preparation = layoutStart.duration(to: .now).components
                lastLayoutMilliseconds = Int(preparation.seconds * 1_000 + preparation.attoseconds / 1_000_000_000_000_000)
                if request == .navigation { emptySpace.hide() }
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return false
                }
                let observedFocusBefore = diagnostics.isEnabled ? windowSystem.focusedWindowID() : nil
                let focused: Bool
                if destinationFocusedBeforeFrame, windowSystem.focusedWindowID() == focusedID {
                    focused = true
                } else {
                    focused = await request.confirmFocus(
                        windowID: focusedID,
                        currentFocus: { windowSystem.focusedWindowID() },
                        activate: { await windowSystem.focus(windowID: focusedID) }
                    )
                }
                if request == .navigation, diagnostics.isEnabled {
                    let observedFocusAfter = windowSystem.focusedWindowID()
                    var details = [
                        "focusConfirmed": String(focused),
                        "membershipCount": String(state.spaces.count { $0.windowIDs.contains(focusedID) }),
                        "observedFocusedWindowIDAfter": observedFocusAfter ?? "none",
                        "observedFocusedWindowIDBefore": observedFocusBefore ?? "none",
                        "operation": operation,
                        "parkedAfter": String(windowSystem.isParked(windowID: focusedID)),
                        "systemFocusedAfter": String(observedFocusAfter == focusedID),
                        "systemFocusedBefore": String(observedFocusBefore == focusedID),
                        "windowID": focusedID
                    ]
                    if observedFocusBefore != focusedID, let report = windowSystem.lastFocusReport {
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
                if !focused || token.map({ expiredTokens.contains($0) }) == true {
                    if let token { focusGate.cancelTransfer(token: token) }
                    warning = "Stagehand couldn't focus \(record.appName). It paused and restored your windows. Check for an open dialog or changed permissions."
                    var details = [
                        "bundleIdentifier": record.bundleIdentifier,
                        "focusConfirmed": String(focused),
                        "pid": String(record.pid),
                        "transferExpired": String(token.map { expiredTokens.contains($0) } ?? false),
                        "windowID": record.id
                    ]
                    if let report = windowSystem.lastFocusReport {
                        details["focusReport"] = report.summary
                    }
                    return failLayout("focus_confirmation_failed", details: details)
                }
                if request == .navigation {
                    for placement in visible where placement.isVisible &&
                        motionLaggingWindowIDs.contains(placement.windowID) {
                        if pass > 0, acceptedFrames[placement.windowID] == placement.frame { continue }
                        let beforeFrame = diagnostics.isEnabled
                            ? windowSystem.observedFrame(windowID: placement.windowID) : nil
                        let frameWritten = windowSystem.setFrame(windowID: placement.windowID, frame: placement.frame)
                        let actualFrame = windowSystem.frame(windowID: placement.windowID)
                        if diagnostics.isEnabled {
                            recordWindowGeometry(
                                event: "window_motion_deferred",
                                windowID: placement.windowID,
                                requestedFrame: placement.frame,
                                beforeFrame: beforeFrame,
                                actualFrame: windowSystem.observedFrame(windowID: placement.windowID),
                                details: [
                                    "frameWriteAccepted": String(frameWritten),
                                    "operation": operation
                                ]
                            )
                        }
                        if !frameWritten, placement.isFocused {
                            warning = "This app controls its window size. Stagehand will use the size it allows."
                        }
                        lastAppliedFrames[placement.windowID] = actualFrame
                    }
                }
                var constrained = false
                for placement in visible {
                    guard let actual = windowSystem.frame(windowID: placement.windowID) else { continue }
                    acceptedFrames[placement.windowID] = actual
                    var constrainedAxes: [String] = []
                    if actual.width.isFinite, actual.width > 0,
                       abs(actual.width - placement.frame.width) > 1 {
                        observedWidths[placement.windowID] = actual.width
                        if !state.maximizeWindows {
                            state.setWidthFraction(actual.width / availableFrame.width, for: placement.windowID)
                        }
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
                destinationPID = record.pid
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
        if let token, let destinationPID {
            focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
            // Posting to a process is asynchronous, not an OS delivery acknowledgement.
            try? await Task.sleep(for: .milliseconds(12))
            guard isRunning, !isSuspended, !Task.isCancelled else { return false }
        }
        let visibleIDs = Set(placements.filter(\.isVisible).map(\.windowID))
        let motionCandidates = placements.filter {
            $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true
        }
        let sliding = motionCandidates.filter { !motionLaggingWindowIDs.contains($0.windowID) }
        let animatedWindowIDs = slideFrom == nil ? Set<String>() : Set(sliding.map(\.windowID))
        for window in windows where !visibleIDs.contains(window.id) && !animatedWindowIDs.contains(window.id) {
            guard preferenceFocusStillMatches(request) else { return true }
            guard desktopScope.refresh() == .home else {
                nativeDesktopChanged()
                return false
            }
            if parkWindow(
                windowID: window.id,
                park: { windowSystem.park(windowID: $0) },
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
        lastTransition = Date()
        if slideFrom != nil {
            let starts = Dictionary(uniqueKeysWithValues: sliding.compactMap { placement in
                windowSystem.frame(windowID: placement.windowID).map { (placement.windowID, $0) }
            })
            let targets = Dictionary(uniqueKeysWithValues: sliding.map { ($0.windowID, $0.frame) })
            settleRibbon(from: starts, to: targets, visibleIDs: visibleIDs, operation: operation)
        }
        if let focused = state.focusedWindowID, let frame = windowSystem.frame(windowID: focused) {
            updateFocusBorder(windowID: focused, frame: frame)
        } else {
            borderWindowID = nil
            borderCornerRadius = nil
            overlays.updateBorder(frame: .zero, visible: false)
        }
        if request == .navigation { overlays.showNavigation(state: state, windows: windows) }
        else { overlays.updateNavigation(state: state, windows: windows) }
        onStateChange?()
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
        guard isRunning, !isSuspended, desktopScope.refresh() == .home else {
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
        let displayedFrames = windowSystem.displayedFrames(windowIDs: Set(frames.keys))
        var movingFrames: [String: CGRect] = [:]
        for (id, frame) in frames where !motionLaggingWindowIDs.contains(id) {
            if let previousPosition = motionPreviousPositions[id],
               let requestedPosition = motionWrittenPositions[id],
               let displayedFrame = displayedFrames[id] {
                if !motionPresentationKeepsPace(
                    previousPosition: previousPosition,
                    requestedPosition: requestedPosition,
                    displayedFrame: displayedFrame
                ) {
                    let misses = (motionPresentationMisses[id] ?? 0) + 1
                    motionPresentationMisses[id] = misses
                    if misses >= 2 {
                        motionLaggingWindowIDs.insert(id)
                        var requestedFrame = frame
                        requestedFrame.origin = requestedPosition
                        recordWindowGeometry(
                            event: "window_motion_lag_detected",
                            windowID: id,
                            requestedFrame: requestedFrame,
                            actualFrame: displayedFrame,
                            details: ["consecutiveMisses": String(misses)]
                        )
                    }
                    continue
                }
                motionPresentationMisses[id] = 0
            }
            movingFrames[id] = frame
        }
        let previousWrittenPositions = motionWrittenPositions
        if let failure = writeRibbonPositions(
            frames: movingFrames,
            writtenPositions: &motionWrittenPositions,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
            observedFrame: { windowSystem.observedFrame(windowID: $0) }
        ) {
            ribbonMotion.cancel()
            recordWindowGeometry(
                event: "ribbon_position_write_failed",
                windowID: failure.windowID,
                requestedFrame: failure.requestedFrame,
                actualFrame: failure.actualFrame
            )
            warning = "Stagehand couldn't move one of your windows. It paused and restored them."
            stop(
                reason: "ribbon_position_failed",
                automatic: true,
                details: ["windowID": failure.windowID]
            )
            return
        }
        for id in movingFrames.keys where previousWrittenPositions[id] != motionWrittenPositions[id] {
            motionPreviousPositions[id] = previousWrittenPositions[id]
            guard let acceptedPosition = windowSystem.observedFrame(windowID: id)?.origin else { continue }
            motionWrittenPositions[id] = RibbonMotion.pixelAligned(
                acceptedPosition,
                backingScaleFactor: motionBackingScaleFactor
            )
        }
        if gestureBase == nil, let focused = state.focusedWindowID, var frame = frames[focused] {
            frame.origin = motionWrittenPositions[focused]
                ?? RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: motionBackingScaleFactor)
            updateFocusBorder(windowID: focused, frame: frame)
        }
    }

    private func settleRibbon(from: [String: CGRect], to: [String: CGRect], visibleIDs: Set<String>,
                              operation: String) {
        motionBackingScaleFactor = builtInScreen?.backingScaleFactor ?? 1
        motionPreviousPositions.removeAll()
        motionPresentationMisses.removeAll()
        motionWrittenPositions = from.mapValues {
            RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
        }
        if diagnostics.isEnabled {
            diagnostics.record("ribbon_animation_started", details: [
                "focusedWindowID": state.focusedWindowID ?? "none",
                "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ])
            recordRibbonGeometry(event: "ribbon_animation_window_started", from: from, to: to,
                                 operation: operation)
        }
        ribbonMotion.animate(from: from, to: to,
                             duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2,
                             update: { [weak self] in self?.applyMotionFrames($0) }, completion: { [weak self] in
            guard let self, self.isRunning, !self.isSuspended, self.desktopScope.refresh() == .home else { return }
            for (id, frame) in to where visibleIDs.contains(id) && self.motionLaggingWindowIDs.contains(id) {
                let beforeFrame = self.diagnostics.isEnabled ? self.windowSystem.observedFrame(windowID: id) : nil
                let frameWritten = self.windowSystem.setFrame(windowID: id, frame: frame)
                if self.diagnostics.isEnabled {
                    self.recordWindowGeometry(
                        event: "window_motion_deferred",
                        windowID: id,
                        requestedFrame: frame,
                        beforeFrame: beforeFrame,
                        actualFrame: self.windowSystem.observedFrame(windowID: id),
                        details: [
                            "frameWriteAccepted": String(frameWritten),
                            "operation": operation
                        ]
                    )
                }
            }
            if self.diagnostics.isEnabled {
                self.diagnostics.record("ribbon_animation_completed", details: [
                    "focusedWindowID": self.state.focusedWindowID ?? "none",
                    "observedFocusedWindowID": self.windowSystem.focusedWindowID() ?? "none",
                    "operation": operation,
                    "windowCount": String(to.count)
                ])
                self.recordRibbonGeometry(event: "ribbon_animation_window_completed", from: from, to: to,
                                          operation: operation)
            }
            for window in self.windows where !visibleIDs.contains(window.id) {
                if parkWindow(
                    windowID: window.id,
                    park: { self.windowSystem.park(windowID: $0) },
                    observedFrame: { self.windowSystem.observedFrame(windowID: $0) }
                ) == .failed {
                    self.warning = "Stagehand couldn't move \(window.appName) out of this space. It paused and restored your windows."
                    self.stop(
                        reason: "ribbon_parking_failed",
                        automatic: true,
                        details: [
                            "bundleIdentifier": window.bundleIdentifier,
                            "pid": String(window.pid),
                            "windowID": window.id
                        ]
                    )
                    return
                }
            }
            for id in visibleIDs { self.lastAppliedFrames[id] = self.windowSystem.frame(windowID: id) }
            if let focused = self.state.focusedWindowID, let actual = self.lastAppliedFrames[focused] {
                self.updateFocusBorder(windowID: focused, frame: actual)
            }
            self.lastTransition = Date()
            self.scheduleRefresh()
        })
    }

    private func recordRibbonGeometry(event: String, from: [String: CGRect], to: [String: CGRect],
                                      operation: String) {
        let observedFocus = windowSystem.focusedWindowID()
        for (windowID, target) in to.sorted(by: { $0.key < $1.key }) {
            recordWindowGeometry(
                event: event,
                windowID: windowID,
                requestedFrame: target,
                beforeFrame: from[windowID],
                actualFrame: windowSystem.observedFrame(windowID: windowID),
                details: [
                    "isDestinationFocused": String(state.focusedWindowID == windowID),
                    "membershipCount": String(state.spaces.count { $0.windowIDs.contains(windowID) }),
                    "observedFocusedWindowID": observedFocus ?? "none",
                    "operation": operation,
                    "parked": String(windowSystem.isParked(windowID: windowID)),
                    "systemFocused": String(observedFocus == windowID)
                ]
            )
        }
    }

    private func handleGesture(_ event: GestureNavigationEvent) {
        if ProcessInfo.processInfo.arguments.contains("--trace-gestures") {
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
                motionPreviousPositions.removeAll()
                motionPresentationMisses.removeAll()
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
                velocity: velocity
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
        if let resolvedAction {
            var destination = state
            guard destination.apply(resolvedAction) else {
                restoreGesturePreview()
                return
            }
            gestureBase = nil
            gesturePrepared.removeAll()
            navigate(resolvedAction)
        } else {
            restoreGesturePreview()
        }
    }

    private func previewGesture(displacement: Double) {
        guard let base = gestureBase, let availableFrame, gestureAxis == .horizontal,
              worker == nil, displacement.isFinite else { return }
        ribbonMotion.follow(frames: { [weak self] in
            guard let self, self.gestureBase != nil, self.desktopScope.refresh() == .home else { return [:] }
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
                                              gap: gap, displacement: displacement)
        var frames: [String: CGRect] = [:]
        for (id, shifted) in preview {
            guard shifted.intersects(availableFrame) || gesturePrepared.contains(id) else { continue }
            if motionLaggingWindowIDs.contains(id) { continue }
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

    private func restoreGesturePreview() {
        guard let base = gestureBase, let availableFrame else { return }
        let starts = presentationFrames ?? [:]
        let targets = base.filter { gesturePrepared.contains($0.key) }
        gestureBase = nil
        presentationFrames = nil
        gesturePrepared.removeAll()
        settleRibbon(from: starts, to: targets,
                     visibleIDs: Set(base.filter { $0.value.intersects(availableFrame) }.keys),
                     operation: "gesture.preview.restore")
    }

    private func preferenceFocusStillMatches(_ request: LayoutRequestPolicy) -> Bool {
        request == .navigation || (state.focusedWindowID != nil && windowSystem.focusedWindowID() == state.focusedWindowID)
    }

    func updateFocusBorder(windowID: String, frame: CGRect) {
        guard !state.maximizeWindows else {
            hideFocusBorder()
            return
        }
        let changed = borderWindowID != windowID
        if changed {
            borderWindowID = windowID
            borderCornerRadius = windows.first(where: { $0.id == windowID }).flatMap {
                WindowCornerRadius.cornerRadius(processID: $0.pid, frame: frame)
            }
        }
        overlays.updateBorder(frame: frame, visible: true, cornerRadius: borderCornerRadius, focusChanged: changed)
    }

    private func hideFocusBorder() {
        borderWindowID = nil
        borderCornerRadius = nil
        overlays.updateBorder(frame: .zero, visible: false)
    }

    private func nativeDesktopChanged(remainingChecks: Int = 5) {
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
                borderWindowID = nil
                borderCornerRadius = nil
                overlays.hide()
                emptySpace.hide()
                updateInputStatus()
                onStateChange?()
            }
            // Native transitions can briefly have no active Desktop ID. Retry only that transient
            // state; otherwise the native Desktop notification wakes us when the user returns.
            if desktopScope.relation == .unknown, remainingChecks > 0 {
                desktopCheckTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.nativeDesktopChanged(remainingChecks: remainingChecks - 1)
                }
            }
        }
    }
}
