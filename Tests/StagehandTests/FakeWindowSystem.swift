import AppKit
import StagehandCore
@testable import Stagehand
@testable import StagehandPlatform

/// In-memory windows that follow `WindowSystem`'s contracts: logical frames while
/// parked, refusals for minimized windows, and original frames restored on stop.
@MainActor
final class FakeWindowSystem: WindowManaging {
    struct Window {
        var record: WindowRecord
        var frame: CGRect
        var original: CGRect
        var restoreFrame: CGRect?
        var minimized = false
    }

    var onChange: (() -> Void)?
    var onWindowCreated: (() -> Void)?
    var onFrameChange: ((String, CGRect) -> Void)?
    var onSheetChange: ((String) -> Void)?
    var onFocusedWindowChange: ((String) -> Void)?
    var wantsObservedFocus: (() -> Bool)?
    var wantsFrameChange: (() -> Bool)?
    var wantsInventory: (() -> Bool)?
    var onTitleChange: ((String, String) -> Void)?
    var onApplicationTerminated: ((pid_t) -> Void)?
    var onWindowDestroyed: ((String) -> Void)?
    var onWindowMiniaturized: ((String) -> Void)?
    var onWindowDeminiaturized: ((String) -> Void)?
    var onNativeDesktopChange: (() -> Void)?
    var onScreenParametersChange: (() -> Void)?
    var onAccessoryActivation: ((pid_t) -> Void)?
    var companionPanelRequests: [(pid: pid_t, anchor: CGRect, bounds: CGRect)] = []
    func centerCompanionPanel(pid: pid_t, over anchor: CGRect, within bounds: CGRect) {
        companionPanelRequests.append((pid, anchor, bounds))
    }

    var isAccessibilityTrusted = true
    var focusDiagnosticsEnabled = false
    var lastFocusReport: WindowFocusReport? { nil }
    var lastObservedFocusedWindowID: String? { focused }
    var hasPendingRecovery = false
    var pendingRecoveryWindowIDs: Set<String> = []
    private(set) var windows: [String: Window] = [:]
    private(set) var focused: String?
    private(set) var started = false
    /// Live windows that refuse focus, like an app blocked by a modal dialog.
    var refusesFocus: Set<String> = []
    /// How long every focus takes, like a busy app letting AX requests time out.
    var focusDelayMilliseconds = 0

    var trackedWindowIDs: Set<String> { Set(windows.keys) }

    @discardableResult
    func addWindow(_ id: String, pid: Int32, frame: CGRect, bundleIdentifier: String? = nil) -> WindowRecord {
        let record = WindowRecord(id: id, appName: "App \(pid)", title: id,
                                  bundleIdentifier: bundleIdentifier ?? "test.app\(pid)",
                                  pid: pid, frame: frame, isResizable: true)
        windows[id] = Window(record: record, frame: frame, original: frame)
        return record
    }

    func setFocus(_ id: String) { focused = id }

    /// Minimizes without the AX notification some apps never post.
    func minimizeSilently(_ id: String) {
        windows[id]?.minimized = true
        if focused == id { focused = nil }
    }

    func minimize(_ id: String) {
        minimizeSilently(id)
        onWindowMiniaturized?(id)
    }

    /// macOS focuses a window it restores from the Dock. Without the notification,
    /// only the next scan finds the window, possibly before focus is reported.
    func restoreFromDock(_ id: String, notify: Bool = true, focus: Bool = false) {
        windows[id]?.minimized = false
        if focus { focused = id }
        if notify { onWindowDeminiaturized?(id) } else { onChange?() }
    }

    /// The app quits after its windows reported their destruction, as most do.
    func terminate(pid: Int32) {
        for id in windows.keys where windows[id]?.record.pid == pid { close(id) }
        onApplicationTerminated?(pid)
    }

    func close(_ id: String) {
        windows.removeValue(forKey: id)
        if focused == id { focused = nil }
        onWindowDestroyed?(id)
    }

    func registerOwnWindow(window: NSWindow) -> String { "native" }
    func requestAccessibilityPermission() {}
    /// Pending recovery clears on the next attempt once the windows can be reached again.
    var recoveryReachable = false
    private(set) var recoveryAttempts = 0
    func recoverInterruptedSession() -> Bool {
        recoveryAttempts += 1
        let interrupted = hasPendingRecovery
        if recoveryReachable {
            hasPendingRecovery = false
            pendingRecoveryWindowIDs.removeAll()
        }
        return interrupted
    }

    func start() -> [WindowRecord] {
        started = true
        return scanWindows()
    }

    func takeParkingStatistics() -> [String: String] { [:] }
    private(set) var stopsWhileAway = 0
    func stop(windowsReachable: Bool) {
        if !windowsReachable { stopsWhileAway += 1 }
        started = false
        for id in windows.keys {
            windows[id]?.restoreFrame = nil
            if let original = windows[id]?.original { windows[id]?.frame = original }
        }
    }

