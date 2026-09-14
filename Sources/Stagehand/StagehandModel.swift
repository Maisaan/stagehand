import AppKit
import Combine
import StagehandCore
import StagehandPlatform

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
        }
    }
    @Published var gap: Double {
        didSet {
            UserDefaults.standard.set(gap, forKey: "windowGap")
            if isRunning && !isSuspended { enqueue(.refresh) }
        }
    }

    var showSettings: (() -> Void)?
    var onStateChange: (() -> Void)?
    private let windowSystem = WindowSystem()
    private let desktopScope = DesktopScope()
    private let input = InputController()
    private let focusGate = FocusInputGate()
    private let overlays = NavigationOverlays()
    private let emptySpace = EmptySpaceWindow()
    private var refreshTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var pending: [(Change, UInt64?)] = []
    private var lastAppliedFrames: [String: CGRect] = [:]
    private var lastTransition = Date.distantPast
    private var workerGeneration = 0
    private var desktopCheckTask: Task<Void, Never>?
    private var transitionRollback: WorkspaceState?
    private var lastLayoutMilliseconds = 0
    private var lastFocusTokenExpired = false

    private enum Change {
        case action(NavigationAction)
        case layout(LayoutMode)
        case remove(String)
        case focus(String)
        case refresh
    }

    init() {
        let defaults = UserDefaults.standard
        gesturesEnabled = defaults.object(forKey: "gesturesEnabled") as? Bool ?? false
        gap = defaults.object(forKey: "windowGap") as? Double ?? 8
        if let raw = defaults.string(forKey: "layoutMode"), let mode = LayoutMode(rawValue: raw) {
            state.layoutMode = mode
        }
        input.onAction = { [weak self] action in self?.navigate(action) }
        input.onStatusChange = { [weak self] in self?.updateInputStatus() }
        windowSystem.onChange = { [weak self] in self?.scheduleRefresh() }
        windowSystem.onNativeDesktopChange = { [weak self] in
            self?.nativeDesktopChanged()
        }
        focusGate.onNavigationAction = { [weak self] action in self?.navigate(action) }
        focusGate.onAvailabilityChanged = { [weak self] in self?.updateInputStatus() }
        focusGate.onInputDiscarded = { [weak self] count in
            self?.warning = "Focus could not be confirmed. \(count) buffered keyboard events were withheld rather than sent to the wrong window. Please check your last input."
            NSSound.beep()
        }
        focusGate.onTransferExpired = { [weak self] token in
            guard let self else { return }
            self.expiredTokens.insert(token)
            let generation = self.workerGeneration
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.workerGeneration == generation else { return }
                self.pause()
                if self.warning == nil {
                    self.warning = "Window switching took too long. Stagehand paused and restored your windows."
                }
            }
        }
        refreshPermissions()
    }

    private var expiredTokens: Set<UInt64> = []

    var focusedWindow: WindowRecord? { windows.first { $0.id == state.focusedWindowID } }

    func refreshPermissions() {
        accessibilityGranted = windowSystem.isAccessibilityTrusted
        updateInputStatus()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refreshPermissions()
    }

    func requestAccessibility() {
        windowSystem.requestAccessibilityPermission()
        refreshPermissions()
    }

    func start() {
        refreshPermissions()
        guard accessibilityGranted else {
            warning = "Enable Accessibility for Stagehand, then press Start."
            return
        }
        guard !isRunning else { return }
        guard desktopScope.bindToCurrentDesktop() else {
            warning = "Could not identify this macOS Desktop. Stagehand has not changed any windows."
            return
        }
        warning = nil
        windowSystem.start()
        windows = windowSystem.scanWindows()
        state.reconcile(windowIDs: windows.map(\.id))
        if let focused = windowSystem.focusedWindowID() { state.focus(windowID: focused) }
        isRunning = true
        isSuspended = false
        state.isPaused = false
        input.gesturesEnabled = gesturesEnabled
        focusGate.start()
        input.start()
        updateInputStatus()
        enqueue(.refresh)
        onStateChange?()
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        isSuspended = false
        state.isPaused = true
        workerGeneration += 1
        worker?.cancel()
        worker = nil
        pending.removeAll()
        expiredTokens.removeAll()
        refreshTask?.cancel()
        desktopCheckTask?.cancel()
        desktopScope.reset()
        transitionRollback = nil
        focusGate.cancelAll()
        focusGate.stop()
        input.stop()
        overlays.hide()
        emptySpace.hide()
        windowSystem.stop()
        lastAppliedFrames.removeAll()
        if let warning { overlays.showWarning(warning) }
        onStateChange?()
    }

    func shutDown() { pause() }

    func navigate(_ action: NavigationAction) {
        switch action {
        case .showSettings: showSettings?()
        case .togglePause: isRunning ? pause() : start()
        default:
            guard isRunning, !isSuspended else { return }
            enqueue(.action(action))
        }
    }

    func setLayout(_ mode: LayoutMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "layoutMode")
        if isRunning && !isSuspended { enqueue(.layout(mode)) }
        else { state.layoutMode = mode }
    }

    func removeMembership(windowID: String) {
        guard isRunning, !isSuspended else { return }
        enqueue(.remove(windowID))
    }

    func focusWindow(_ id: String) {
        guard isRunning, !isSuspended else { return }
        enqueue(.focus(id))
    }

    func dismissWarning() { warning = nil }

    /// Runs the actual Start path, prints no window titles or input, then restores all frames.
    func diagnoseStartup() async -> String {
        windowSystem.focusDiagnosticsEnabled = true
        guard accessibilityGranted else {
            return "Accessibility permission is missing for this build. No windows were changed."
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let began = ContinuousClock.now
        start()
        let deadline = began.advanced(by: .seconds(4))
        while worker != nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let result = """
        Startup running: \(isRunning), suspended: \(isSuspended)
        Managed window count: \(windows.count)
        Layout preparation: \(lastLayoutMilliseconds) ms
        Focus token expired: \(lastFocusTokenExpired)
        Warning: \(warning ?? "none")
        \(windowSystem.lastFocusReport?.summary ?? "No focus report")
        """
        pause()
        _ = previousApp?.activate(options: [])
        return result
    }

    private func updateInputStatus() {
        var issues = input.issues
        if isRunning && !isSuspended && !focusGate.isAvailable {
            issues.append(focusGate.isSecureInputEnabled
                          ? "Secure Input is active. macOS prevents keyboard handoff protection in this mode."
                          : "Keyboard handoff protection is unavailable. Check Accessibility and Input Monitoring permissions.")
        }
        if gesturesEnabled { issues.append(contentsOf: InputController.nativeGestureConflicts()) }
        var seen = Set<String>()
        inputIssues = issues.filter { seen.insert($0).inserted }
    }

    private func scheduleRefresh() {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended else { return }
            if self.worker != nil { return }
            self.refreshWindows()
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
        state.reconcile(windowIDs: current.map(\.id))
        let hasNewWindows = current.contains { !oldIDs.contains($0.id) }
        if !hasNewWindows, let focused = windowSystem.focusedWindowID(),
           current.contains(where: { $0.id == focused }) {
            // External app activation follows an existing membership; shared windows stay in this space.
            if !state.currentSpace.windowIDs.contains(focused),
               let space = state.spaces.firstIndex(where: { $0.windowIDs.contains(focused) }) {
                state.apply(.goToSpace(index: space))
            }
            state.focus(windowID: focused)
        }
        if state.layoutMode == .scrolling,
           let focused = focusedWindow,
           let previous = lastAppliedFrames[focused.id],
           abs(focused.frame.width - previous.width) > 3,
           let frame = availableFrame {
            if Date().timeIntervalSince(lastTransition) > 0.4 {
                state.setWidthFraction(focused.frame.width / frame.width, for: focused.id)
            } else {
                refreshTask?.cancel()
                refreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, self.worker == nil else { return }
                    self.refreshWindows()
                }
            }
        }
        if oldState != state { enqueue(.refresh) }
        else if let id = state.focusedWindowID, let frame = windowSystem.frame(windowID: id) {
            overlays.updateBorder(frame: frame, visible: state.layoutMode == .scrolling)
        }
        onStateChange?()
    }

    private func enqueue(_ change: Change) {
        guard isRunning, !isSuspended else { return }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        // Capture typing before the asynchronous AX activation starts.
        let token = focusGate.isAvailable ? focusGate.beginTransfer() : nil
        pending.append((change, token))
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            while self.isRunning && !self.isSuspended && !Task.isCancelled && !self.pending.isEmpty {
                let (change, token) = self.pending.removeFirst()
                let previousState = self.state
                self.transitionRollback = previousState
                switch change {
                case .action(let action): self.state.apply(action)
                case .layout(let mode): self.state.layoutMode = mode
                case .remove(let id): self.state.removeFromCurrentSpace(windowID: id)
                case .focus(let id): self.state.focus(windowID: id)
                case .refresh: break
                }
                let succeeded = await self.applyLayout(token: token)
                guard generation == self.workerGeneration, !Task.isCancelled else { return }
                if !succeeded {
                    self.state = previousState
                    self.pause()
                    return
                }
                self.transitionRollback = nil
            }
            guard generation == self.workerGeneration, !Task.isCancelled else { return }
            self.worker = nil
            self.onStateChange?()
            self.scheduleRefresh()
        }
    }

    private var availableFrame: CGRect? {
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
        guard let screen, let primary = NSScreen.screens.first else { return nil }
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private func applyLayout(token: UInt64?) async -> Bool {
        let layoutStart = ContinuousClock.now
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return false
        }
        guard let availableFrame else {
            if let token { focusGate.cancelTransfer(token: token) }
            return false
        }
        let placements = WindowLayout.placements(for: state, availableFrame: availableFrame, gap: gap)
        let visible = placements.filter(\.isVisible)
        // Position neighbors first. Raising the focused real window last keeps clamped neighbors behind it.
        for placement in visible.sorted(by: { !$0.isFocused && $1.isFocused }) {
            guard desktopScope.refresh() == .home else {
                nativeDesktopChanged()
                return false
            }
            if !windowSystem.setFrame(windowID: placement.windowID, frame: placement.frame), placement.isFocused {
                warning = "This app constrained its window size. Stagehand will use the size it allows."
            }
            lastAppliedFrames[placement.windowID] = windowSystem.frame(windowID: placement.windowID)
        }
        if let focusedID = state.focusedWindowID,
           let record = windows.first(where: { $0.id == focusedID }) {
            let preparation = layoutStart.duration(to: .now).components
            lastLayoutMilliseconds = Int(preparation.seconds * 1_000 + preparation.attoseconds / 1_000_000_000_000_000)
            emptySpace.hide()
            guard desktopScope.refresh() == .home else {
                nativeDesktopChanged()
                return false
            }
            let focused = await windowSystem.focus(windowID: focusedID)
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
                warning = "Could not confirm focus on \(record.appName). Stagehand paused and restored your windows. Check for a dialog or permission change."
                return false
            }
            if let token {
                focusGate.commitTransfer(token: token, processIdentifier: record.pid)
                // Posting to a process is asynchronous. Give the destination event loop a turn
                // before another queued switch, especially between windows in the same app.
                // This is not an OS delivery acknowledgement; live acceptance testing is required.
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return false }
            }
        } else {
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
                warning = "Could not activate the empty space. Stagehand paused and restored your windows."
                return false
            }
            if let token { focusGate.commitTransfer(token: token, processIdentifier: ProcessInfo.processInfo.processIdentifier) }
        }
        let visibleIDs = Set(visible.map(\.windowID))
        for window in windows where !visibleIDs.contains(window.id) {
            guard desktopScope.refresh() == .home else {
                nativeDesktopChanged()
                return false
            }
            guard windowSystem.park(windowID: window.id) else {
                warning = "\(window.appName) would not move out of this space. Stagehand paused and restored your windows."
                return false
            }
        }
        lastTransition = Date()
        if let focused = state.focusedWindowID, let frame = windowSystem.frame(windowID: focused) {
            overlays.updateBorder(frame: frame, visible: state.layoutMode == .scrolling)
        } else {
            overlays.updateBorder(frame: .zero, visible: false)
        }
        overlays.showNavigation(state: state, windows: windows)
        onStateChange?()
        return true
    }

    private func nativeDesktopChanged(remainingChecks: Int = 5) {
        guard isRunning else { return }
        desktopCheckTask?.cancel()
        switch desktopScope.refresh() {
        case .home:
            guard isSuspended else { return }
            isSuspended = false
            input.gesturesEnabled = gesturesEnabled
            focusGate.start()
            input.start()
            // Reconcile only after returning to the bound Desktop; away windows never enter state.
            refreshWindows()
            if worker == nil { enqueue(.refresh) }
            onStateChange?()
        case .away, .unknown:
            if !isSuspended {
                isSuspended = true
                workerGeneration += 1
                worker?.cancel()
                worker = nil
                pending.removeAll()
                refreshTask?.cancel()
                if let transitionRollback { state = transitionRollback }
                transitionRollback = nil
                focusGate.cancelAll()
                focusGate.stop()
                input.stop()
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