    /// Scans report each window's current frame instead of the frame it was added
    /// with, so a frame the user changed reaches the model as a real scan's would.
    var scansReportLiveFrames = false

    func scanWindows() -> [WindowRecord] {
        windows.values.filter { !$0.minimized }.map { window in
            guard scansReportLiveFrames else { return window.record }
            let record = window.record
            return WindowRecord(id: record.id, appName: record.appName, title: record.title,
                                bundleIdentifier: record.bundleIdentifier, pid: record.pid,
                                frame: window.frame, isResizable: record.isResizable)
        }.sorted { $0.id < $1.id }
    }

    /// Off-main scans that report windows changed during their read.
    var staleScansRemaining = 0
    private(set) var offMainScans = 0

    /// Runs inside an off-main scan, as a notification arriving during the read would.
    var duringOffMainScan: (() -> Void)?

    func scanWindowsOffMain() async -> [WindowRecord]? {
        offMainScans += 1
        if let hook = duringOffMainScan {
            duringOffMainScan = nil
            hook()
        }
        await Task.yield()
        guard staleScansRemaining == 0 else {
            staleScansRemaining -= 1
            return nil
        }
        return scanWindows()
    }

    func record(windowID: String) -> WindowRecord? { windows[windowID]?.record }

    /// Frame reads since the last reset that asked the app. Each stands for a
    /// synchronous AX round trip on the main thread.
    private(set) var frameReads = 0
    private(set) var observedFrameReads = 0
    func resetReadCounts() {
        frameReads = 0
        observedFrameReads = 0
        focusReads = 0
    }

    func frame(windowID: String) -> CGRect? {
        guard let window = windows[windowID] else { return nil }
        // A parked window answers from its logical frame, as WindowSystem does, without asking the app.
        if let restoreFrame = window.restoreFrame { return restoreFrame }
        frameReads += 1
        return window.frame
    }

    func observedFrame(windowID: String) -> CGRect? {
        observedFrameReads += 1
        guard !unreadableFrames.contains(windowID) else { return nil }
        return windows[windowID]?.frame
    }
    /// Attached sheets by owner, placed relative to the owner's origin.
    var sheets: [String: CGRect] = [:]
    func sheetFrame(windowID: String, over frame: CGRect) -> CGRect? {
        sheets[windowID]?.offsetBy(dx: frame.minX, dy: frame.minY)
    }
    func windowNumber(for windowID: String) -> CGWindowID? { nil }
    func isParked(windowID: String) -> Bool { windows[windowID]?.restoreFrame != nil }

    func unavailability(windowID: String) -> WindowUnavailability? {
        guard let window = windows[windowID] else { return .closed }
        return window.minimized ? .minimized : nil
    }

    func setPosition(windowID: String, position: CGPoint) -> Bool {
        guard let window = windows[windowID], !window.minimized, window.restoreFrame == nil else { return false }
        windows[windowID]?.frame.origin = position
        return true
    }

    /// Position writes made by ribbon motion; none means nothing slid.
    private(set) var motionPositionWrites = 0
    func setMotionPosition(windowID: String, position: CGPoint) -> Bool {
        motionPositionWrites += 1
        return setPosition(windowID: windowID, position: position)
    }

    func finishMotionWrites() async {}

    private(set) var raisedWithoutActivating: [String] = []
    func raiseWithoutActivating(windowID: String) { raisedWithoutActivating.append(windowID) }

    func motionWriteStatistics(reset: Bool, focusedWindowID: String?) -> [String: String] { [:] }

    /// Windows whose frame writes are refused, and whose frames cannot be read back,
    /// like a closing window or one whose app is not answering.
    var refusesFrames: Set<String> = []
    var unreadableFrames: Set<String> = []
    private(set) var setFrameCalls: [String] = []

    /// Sizes apps refuse to go below; a smaller write takes the minimum instead and
    /// reports the refusal, as WindowSystem's verified write does.
    var minimumSizes: [String: CGSize] = [:]
    private(set) var clampedFrameWrites: [String] = []

    func setFrame(windowID: String, frame: CGRect) -> Bool {
        setFrameCalls.append(windowID)
        guard let window = windows[windowID], !window.minimized, !refusesFrames.contains(windowID) else { return false }
        var accepted = frame
        if let minimum = minimumSizes[windowID] {
            accepted.size.width = max(accepted.width, minimum.width)
            accepted.size.height = max(accepted.height, minimum.height)
        }
        windows[windowID]?.restoreFrame = nil
        windows[windowID]?.frame = accepted
        guard accepted == frame else {
            clampedFrameWrites.append(windowID)
            return false
        }
        return true
    }

    /// The user resized or moved a window directly, as a title-bar drag does.
    func userSetFrame(_ id: String, _ frame: CGRect) {
        windows[id]?.frame = frame
    }

    var parkRemnantWidths: [String: CGFloat] = [:]

    func park(windowID: String, preferredSide: WindowParkingSide?, remnantWidth: CGFloat) -> Bool {
        guard let window = windows[windowID], !window.minimized else { return false }
        parkRemnantWidths[windowID] = remnantWidth
        if window.restoreFrame == nil { windows[windowID]?.restoreFrame = window.frame }
        windows[windowID]?.frame.origin.x = preferredSide == .left ? -window.frame.width + 1 : 100_000
        return true
    }

    /// Focus reads since the last reset; each is a synchronous AX round trip to the focused app.
    private(set) var focusReads = 0

    func focusedWindowIDOffMain() async -> String? { focusedWindowID() }

    func focusedWindowID() -> String? {
        focusReads += 1
        return focused
    }

    /// The focused window's app is the frontmost app.
    func mayHoldFocus(windowID: String) -> Bool {
        guard let pid = windows[windowID]?.record.pid, let focused else { return false }
        return windows[focused]?.record.pid == pid
    }

    func focus(windowID: String) async -> Bool {
        if focusDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(focusDelayMilliseconds))
        }
        guard let window = windows[windowID], !window.minimized, !refusesFocus.contains(windowID) else {
            return false
        }
        windows[windowID]?.restoreFrame = nil
        focused = windowID
        return true
    }
}

/// The left button and the drag pasteboard, as PointerDragTracker sees them.
@MainActor
final class FakePointer {
    var buttonDown = false
    var dragChangeCount = 10
    lazy var tracker = PointerDragTracker(buttonDown: { [unowned self] in buttonDown },
                                          dragChangeCount: { [unowned self] in dragChangeCount })

    /// Holds the button over another app and starts a drag session.
    func beginDragAndDrop() {
        buttonDown = true
        tracker.pressBegan(inStagehand: false)
        dragChangeCount += 1
    }

    /// Holds the button over another app without a drag session: a title-bar drag.
    func beginWindowDrag() {
        buttonDown = true
        tracker.pressBegan(inStagehand: false)
    }

    func release() {
        buttonDown = false
        tracker.pressEnded()
    }
}

@MainActor
final class FakeInput: InputControlling {
    var onAction: ((NavigationAction) -> Void)?
    var onGesture: ((GestureNavigationEvent) -> Void)?
    var onStatusChange: (() -> Void)?
    var onDropCheckRequested: (() -> Void)?
    var gesturesEnabled = false
    var shortcutSwipesEnabled = false
    var reverseShortcutSwipeDirection = true
    var issues: [String] = []
    func start() {}
    func stop() {}
    func setShortcutBindings(_ bindings: [ShortcutBinding]) {}
    func setShortcutCaptureActive(_ active: Bool) {}
    func takePendingGestureCompletion() -> GestureNavigationCompletion? { nil }
    func cancelGestureSequence() {}
}

@MainActor
final class FakeEmptySpace: EmptySpacePresenting {
    private(set) var isFocused = false
    func show(space: Int, frame: CGRect) async -> Bool {
        isFocused = true
        return true
    }
    func hide() { isFocused = false }
}

/// Records what the app bar and border would show without opening windows.
@MainActor
final class FakeOverlays: NavigationPresenting {
    var onFocusWindow: ((String) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String) -> Void)?
    var canRevealNavigation: (() -> Bool)?
    var pointerCarriesDrop: (() -> Bool)?
    private(set) var shortcutHintToggles = 0
    private(set) var warnings: [String] = []
    private(set) var borderFrame: CGRect?
    private(set) var borderSheet: CGRect?
    var suspensions = 0
    /// Each time the border appeared (true) or disappeared (false).
    var borderVisibility: [Bool] = []

    func setBorderColor(_ color: NSColor) {}
    func updateBorder(frame: CGRect, sheet: CGRect?, visible: Bool, cornerRadius: CGFloat?,
                      focusChanged: Bool, raiseBorder: Bool) {
        if visible != (borderFrame != nil) { borderVisibility.append(visible) }
        borderFrame = visible ? frame : nil
        borderSheet = visible ? sheet : nil
    }
    func showNavigation(state: WorkspaceState, windows: [WindowRecord]) {}
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord]) {}
    func showWarning(_ message: String) { warnings.append(message) }
    private(set) var notices: [String] = []
    func showNotice(_ message: String) { notices.append(message) }
    func setShortcutHints(_ bindings: [ShortcutBinding], swipeTip: String?) {}
    func toggleShortcutHints() { shortcutHintToggles += 1 }
    func hide() {
        if borderFrame != nil { borderVisibility.append(false) }
        borderFrame = nil
    }
    func suspend() {
        suspensions += 1
        hide()
    }
}

/// Finishes every ribbon animation immediately, as with Reduce Motion.
final class ImmediateFrameDriver: RibbonFrameDriving {
    private(set) var displays: [CGDirectDisplayID] = []
    func start(display: CGDirectDisplayID, onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        displays.append(display)
        return false
    }
    func stop() {}
}

extension ScreenDescription {
    /// The first screen's geometry as a built-in display, so tests run the same on a Mac without one.
    @MainActor static var testBuiltIn: ScreenDescription {
        let screen = NSScreen.screens.first
        return ScreenDescription(
            id: DisplayID(rawValue: "B0000000-0000-0000-0000-000000000001"), number: 1,
            frame: screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875),
            isBuiltIn: true, backingScaleFactor: screen?.backingScaleFactor ?? 2, maximumFramesPerSecond: 120)
    }

    static func external(number: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect? = nil,
                         backingScaleFactor: CGFloat = 1) -> ScreenDescription {
        ScreenDescription(id: DisplayID(rawValue: String(format: "E%07X-0000-0000-0000-000000000000", number)),
                          number: number, frame: frame, visibleFrame: visibleFrame ?? frame, isBuiltIn: false,
                          backingScaleFactor: backingScaleFactor, maximumFramesPerSecond: 60)
    }
}

extension DisplayArrangement {
    @MainActor static var testBuiltIn: DisplayArrangement { DisplayArrangement(screens: [.testBuiltIn]) }
    /// Clamshell: an external display and no built-in one.
    static let externalOnly = DisplayArrangement(screens: [
        .external(number: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    ])
}

@MainActor
final class DesktopFixture {
    var id: UInt64? = 1
    /// Empty: one display, read through the active Space alone.
    var displays: [DisplayID] = []
    var displaySpaces: [DisplayID: UInt64] = [:]
}

/// A model wired to fakes, recording diagnostics to a temporary file.
@MainActor
struct ModelHarness {
    let model: StagehandModel
    let windows: FakeWindowSystem
    let overlays: FakeOverlays
    let pointer = FakePointer()
    let logURL: URL
    let preferencesSuite = "stagehand-tests-\(UUID().uuidString)"
    let postedEvents: () -> Int
    let frameDriver = ImmediateFrameDriver()

    /// The Desktop reported to the model; nil means WindowServer gave no identity.
    let desktop: DesktopFixture

    init(windowIDs: [String], focused: String, layoutStore: WorkspaceLayoutStore? = nil,
         transferTimeoutMilliseconds: Int = 4_000) {
        let desktop = DesktopFixture()
        self.desktop = desktop
        let windows = FakeWindowSystem()
        let available = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        for (index, id) in windowIDs.enumerated() {
            windows.addWindow(id, pid: Int32(100 + index), frame: CGRect(
                x: available.minX + CGFloat(index) * 40, y: 40,
                width: available.width * 0.6, height: available.height * 0.8
            ))
        }
        windows.setFocus(focused)
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagehand-model-\(UUID().uuidString).log")
        var posted = 0
        let gate = FocusInputGate(transferTimeoutMilliseconds: transferTimeoutMilliseconds,
                                  installsEventTap: false) { _, _ in posted += 1 }
        let overlays = FakeOverlays()
        model = StagehandModel(
            overlays: overlays,
            diagnostics: DiagnosticLogger(logURL: logURL, enabled: true),
            windowSystem: windows,
            input: FakeInput(),
            emptySpace: FakeEmptySpace(),
            desktopScope: DesktopScope(currentDesktopID: { desktop.id }, displaySource: DisplaySpaceSource(
                connectedDisplays: { desktop.displays }, screensHaveSeparateSpaces: { true },
                currentSpace: { desktop.displaySpaces[$0] }, readerSymbol: "SLSManagedDisplayGetCurrentSpace")),
            focusGate: gate,
            ribbonMotion: RibbonMotion(frameDriver: frameDriver),
            pointer: pointer.tracker,
            layoutStore: layoutStore,
            preferences: UserDefaults(suiteName: preferencesSuite)!
        )
        model.displayArrangementProvider = { .testBuiltIn }
        self.windows = windows
        self.overlays = overlays
        postedEvents = { posted }
    }

    /// Waits for queued changes, motion, and refreshes to finish.
    func settle(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var quietSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            let busy = model.changes.isProcessing || model.ribbonMotion.isRunning || model.automaticResumeTask != nil
            if busy {
                quietSince = nil
            } else if let quietSince, quietSince.duration(to: .now) > .milliseconds(150) {
                return
            } else if quietSince == nil {
                quietSince = .now
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func events(_ name: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == name else { return nil }
            return object
        }
    }

    func cleanUp() {
        model.pause()
        try? FileManager.default.removeItem(at: logURL)
        model.preferences.removePersistentDomain(forName: preferencesSuite)
    }
}
