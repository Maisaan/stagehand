import AppKit
import StagehandCore
@preconcurrency import ApplicationServices
import Darwin
import os

/// Diagnostic lines go to the unified log. Nothing here carries window titles
/// or other user content, so every value is marked public to stay readable.
private let logger = Logger(subsystem: "app.stagehand.Stagehand", category: "window-system")

/// `_AXUIElementGetWindow` is private HIServices API. Binding it at link time
/// would stop the app launching on a system where the symbol is gone; resolving
/// it at first use leaves window numbers unavailable instead, and matching then
/// falls back to element identity and geometry.
/// Timing and geometry constants shared by the window system. Values are the
/// ones the code has always used; they live here so a change to one is deliberate
/// and visible rather than buried in a call site.
public enum WindowTuning {
    /// How long a single Accessibility request to the system-wide element may wait.
    public static let accessibilityMessagingTimeoutSeconds: Float = 0.1
    /// Cadence of the CGWindowList poll that notices apps and windows AX did not report.
    public static let applicationInventoryPollSeconds: Int = 2
    /// Delays between AXObserverAddNotification retries for an app answering
    /// .cannotComplete; the last value repeats while the app runs.
    public static let observationRetryDelaysMilliseconds = [100, 200, 400, 800, 1600, 3200, 5000, 10_000, 20_000, 30_000]
    /// Waits before each further restoreAll attempt for a window that failed to restore.
    public static let restoreRetryDelaysMilliseconds = [50, 100]
    /// Rechecks after an app launches or activates before a usable window appears.
    public static let launchDiscoveryDelays: [Duration] = [
        .milliseconds(100), .milliseconds(250), .milliseconds(500),
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)
    ]
    /// How long a native (Stagehand-owned) window may take to become key after activation.
    public static let nativeFocusDeadlineMilliseconds = 180
    /// Poll interval while waiting for a native window to become key.
    public static let nativeFocusPollMilliseconds = 8
    /// After the target app is active, how long its exact window may take to own focus
    /// before the attempt reports a timeout.
    public static let focusActivationDeadlineMilliseconds = 600
    /// Upper bound on one focus attempt, including recovery of a refused activation.
    public static let focusRecoveryDeadlineMilliseconds = 1_500
    /// The widest strip of a parked window that may stay on the screen it was parked from.
    public static let parkedRemnantWidth: CGFloat = 64
    /// The widest strip a user may allow for an app that clamps its windows onscreen.
    public static let maximumParkedRemnantWidth: CGFloat = 600
    /// A journaled coordinate or size beyond this is treated as corrupt rather than restored.
    public static let recoveryFrameBound: CGFloat = 100_000
    /// Cadence of the poll that writes a deferred recovery frame once its window
    /// is no longer minimized. Runs only while such records exist, even when stopped.
    public static let deferredRecoveryPollSeconds: Int = 5
}

private enum AccessibilityWindowNumber {
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let function: Function? = {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        // Keep this framework reference for process lifetime while the pointer is in use.
        let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) ?? dlopen(nil, RTLD_NOW)
        guard let handle, let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
}

public struct WindowRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let appName: String
    public let title: String
    public let bundleIdentifier: String
    public let pid: Int32
    /// Accessibility coordinates: origin at the top left of the primary display.
    public let frame: CGRect
    public let isResizable: Bool

    public func withTitle(_ title: String) -> WindowRecord {
        WindowRecord(id: id, appName: appName, title: title, bundleIdentifier: bundleIdentifier,
                     pid: pid, frame: frame, isResizable: isResizable)
    }
}

/// Positive evidence that a managed window can no longer take part in the ribbon.
public enum WindowUnavailability: String, Sendable {
    case minimized
    case closed
}

func canManageWindows(
    for activationPolicy: NSApplication.ActivationPolicy,
    hasVisibleOrTrackedWindow: Bool
) -> Bool {
    activationPolicy == .regular || activationPolicy == .accessory && hasVisibleOrTrackedWindow
}

func uniqueWindowID(
    matchingFrame frame: CGRect,
    among candidates: [(id: String, frame: CGRect?)]
) -> String? {
    let matches = candidates.compactMap { candidate -> String? in
        guard let candidateFrame = candidate.frame,
              abs(candidateFrame.minX - frame.minX) < 1,
              abs(candidateFrame.minY - frame.minY) < 1,
              abs(candidateFrame.width - frame.width) < 1,
              abs(candidateFrame.height - frame.height) < 1 else { return nil }
        return candidate.id
    }
    return matches.count == 1 ? matches[0] : nil
}

/// Controls external windows through Accessibility and registered Stagehand windows through AppKit.
@MainActor
public final class WindowSystem {
    public var onChange: (() -> Void)?
    public var onFrameChange: ((String, CGRect) -> Void)?
    public var onFocusedWindowChange: ((String) -> Void)?
    /// A tracked window's title changed. No rescan is scheduled for it.
    public var onTitleChange: ((String, String) -> Void)?
    public var onApplicationTerminated: ((pid_t) -> Void)?
    public var onWindowDestroyed: ((String) -> Void)?
    public var onWindowMiniaturized: ((String) -> Void)?
    public var onWindowDeminiaturized: ((String) -> Void)?
    public var onNativeDesktopChange: (() -> Void)?
    public var onScreenParametersChange: (() -> Void)?
    public var onAccessoryActivation: ((pid_t) -> Void)?
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var focusDiagnosticsEnabled = false
    /// Restricts management to these apps, excluding Stagehand's own windows. The
    /// acceptance runner uses it so disposable windows are the only ones moved.
    public var managedBundleIdentifiers: Set<String>?
    public private(set) var lastFocusReport: WindowFocusReport?
    public private(set) var lastObservedFocusedWindowID: String?

    /// Includes known windows omitted from a scan while busy, minimized, or on another Desktop.
    public var trackedWindowIDs: Set<String> {
        Set(windows.keys).union(nativeWindows.trackedWindowIDs)
    }

    private struct TrackedWindow {
        var element: AXUIElement
        var windowNumber: CGWindowID?
        var record: WindowRecord
        var originalFrame: CGRect?
        var parking = WindowParking()
        var logicalFrame: CGRect? { parking.isParked ? parking.restoreFrame : nil }
        var isAdmitted = true
        var missedScans = 0
        var observationComplete = false
    }

    private struct OwnedWindow {
        let element: AXUIElement
        let parentID: String
    }

    private struct VisibleWindowIdentity: Hashable {
        let pid: pid_t
        let windowNumber: CGWindowID
    }

    private struct ApplicationInventory: Equatable {
        let applicationPIDs: Set<pid_t>
        let visibleWindows: Set<VisibleWindowIdentity>
    }

    private var windows: [String: TrackedWindow] = [:]
    private var ownedWindows: [OwnedWindow] = []
    private var observers: [pid_t: AXObserver] = [:]
    private let motionWriter = MotionPositionWriter()
    private var focusReportInFlight = false
    private var focusReportPending = false
    /// Answers whether an observed focus change would be used now. Reads nobody
    /// would use, such as during Stagehand's own navigation, are skipped.
    public var wantsObservedFocus: (() -> Bool)?
    /// Answers whether moved or resized windows' frames would be used now. Checked
    /// before identifying the window and reading its frame, which are AX round
    /// trips to an app that may be busy; ribbon motion's own writes echo back here.
    public var wantsFrameChange: (() -> Bool)?
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var observationRetries: [pid_t: Task<Void, Never>] = [:]
    /// One serial queue per app for its notification registrations. A launching app
    /// answers each with cannotComplete only at the messaging timeout; four of those
    /// on the main thread blocked it for ~400 ms on every attempt.
    private var observationQueues: [pid_t: DispatchQueue] = [:]
    private let launchDiscovery = ApplicationLaunchDiscovery()
    private var applicationInventoryTask: Task<Void, Never>?
    /// Set while the login session is inactive or the displays are asleep. The
    /// inventory poll keeps its cadence but skips the CGWindowList read, which
    /// cannot change while nothing is being drawn.
    private var inventoryPaused = false
    private var lastApplicationInventory: ApplicationInventory?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var applicationTokens: [NSObjectProtocol] = []
    private var nextFallbackID: UInt64 = 0
    private var started = false
    private let systemElement = AXUIElementCreateSystemWide()
    private let nativeWindows = NativeWindowRegistry()
    private let recoveryJournal = WindowRecoveryJournal()
    private var interruptedWindowIDs: Set<String> = []
    private var missingRecoveryWindowIDs: Set<String> = []
    /// Records whose window was minimized when restoration was attempted and did not
    /// accept a frame write. They do not block Start; the frame is written when AX
    /// reports the window de-miniaturized, or by the next recovery pass.
    private var deferredRecoveryWindowIDs: Set<String> = [] {
        didSet { if !deferredRecoveryWindowIDs.isEmpty { startDeferredRecoveryPoll() } }
    }
    private var deferredRecoveryTask: Task<Void, Never>?
    /// Windows an earlier pass could not put back. Each still has a journal record.
    public var pendingRecoveryWindowIDs: Set<String> {
        interruptedWindowIDs.filter { recoveryJournal.records[$0] != nil && !deferredRecoveryWindowIDs.contains($0) }
    }
    public var hasPendingRecovery: Bool { !pendingRecoveryWindowIDs.isEmpty }

    public init() {
        interruptedWindowIDs = Set(recoveryJournal.records.keys)
        AXUIElementSetMessagingTimeout(systemElement, WindowTuning.accessibilityMessagingTimeoutSeconds)
        nativeWindows.onChange = { [weak self] in
            guard let self, self.started else { return }
            self.onChange?()
        }
        nativeWindows.onFrameChange = { [weak self] id, frame in
            guard let self, self.started else { return }
            self.onFrameChange?(id, frame)
        }
        nativeWindows.onFocusedWindowChange = { [weak self] id in
            guard let self, self.started else { return }
            self.onFocusedWindowChange?(id)
        }
        nativeWindows.onWindowDestroyed = { [weak self] id in
            guard let self, self.started else { return }
            self.onWindowDestroyed?(id)
        }
        nativeWindows.onWindowMiniaturized = { [weak self] id in
            guard let self, self.started else { return }
            self.onWindowMiniaturized?(id)
        }
        nativeWindows.onWindowDeminiaturized = { [weak self] id in
            guard let self, self.started else { return }
            self.onWindowDeminiaturized?(id)
        }
    }

    /// Register Stagehand's settings explicitly. HUD and empty-space windows stay unmanaged.
    @discardableResult
    public func registerOwnWindow(window: NSWindow) -> String {
        nativeWindows.register(window: window)
    }

    public func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Restore exact windows left at ribbon or parking positions by an interrupted process.
    /// A failed AX read stays in the journal for the next attempt.
    public func recoverInterruptedSession() -> Bool {
        guard isAccessibilityTrusted else { return false }
        var foundInterruptedWindow = false
        for id in interruptedWindowIDs {
            guard let record = recoveryJournal.records[id] else { continue }
            if let owner = NSRunningApplication(processIdentifier: record.ownerPID),
               record.isOwnedByProcess(pid: owner.resolvedProcessIdentifier,
                                       launchDate: ProcessLaunchDate.launchDate(for: owner)) {
                // Another live Stagehand owns the window, or this one is still
                // managing it. Once this process has stopped, its own leftovers
                // from a failed restoreAll are retried like any other record.
                let ownRecord = record.ownerPID == ProcessInfo.processInfo.processIdentifier
                guard ownRecord, !started else {
                    foundInterruptedWindow = true
                    continue
                }
            }
            guard let app = NSRunningApplication(processIdentifier: record.pid),
                  record.matchesProcess(bundleIdentifier: app.bundleIdentifier,
                                        pid: app.resolvedProcessIdentifier,
                                        launchDate: ProcessLaunchDate.launchDate(for: app)) else {
                try? recoveryJournal.remove(windowID: record.windowID)
                continue
            }
            let element: AXUIElement
            switch recoveryElement(for: record) {
            case .found(let match):
                element = match
            case .unavailable:
                foundInterruptedWindow = true
                continue
            case .absent:
                // Some apps publish their AX window list late after Stagehand launches.
                // Require a second complete inventory before treating a window as closed.
                if missingRecoveryWindowIDs.insert(id).inserted {
                    foundInterruptedWindow = true
                } else {
                    try? recoveryJournal.remove(windowID: id)
                }
                continue
            }
            missingRecoveryWindowIDs.remove(id)
            foundInterruptedWindow = true
            guard let minimized = attribute(element, kAXMinimizedAttribute) as? Bool else { continue }
            let fullscreen = copyAttribute(element, "AXFullScreen")
            guard fullscreen.error != .cannotComplete else { continue }
            if fullscreen.value as? Bool == true {
                forgetRecovery(windowID: record.windowID)
                continue
            }
            if let current = readFrame(element), sameBounds(current, record.frame) ||
                writeFrame(element, frame: record.frame) {
                forgetRecovery(windowID: record.windowID)
            } else if minimized {
                // The Dock tile hides a parked position. Keep the record so the
                // frame is written once the window is shown again.
                deferredRecoveryWindowIDs.insert(id)
            }
        }
        interruptedWindowIDs = interruptedWindowIDs.filter { recoveryJournal.records[$0] != nil }
        deferredRecoveryWindowIDs = deferredRecoveryWindowIDs.filter { recoveryJournal.records[$0] != nil }
        return foundInterruptedWindow
    }

    enum RecoverySearch {
        case found(AXUIElement)
        /// The window is confirmed gone from its app's window list.
        case absent
        /// The app did not answer, or window identities cannot be read at all, so
        /// absence is not established and the record must be kept.
        case unavailable
    }

    private func recoveryElement(for record: WindowRecoveryRecord) -> RecoverySearch {
        let appElement = AXUIElementCreateApplication(record.pid)
        guard let elements = copyAttribute(appElement, kAXWindowsAttribute).value as? [AXUIElement] else {
            return .unavailable
        }
        return Self.recoveryMatch(elements, numbers: elements.map { windowNumber($0) },
                                  target: record.windowNumber, identityAvailable: Self.windowIdentityAvailable)
    }

    /// Without _AXUIElementGetWindow every lookup is nil, which must not read as
    /// "every journaled window has closed".
    nonisolated static var windowIdentityAvailable: Bool { AccessibilityWindowNumber.function != nil }

    nonisolated static func recoveryMatch(_ elements: [AXUIElement], numbers: [CGWindowID?],
                                          target: CGWindowID, identityAvailable: Bool) -> RecoverySearch {
        guard identityAvailable else { return .unavailable }
        guard let index = numbers.firstIndex(where: { $0 == target }) else { return .absent }
        return .found(elements[index])
    }

    /// Journal records whose window was minimized when restoration was refused. They
    /// are retried here independently of tracking or admission: the recovery pass
    /// only runs before Start, the de-miniaturize route only fires for a tracked
    /// window, and a minimized window is never admitted by a scan.
    private func startDeferredRecoveryPoll() {
        guard deferredRecoveryTask == nil else { return }
        deferredRecoveryTask = Task { @MainActor [weak self] in
            defer { self?.deferredRecoveryTask = nil }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(WindowTuning.deferredRecoveryPollSeconds)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.pollDeferredRecovery()
                if self.deferredRecoveryWindowIDs.isEmpty { return }
            }
        }
    }

    private func pollDeferredRecovery() {
        guard isAccessibilityTrusted else { return }
        for id in deferredRecoveryWindowIDs {
            guard let record = recoveryJournal.records[id] else {
                deferredRecoveryWindowIDs.remove(id)
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated,
                  record.matchesProcess(bundleIdentifier: app.bundleIdentifier,
                                        pid: app.resolvedProcessIdentifier,
                                        launchDate: ProcessLaunchDate.launchDate(for: app)) else {
                forgetRecovery(windowID: id)
                continue
            }
            // A window this process is managing again is the model's to place.
            if started, let tracked = windows[id], tracked.isAdmitted { continue }
            let element: AXUIElement
            if let tracked = windows[id] {
                element = tracked.element
            } else {
                switch recoveryElement(for: record) {
                case .found(let match): element = match
                case .absent: forgetRecovery(windowID: id); continue
                case .unavailable: continue
                }
            }
            guard attribute(element, "AXFullScreen") as? Bool != true else {
                forgetRecovery(windowID: id)
                continue
            }
            if let current = readFrame(element), sameBounds(current, record.frame) ||
                writeFrame(element, frame: record.frame) {
                forgetRecovery(windowID: id)
                if focusDiagnosticsEnabled { logger.notice("Recovery deferred=\(id, privacy: .public) restored=true") }
            }
        }
    }

    /// A de-miniaturized window whose recovery was deferred goes back to its
    /// journaled frame before the model lays it out again.
    private func completeDeferredRecovery(windowID id: String) {
        guard let tracked = windows[id] else { return }
        let deferred = deferredRecoveryWindowIDs.compactMap { recoveryJournal.records[$0] }.first {
            $0.windowID == id || $0.pid == tracked.record.pid && $0.windowNumber == tracked.windowNumber
        }
        guard let deferred else { return }
        if let current = readFrame(tracked.element), sameBounds(current, deferred.frame) ||
            writeFrame(tracked.element, frame: deferred.frame) {
            forgetRecovery(windowID: deferred.windowID)
            forgetRecovery(windowID: id)
        }
    }

    /// The window is back where it started, or macOS now owns it. Clear the record
    /// and any tracking left from this process so the next move captures afresh.
    private func forgetRecovery(windowID: String) {
        try? recoveryJournal.remove(windowID: windowID)
        interruptedWindowIDs.remove(windowID)
        deferredRecoveryWindowIDs.remove(windowID)
        if windows[windowID] != nil {
            windows[windowID]?.originalFrame = nil
            windows[windowID]?.parking = WindowParking()
        }
    }

    @discardableResult
    public func start() -> [WindowRecord] {
        guard !started else { return scanWindows() }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                    .map(\.resolvedProcessIdentifier).flatMap { $0 > 0 ? $0 : nil }
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    if self.focusDiagnosticsEnabled {
                        logger.notice("Discovery t=\(ProcessInfo.processInfo.systemUptime, privacy: .public) workspace=\(name.rawValue, privacy: .public) pid=\(pid.map(String.init) ?? "nil", privacy: .public)")
                    }
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self.reportCurrentFocus()
                        if let pid, pid != ProcessInfo.processInfo.processIdentifier,
                           let app = NSRunningApplication(processIdentifier: pid),
                           Self.isSystemAgent(app), !self.windows.values.contains(where: { $0.record.pid == pid }) {
                            self.onAccessoryActivation?(pid)
                        }
                    }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        // Without the process there is nothing to drop; pid 0 would
                        // otherwise flow into removeObserver and the journal.
                        guard let pid else { return }
                        self.applicationTerminated(pid: pid)
                    }
                    if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didActivateApplicationNotification,
                       let pid, let app = NSRunningApplication(processIdentifier: pid) {
                        self.scheduleDiscovery(for: app)
                    }
                    self.onChange?()
                }
            })
        }
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.onNativeDesktopChange?()
            }
        })
        for name in [NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
                    self.inventoryPaused = name == NSWorkspace.sessionDidResignActiveNotification
                    self.onNativeDesktopChange?()
                }
            })
        }
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.inventoryPaused = true
            }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
                    self.inventoryPaused = false
                    self.onNativeDesktopChange?()
                    self.onChange?()
                }
            })
        }
        applicationTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                self.onScreenParametersChange?()
            }
        })
        let records = scanWindows()
        startApplicationInventory()
        return records
    }

    /// The process is gone, so its windows cannot be restored and their journal
    /// records would only accumulate until the next launch's recovery pass.
    private func applicationTerminated(pid: pid_t) {
        trackedStateGeneration &+= 1
        motionWriter.forget(pid: pid)
        removeObserver(pid: pid)
        let removedIDs = windows.compactMap { $0.value.record.pid == pid ? $0.key : nil }
        for id in removedIDs {
            windows.removeValue(forKey: id)
        }
        for record in recoveryJournal.records.values where record.pid == pid {
            try? recoveryJournal.remove(windowID: record.windowID)
            interruptedWindowIDs.remove(record.windowID)
        }
        if !removedIDs.isEmpty { onApplicationTerminated?(pid) }
    }

    public func stop() {
        started = false
        applicationInventoryTask?.cancel()
        applicationInventoryTask = nil
        inventoryPaused = false
        lastApplicationInventory = nil
        launchDiscovery.cancelAll()
        restoreAll()
        // A subsequent Start can happen on a different native Desktop. Keep
        // stable identities, but admit only its visible windows again.
        for id in Array(windows.keys) {
            windows[id]?.isAdmitted = false
            windows[id]?.observationComplete = false
        }
        ownedWindows.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
        applicationTokens.removeAll()
        for pid in Array(observers.keys) { removeObserver(pid: pid) }
        for retry in observationRetries.values { retry.cancel() }
        observationRetries.removeAll()
        applicationObservations.removeAll()
    }

    /// The observer callbacks hold an unretained pointer to this object. Every
    /// run-loop source and notification must be gone before it is freed.
    deinit {
        MainActor.assumeIsolated {
            for pid in Array(observers.keys) { removeObserver(pid: pid) }
            for retry in observationRetries.values { retry.cancel() }
            applicationInventoryTask?.cancel()
            deferredRecoveryTask?.cancel()
            let center = NSWorkspace.shared.notificationCenter
            for token in workspaceTokens { center.removeObserver(token) }
            for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    public func scanWindows() -> [WindowRecord] {
        guard isAccessibilityTrusted else {
            return windows.values.filter(\.isAdmitted).map(\.record) + nativeWindows.records
        }
        let plan = beginScan()
        return applyScan(plan, reads: Self.readApplications(plan.reads))
    }

    /// Reads Accessibility data on a background queue, then applies it on the main
    /// actor. Returns nil when windows changed availability or another scan ran
    /// during the read; callers should scan again later.
    public func scanWindowsOffMain() async -> [WindowRecord]? {
        guard isAccessibilityTrusted else { return scanWindows() }
        let plan = beginScan()
        let generation = trackedStateGeneration
        let reads = await withCheckedContinuation { continuation in
            Self.scanQueue.async { continuation.resume(returning: Self.readApplications(plan.reads)) }
        }
        guard started, generation == trackedStateGeneration else { return nil }
        return applyScan(plan, reads: reads)
    }

    private static let scanQueue = DispatchQueue(label: "app.stagehand.scan-accessibility", qos: .userInitiated)

    /// Advances whenever tracked windows change outside a scan. An off-main scan
    /// whose reads predate the change must not apply them, or it could restore a
    /// window that was just closed or minimized.
    private var trackedStateGeneration = 0
    /// Windows each app lists without the metadata a scan needs, as last reported.
    /// Finder lists one such window permanently; report it once, not every scan.
    private var reportedMissingMetadata: [pid_t: Set<String>] = [:]

    private struct ScanPlan: @unchecked Sendable {
        let apps: [NSRunningApplication]
        let livePIDs: Set<pid_t>
        let visibleWindows: [VisibleWindow]
        let reads: ScanReadRequest
    }

    fileprivate struct ScanReadRequest: @unchecked Sendable {
        let system: WindowSystem
        let pids: [pid_t]
        let identities: IdentitySnapshot
    }

    /// Accessibility data for one app, gathered without touching tracked state.
    fileprivate struct ApplicationRead: @unchecked Sendable {
        struct Candidate {
            let element: AXUIElement
            let windowNumber: CGWindowID?
            let metadata: ScanMetadata
            let owner: AXUIElement?
            let ownerPID: pid_t?
            let ownerNumber: CGWindowID?
            let isChild: Bool
            /// A tracked window with an attached child dialog. Chrome reports its browser
            /// window as AXDialog while a JavaScript dialog is open.
            let hostsTrackedChild: Bool
            /// A dialog attached to no window, such as Xcode's component installer.
            /// It joins the ribbon while its Dock app has no standard window.
            let isUnattachedDialog: Bool
            /// Read only for windows that pass the cheap metadata filters.
            let movable: (status: AXError, value: Bool)?
            let resizable: (status: AXError, value: Bool)?
        }
        let windowsStatus: AXError
        let candidates: [Candidate]?
    }

    private func beginScan() -> ScanPlan {
        let runningApps = MainThreadActivity.during("runningApplications") { NSWorkspace.shared.runningApplications }
        // Modal panels count only toward a standalone dialog's admission.
        let visibleWindows = onScreenWindows(includingModalPanels: true)
        let accessoryPIDs = Set(visibleWindows.filter { !$0.isModalPanel }.map(\.pid))
            .union(windows.values.map(\.record.pid))
        let apps = eligibleApplications(from: runningApps, accessoryPIDs: accessoryPIDs)
        let livePIDs = Set(apps.map(\.resolvedProcessIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            removeObserver(pid: pid)
        }
        if focusDiagnosticsEnabled {
            logger.notice("Scan t=\(ProcessInfo.processInfo.systemUptime, privacy: .public) runningApps=\(runningApps.count, privacy: .public) eligibleApps=\(apps.count, privacy: .public) cgVisibleWindows=\(visibleWindows.count, privacy: .public)")
        }
        if started {
            for app in apps {
                observeApplication(AXUIElementCreateApplication(app.resolvedProcessIdentifier), pid: app.resolvedProcessIdentifier)
            }
        }
        return ScanPlan(apps: apps, livePIDs: livePIDs, visibleWindows: visibleWindows,
                        reads: ScanReadRequest(system: self, pids: apps.map(\.resolvedProcessIdentifier),
                                               identities: identitySnapshot()))
    }

    nonisolated private static func readApplications(_ request: ScanReadRequest) -> [pid_t: ApplicationRead] {
        // A pid listed twice must not trap mid-scan with windows parked; the last read wins.
        Dictionary(request.pids.map {
            ($0, request.system.readApplication(pid: $0, identities: request.identities))
        }, uniquingKeysWith: { _, last in last })
    }

    nonisolated private func readApplication(pid: pid_t, identities: IdentitySnapshot) -> ApplicationRead {
        let appElement = AXUIElementCreateApplication(pid)
        let windowList = copyAttribute(appElement, kAXWindowsAttribute)
        guard let elements = windowList.value as? [AXUIElement] else {
            return ApplicationRead(windowsStatus: windowList.error, candidates: nil)
        }
        let basics = elements.map { (element: $0, windowNumber: windowNumber($0), metadata: readScanMetadata($0)) }
        let appMain = elementAttribute(appElement, kAXMainWindowAttribute)
        let owners = basics.map { candidate -> AXUIElement? in
            guard let owner = explicitOwner(of: candidate.element, candidates: candidate.metadata.ownerCandidates,
                                            application: appElement) ?? (candidate.metadata.modal ? appMain : nil),
                  !sameWindow(candidate.element, owner) else { return nil }
            return owner
        }
        let childFlags = basics.indices.map { index in
            owners[index].map { owner in
                basics.indices.contains { other in
                    other != index &&
                    basics[other].metadata.subrole == kAXStandardWindowSubrole &&
                    sameWindow(basics[other].element, owner)
                } || directTrackedWindowID(matching: owner, in: identities) != nil
            } ?? false
        }
        let candidates = basics.indices.map { index -> ApplicationRead.Candidate in
            let candidate = basics[index]
            let owner = owners[index]
            let isChild = childFlags[index]
            let hostsTrackedChild = !isChild &&
                basics.indices.contains { other in
                    childFlags[other] && owners[other].map { sameWindow(candidate.element, $0) } == true
                } && directTrackedWindowID(matching: candidate.element, in: identities) != nil
            var ownerPID: pid_t = 0
            let hasOwnerPID = owner.map { AXUIElementGetPid($0, &ownerPID) == .success } ?? false
            let metadata = candidate.metadata
            let isUnattachedDialog = !isChild && owner == nil && metadata.subrole == kAXDialogSubrole
            let eligible = !isChild &&
                (metadata.subrole == kAXStandardWindowSubrole || hostsTrackedChild || isUnattachedDialog) &&
                metadata.minimized == false && metadata.fullscreen.error != .cannotComplete &&
                metadata.fullscreen.value as? Bool != true &&
                (metadata.frame.map { $0.width > 1 && $0.height > 1 } ?? false)
            func settable(_ name: String) -> (status: AXError, value: Bool) {
                var value: DarwinBoolean = false
                let status = AXUIElementIsAttributeSettable(candidate.element, name as CFString, &value)
                return (status, value.boolValue)
            }
            let movable = eligible ? settable(kAXPositionAttribute) : nil
            return ApplicationRead.Candidate(
                element: candidate.element,
                windowNumber: candidate.windowNumber,
                metadata: metadata,
                owner: owner,
                ownerPID: hasOwnerPID ? ownerPID : nil,
                ownerNumber: isChild ? owner.flatMap { windowNumber($0) } : nil,
                isChild: isChild,
                hostsTrackedChild: hostsTrackedChild,
                isUnattachedDialog: isUnattachedDialog,
                movable: movable,
                resizable: movable?.value == true ? settable(kAXSizeAttribute) : nil
            )
        }
        return ApplicationRead(windowsStatus: windowList.error, candidates: candidates)
    }

    private func applyScan(_ plan: ScanPlan, reads: [pid_t: ApplicationRead]) -> [WindowRecord] {
        trackedStateGeneration &+= 1
        reportedMissingMetadata = reportedMissingMetadata.filter { plan.livePIDs.contains($0.key) }
        let visibleWindows = plan.visibleWindows
        var seen = Set<String>()
        var result: [WindowRecord] = []
        var ownedWindows: [OwnedWindow] = []
        for app in plan.apps {
            let appPID = app.resolvedProcessIdentifier
            guard let read = reads[appPID] else { continue }
            if focusDiagnosticsEnabled {
                logger.notice("Scan pid=\(appPID, privacy: .public) AXWindowsStatus=\(read.windowsStatus.rawValue, privacy: .public) count=\(read.candidates?.count ?? -1, privacy: .public)")
            }
            guard let candidates = read.candidates else {
                // A temporarily busy application must not lose its space memberships.
                for tracked in windows.values where tracked.record.pid == appPID {
                    seen.insert(tracked.record.id)
                    if tracked.isAdmitted { result.append(tracked.record) }
                }
                ownedWindows.append(contentsOf: self.ownedWindows.filter {
                    var pid: pid_t = 0
                    return AXUIElementGetPid($0.element, &pid) == .success && pid == appPID
                })
                continue
            }
            let hasStandardWindow = candidates.contains {
                $0.metadata.subrole == kAXStandardWindowSubrole && $0.metadata.minimized != true
            }
            let missingMetadata = Set(candidates.filter { !$0.isChild }.compactMap { candidate -> String? in
                guard let missing = candidate.metadata.missing else { return nil }
                return "window=\(candidate.windowNumber.map(String.init) ?? "nil") " +
                    "title=\(candidate.metadata.title.map { "\"\($0)\"" } ?? "nil") missing: \(missing)"
            })
            if focusDiagnosticsEnabled {
                for description in missingMetadata.subtracting(reportedMissingMetadata[appPID] ?? []) {
                    logger.notice("Scan pid=\(appPID, privacy: .public) rejected=missingMetadata \(description, privacy: .public)")
                }
            }
            reportedMissingMetadata[appPID] = missingMetadata
            for candidate in candidates where !candidate.isChild {
                let element = candidate.element
                let identityMatch = windows.first {
                    guard $0.value.record.pid == appPID else { return false }
                    if let candidateNumber = candidate.windowNumber,
                       let trackedNumber = $0.value.windowNumber {
                        return candidateNumber == trackedNumber
                    }
                    return CFEqual($0.value.element, element)
                }?.key
                let geometryMatches = candidate.metadata.frame.map { frame in
                    windows.filter {
                        $0.value.record.pid == appPID &&
                        (candidate.windowNumber == nil || $0.value.windowNumber == nil) &&
                        sameBounds($0.value.record.frame, frame)
                    }.map(\.key)
                } ?? []
                let existingID = identityMatch ?? (geometryMatches.count == 1 ? geometryMatches[0] : nil)
                let existing = existingID.flatMap { windows[$0] }
                // Presence in AXWindows means the window still exists, even if an
                // individual attribute temporarily times out. Keep restoration data.
                if let existingID { seen.insert(existingID) }
                guard let subrole = candidate.metadata.subrole,
                      let currentFrame = candidate.metadata.frame,
                      let minimized = candidate.metadata.minimized else {
                    // Reported above, once per change, with the window number and errors.
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                let fullscreen = candidate.metadata.fullscreen
                if fullscreen.error == .cannotComplete {
                    if focusDiagnosticsEnabled { logger.notice("Scan pid=\(appPID, privacy: .public) rejected=fullscreenReadTimeout") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                // Only Dock apps qualify, so agent prompts such as Gatekeeper's stay floating.
                // An admitted standalone dialog stays when its app later opens a standard window.
                let standaloneDialog = candidate.isUnattachedDialog && app.activationPolicy == .regular &&
                    (!hasStandardWindow || existing?.isAdmitted == true)
                guard subrole == kAXStandardWindowSubrole || (candidate.hostsTrackedChild && existing?.isAdmitted == true) ||
                        standaloneDialog,
                      currentFrame.width > 1, currentFrame.height > 1 else {
                    if focusDiagnosticsEnabled {
                        logger.notice("Scan pid=\(appPID, privacy: .public) rejected=nonstandardOrInvalidFrame window=\(candidate.windowNumber.map(String.init) ?? "nil", privacy: .public) subrole=\(subrole, privacy: .public) modal=\(candidate.metadata.modal, privacy: .public) frame=\(String(describing: currentFrame), privacy: .public) tracked=\(existingID ?? "nil", privacy: .public)")
                    }
                    continue
                }
                guard fullscreen.value as? Bool != true else {
                    if focusDiagnosticsEnabled { logger.notice("Scan pid=\(appPID, privacy: .public) unavailable=fullscreen") }
                    continue
                }
                guard !minimized else {
                    if focusDiagnosticsEnabled { logger.notice("Scan pid=\(appPID, privacy: .public) unavailable=minimized") }
                    continue
                }
                if existing?.isAdmitted != true {
                    // PID and bounds remain available without Screen Recording access.
                    // Reject ambiguous geometry rather than accidentally admitting a
                    // same-sized window belonging to another native macOS Desktop.
                    let visibleMatch = visibleWindows.contains { visible in
                        guard visible.pid == appPID,
                              !visible.isModalPanel || standaloneDialog else { return false }
                        return candidate.windowNumber.map { $0 == visible.windowNumber }
                            ?? sameBounds(visible.frame, currentFrame)
                    }
                    let geometryMatches = candidates.filter({
                        $0.metadata.frame.map { sameBounds($0, currentFrame) } == true
                    }).count
                    guard visibleMatch, candidate.windowNumber != nil || geometryMatches == 1 else {
                        if focusDiagnosticsEnabled {
                            logger.notice("Scan pid=\(appPID, privacy: .public) rejected=desktopAdmission visibleMatch=\(visibleMatch, privacy: .public) sameGeometryCount=\(geometryMatches, privacy: .public)")
                        }
                        continue
                    }
                }
                guard let movable = candidate.movable, movable.status == .success else {
                    if focusDiagnosticsEnabled { logger.notice("Scan pid=\(appPID, privacy: .public) rejected=positionSettableReadFailed") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard movable.value else {
                    if focusDiagnosticsEnabled { logger.notice("Scan pid=\(appPID, privacy: .public) rejected=notMovable") }
                    continue
                }
                let id: String
                if let existingID {
                    id = existingID
                } else if let windowNumber = candidate.windowNumber {
                    id = "\(appPID):\(windowNumber)"
                } else {
                    nextFallbackID += 1
                    id = "\(appPID):fallback:\(nextFallbackID)"
                }
                let resizable = candidate.resizable
                let record = WindowRecord(
                    id: id,
                    appName: app.localizedName ?? "Unknown app",
                    title: candidate.metadata.title ?? existing?.record.title ?? "",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    pid: appPID,
                    frame: windows[id]?.logicalFrame ?? currentFrame,
                    isResizable: resizable?.status == .success ? resizable?.value == true
                        : existing?.record.isResizable ?? false
                )
                if windows[id] != nil {
                    var replacedElement = false
                    if let currentElement = windows[id]?.element, !CFEqual(currentElement, element) {
                        if let observer = observers[appPID] {
                            unobserveWindow(currentElement, observer: observer)
                        }
                        windows[id]?.element = element
                        windows[id]?.observationComplete = false
                        replacedElement = true
                    }
                    if windows[id]?.windowNumber == nil {
                        windows[id]?.windowNumber = candidate.windowNumber
                    }
                    windows[id]?.record = record
                    windows[id]?.isAdmitted = true
                    windows[id]?.missedScans = 0
                    if let observer = observers[appPID],
                       replacedElement || windows[id]?.observationComplete == false {
                        windows[id]?.observationComplete = observeWindow(element, observer: observer)
                    }
                } else {
                    windows[id] = TrackedWindow(
                        element: element,
                        windowNumber: candidate.windowNumber,
                        record: record
                    )
                    if let observer = observers[appPID] {
                        windows[id]?.observationComplete = observeWindow(element, observer: observer)
                    }
                }
                seen.insert(id)
                result.append(record)
            }
            // Match owners against the current tracked windows, which may include
            // windows admitted earlier in this scan.
            let identities = identitySnapshot()
            if focusDiagnosticsEnabled {
                for candidate in candidates where candidate.isChild {
                    logger.notice("Scan pid=\(appPID, privacy: .public) child window=\(candidate.windowNumber.map(String.init) ?? "nil", privacy: .public) subrole=\(candidate.metadata.subrole ?? "nil", privacy: .public) modal=\(candidate.metadata.modal, privacy: .public) owner=\(candidate.ownerNumber.map(String.init) ?? "nil", privacy: .public)")
                }
            }
            for candidate in candidates where candidate.isChild && candidate.metadata.minimized != true {
                guard let owner = candidate.owner, let ownerPID = candidate.ownerPID,
                      let parentID = Self.trackedWindowID(pid: ownerPID, number: candidate.ownerNumber,
                                                          element: owner, in: identities),
                      windows[parentID]?.isAdmitted == true else { continue }
                if let previousID = Self.trackedWindowID(pid: appPID, number: candidate.windowNumber,
                                                         element: candidate.element, in: identities),
                   previousID != parentID {
                    dropTrackedWindow(id: previousID)
                }
                ownedWindows.append(OwnedWindow(element: candidate.element, parentID: parentID))
            }
        }
        self.ownedWindows = ownedWindows
        for id in Array(windows.keys) where !seen.contains(id) {
            guard let pid = windows[id]?.record.pid, plan.livePIDs.contains(pid) else {
                dropTrackedWindow(id: id)
                continue
            }
            windows[id]?.missedScans += 1
            if windows[id]?.missedScans ?? 0 >= 2 {
                dropTrackedWindow(id: id)
            } else if let tracked = windows[id], tracked.isAdmitted {
                result.append(tracked.record)
            }
        }
        if focusDiagnosticsEnabled { logger.notice("Scan admittedExternal=\(result.count, privacy: .public) registeredNative=\(self.nativeWindows.records.count, privacy: .public)") }
        return result + (managedBundleIdentifiers == nil ? nativeWindows.records : [])
    }

    /// Stops tracking a window that left the scan or became a child. A window
    /// Stagehand has moved is put back first; if its process is gone the record is
    /// useless, and if the write fails the record stays and the ID is reported as
    /// pending so a later pass can retry.
    private func dropTrackedWindow(id: String) {
        defer { windows.removeValue(forKey: id) }
        guard let tracked = windows[id],
              tracked.parking.restoreFrame != nil || tracked.originalFrame != nil else { return }
        let processAlive = NSRunningApplication(processIdentifier: tracked.record.pid).map { !$0.isTerminated } ?? false
        guard processAlive else {
            try? recoveryJournal.remove(windowID: id)
            interruptedWindowIDs.remove(id)
            return
        }
        if returnToOriginalFrame(windowID: id) == .failed, recoveryJournal.records[id] != nil {
            interruptedWindowIDs.insert(id)
            if focusDiagnosticsEnabled { logger.notice("Scan dropped=\(id, privacy: .public) restoreFailed=true recordKept=true") }
        }
    }

    public func record(windowID: String) -> WindowRecord? {
        nativeWindows.record(windowID: windowID) ?? windows[windowID]?.record
    }

    /// Moves a restored window without resizing it or requesting keyboard focus.
    @discardableResult
    public func setPosition(windowID: String, position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite else { return false }
        if nativeWindows.contains(windowID: windowID) {
            return nativeWindows.setPosition(windowID: windowID, position: position)
        }
        guard let tracked = windows[windowID], tracked.isAdmitted,
              !tracked.parking.isParked else { return false }
        guard captureOriginalFrame(windowID: windowID) else { return false }
        return moveWithOwnedWindows(windowID: windowID) {
            writePosition(tracked.element, position: position)
        }
    }

    /// Moves a window during ribbon motion without waiting for its app. Only the
    /// newest position is written; finishMotionWrites() waits for the last one.
    /// Returns false when the window cannot be moved, such as a parked window.
    @discardableResult
    public func setMotionPosition(windowID: String, position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite else { return false }
        if nativeWindows.contains(windowID: windowID) {
            return nativeWindows.setPosition(windowID: windowID, position: position)
        }
        guard let tracked = windows[windowID], tracked.isAdmitted,
              !tracked.parking.isParked else { return false }
        guard captureOriginalFrame(windowID: windowID) else { return false }
        // Attached dialogs move with their owner, which needs before-and-after reads.
        if ownedWindows.contains(where: { $0.parentID == windowID }) {
            return moveWithOwnedWindows(windowID: windowID) {
                writePosition(tracked.element, position: position)
            }
        }
        motionWriter.write(windowID: windowID, pid: tracked.record.pid, element: tracked.element, position: position)
        return true
    }

    /// Brings a window to the front without activating its app, so the window
    /// being switched to is on top from the first frame; activation follows later.
    public func raiseWithoutActivating(windowID: String) {
        guard !nativeWindows.contains(windowID: windowID),
              let tracked = windows[windowID], tracked.isAdmitted else { return }
        motionWriter.raise(pid: tracked.record.pid, element: tracked.element)
    }

    public func finishMotionWrites() async {
        await motionWriter.flush()
    }

    /// Since the last reset: positions requested, AX writes sent, the slowest write,
    /// and the longest any window, and `focusedWindowID`, went without moving.
    public func motionWriteStatistics(reset: Bool, focusedWindowID: String?) -> [String: String] {
        let statistics = motionWriter.statistics
        if reset { motionWriter.resetStatistics() }
        return ["motionPositionsRequested": String(statistics.requested),
                "motionWritesSent": String(statistics.sent),
                "slowestMotionWriteMilliseconds": String(statistics.slowestMilliseconds),
                "largestMotionGapMilliseconds": String(statistics.largestGapMilliseconds.values.max() ?? 0),
                "focusedMotionGapMilliseconds": String(focusedWindowID.flatMap {
                    statistics.largestGapMilliseconds[$0] } ?? 0)]
    }

    public func frame(windowID: String) -> CGRect? {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.frame(windowID: windowID) }
        guard let tracked = windows[windowID] else { return nil }
        return tracked.logicalFrame ?? readFrame(tracked.element)
    }

    /// Returns the WindowServer identity captured from Accessibility discovery.
    public func windowNumber(for windowID: String) -> CGWindowID? {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.windowNumber(for: windowID) }
        return windows[windowID]?.windowNumber
    }

    /// Reads the window's current physical frame, including its parking position.
    public func observedFrame(windowID: String) -> CGRect? {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.observedFrame(windowID: windowID) }
        guard let tracked = windows[windowID] else { return nil }
        return readFrame(tracked.element)
    }

    /// Some apps minimize or close a window without posting the matching AX
    /// notification. Report only confirmed states; a busy app returns nil.
    public func unavailability(windowID: String) -> WindowUnavailability? {
        if nativeWindows.contains(windowID: windowID) {
            return nativeWindows.record(windowID: windowID) == nil ? .closed : nil
        }
        guard let tracked = windows[windowID],
              let app = NSRunningApplication(processIdentifier: tracked.record.pid),
              !app.isTerminated else { return .closed }
        let minimized = copyAttribute(tracked.element, kAXMinimizedAttribute)
        switch Self.availability(minimizedStatus: minimized.error, minimized: minimized.value as? Bool) {
        case .closed: return .closed
        case .minimized: return .minimized
        case .available, .unknown: return nil
        }
    }

    enum TargetAvailability: Equatable, Sendable {
        case available, minimized, closed, unknown
    }

    /// Interprets one read of kAXMinimized. Only a successful read reports a
    /// state, and a destroyed element is closed. Any other error, including
    /// cannotComplete from an app that is busy, is unknown: callers must not
    /// treat it as minimized, because that turns a transient stall into a pause.
    nonisolated static func availability(minimizedStatus: AXError, minimized: Bool?) -> TargetAvailability {
        switch minimizedStatus {
        case .success: return minimized == true ? .minimized : .available
        case .invalidUIElement: return .closed
        default: return .unknown
        }
    }

    public func isParked(windowID: String) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.isParked(windowID: windowID) }
        return windows[windowID]?.parking.isParked == true
    }

    @discardableResult
    public func setFrame(windowID: String, frame: CGRect) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.setFrame(windowID: windowID, frame: frame) }
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              let tracked = windows[windowID] else { return false }
        guard captureOriginalFrame(windowID: windowID) else { return false }
        if tracked.parking.restoreFrame != nil {
            guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool != true else { return false }
            var parking = tracked.parking
            let success = parking.restore(to: frame, setFrame: { requested in
                self.moveWithOwnedWindows(windowID: windowID) {
                    self.writeFrame(tracked.element, frame: requested, resizeFirst: false)
                }
            },
                                          readFrame: { self.readFrame(tracked.element) })
            windows[windowID]?.parking = parking
            return success
        }
        return moveWithOwnedWindows(windowID: windowID) {
            writeFrame(tracked.element, frame: frame)
        }
    }

    /// Parks just this window, preserving other windows belonging to the same app.
    /// A thin side remnant avoids macOS's fully-offscreen clamp without changing Y.
    @discardableResult
    public func park(windowID: String, preferredSide: WindowParkingSide? = nil,
                     remnantWidth: CGFloat = WindowTuning.parkedRemnantWidth) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.park(windowID: windowID) }
        guard let tracked = windows[windowID] else { return false }
        motionWriter.settle(pid: tracked.record.pid)
        // AX can move a parked window back onscreen after our last frame read.
        // Check its physical position on every parking request.
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool != true else { return false }
        guard let currentFrame = readFrame(tracked.element) else { return false }
        guard captureOriginalFrame(windowID: windowID) else { return false }
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return false }
        let displays = screens.map { screen -> CGRect in
            CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        guard let screenIndex = displays.indices.max(by: {
            displays[$0].overlapArea(with: currentFrame) < displays[$1].overlapArea(with: currentFrame)
        }) else { return false }
        let visible = screens[screenIndex].visibleFrame
        let bounds = CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                            width: visible.width, height: visible.height)
        var parking = tracked.parking
        let success = parking.park(frame: currentFrame, bounds: bounds, displays: displays,
                                   preferredSide: preferredSide, remnantWidth: remnantWidth,
                                   setPosition: { position in
            let accepted = self.moveWithOwnedWindows(windowID: windowID) {
                self.writePosition(tracked.element, position: position)
            }
            if self.focusDiagnosticsEnabled { logger.notice("Parking write pid=\(tracked.record.pid, privacy: .public) requested=\(String(describing: position), privacy: .public) accepted=\(accepted, privacy: .public)") }
            return accepted
        },
                                   readFrame: { self.readFrame(tracked.element) })
        windows[windowID]?.parking = parking
        if focusDiagnosticsEnabled {
            // A parked window was verified by the write's readback; read back only a refusal.
            let actual = success ? "verified" : String(describing: self.readFrame(tracked.element))
            let minimized = success ? "false" : String(describing: self.attribute(tracked.element, kAXMinimizedAttribute) as? Bool)
            logger.notice("Parking pid=\(tracked.record.pid, privacy: .public) success=\(success, privacy: .public) remnantWidth=\(remnantWidth, privacy: .public) actual=\(actual, privacy: .public) minimized=\(minimized, privacy: .public) restorePending=\(parking.restoreFrame != nil, privacy: .public)")
        }
        return success
    }

    /// Unparks without requesting app activation. Focus is a separate operation.
    @discardableResult
    public func restore(windowID: String) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.restore(windowID: windowID) }
        guard let tracked = windows[windowID] else { return false }
        guard tracked.parking.restoreFrame != nil else { return true }
        // A user-minimized window remains theirs; Stagehand never reverses that action.
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool != true else { return false }
        var parking = tracked.parking
        let success = parking.restore(setFrame: { requested in
            self.moveWithOwnedWindows(windowID: windowID) {
                self.writeFrame(tracked.element, frame: requested, resizeFirst: false)
            }
        },
                                      readFrame: { self.readFrame(tracked.element) })
        windows[windowID]?.parking = parking
        if focusDiagnosticsEnabled {
            let actual = success ? "verified" : String(describing: self.readFrame(tracked.element))
            logger.notice("Parking restore pid=\(tracked.record.pid, privacy: .public) success=\(success, privacy: .public) actual=\(actual, privacy: .public) restorePending=\(parking.restoreFrame != nil, privacy: .public)")
        }
        return success
    }

    @discardableResult
    public func captureOriginalFrame(windowID: String) -> Bool {
        if nativeWindows.contains(windowID: windowID) {
            nativeWindows.captureOriginalFrame(windowID: windowID)
            return true
        }
        guard let tracked = windows[windowID] else { return false }
        guard tracked.originalFrame == nil else { return true }
        // A record for this window already on disk predates the current position,
        // which may be a parking spot left by an earlier pass or a dropped tracking.
        if let existing = recoveryJournal.records[windowID],
           let app = NSRunningApplication(processIdentifier: tracked.record.pid),
           existing.matchesProcess(bundleIdentifier: app.bundleIdentifier, pid: app.resolvedProcessIdentifier,
                                   launchDate: ProcessLaunchDate.launchDate(for: app)),
           existing.windowNumber == tracked.windowNumber {
            windows[windowID]?.originalFrame = existing.frame
            return true
        }
        guard let frame = readFrame(tracked.element) else { return false }
        // Without an on-disk record a crash would leave the window wherever the
        // ribbon or parking put it. Refuse to move it at all in that case.
        guard let record = Self.recoveryRecord(
            windowID: windowID, bundleIdentifier: tracked.record.bundleIdentifier, pid: tracked.record.pid,
            windowNumber: tracked.windowNumber,
            launchDate: ProcessLaunchDate.launchDate(pid: tracked.record.pid),
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            ownerLaunchDate: ProcessLaunchDate.launchDate(for: .current), frame: frame
        ) else {
            logger.error("Refused to manage window \(windowID, privacy: .public): no recovery record can be written")
            return false
        }
        do {
            try recoveryJournal.save(record)
        } catch {
            logger.error("Window recovery save failed for \(windowID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        windows[windowID]?.originalFrame = frame
        return true
    }

    /// The journal entry that lets a later process put the window back. Nil when
    /// any identity is missing, which means the window must not be moved.
    nonisolated static func recoveryRecord(
        windowID: String, bundleIdentifier: String, pid: pid_t, windowNumber: CGWindowID?,
        launchDate: Date?, ownerPID: pid_t, ownerLaunchDate: Date?, frame: CGRect
    ) -> WindowRecoveryRecord? {
        guard let windowNumber, let launchDate, let ownerLaunchDate, !bundleIdentifier.isEmpty else { return nil }
        let record = WindowRecoveryRecord(
            windowID: windowID, bundleIdentifier: bundleIdentifier, pid: pid, launchDate: launchDate,
            ownerPID: ownerPID, ownerLaunchDate: ownerLaunchDate, windowNumber: windowNumber, frame: frame
        )
        return record.isValid ? record : nil
    }

    /// Call on pause/quit, before releasing tracking, to return windows to their original positions.
    /// A window that cannot be put back keeps its journal record and is reported through
    /// `pendingRecoveryWindowIDs`, so the model can warn and a later pass can retry.
    public func restoreAll() {
        nativeWindows.restoreAll()
        var failed = Set<String>()
        for id in Array(windows.keys) where returnToOriginalFrame(windowID: id) == .failed {
            failed.insert(id)
        }
        // A busy app answers a later request; a bounded retry covers the common
        // case without holding pause or quit for long.
        for delay in WindowTuning.restoreRetryDelaysMilliseconds where !failed.isEmpty {
            MainThreadActivity.during("restoreAll wait") { Thread.sleep(forTimeInterval: Double(delay) / 1_000) }
            failed = failed.filter { returnToOriginalFrame(windowID: $0) == .failed }
        }
        for id in failed where recoveryJournal.records[id] != nil {
            interruptedWindowIDs.insert(id)
        }
    }

    private enum RestoreOutcome {
        case restored
        /// Nothing to do now: the window is in native fullscreen, which hands it back
        /// to macOS. Its record stays for the next recovery pass without a warning.
        case deferred
        case failed
    }

    /// Unparks the window and writes the frame Stagehand found it at. On success the
    /// window no longer needs recovery, so its record is removed.
    private func returnToOriginalFrame(windowID id: String) -> RestoreOutcome {
        guard let tracked = windows[id] else { return .restored }
        guard tracked.parking.restoreFrame != nil || tracked.originalFrame != nil else { return .restored }
        guard attribute(tracked.element, "AXFullScreen") as? Bool != true else { return .deferred }
        if attribute(tracked.element, kAXMinimizedAttribute) as? Bool == true {
            // restore() never reverses a user's minimize, but the frame can often be
            // written behind the Dock tile. Otherwise wait for de-miniaturization.
            guard let target = tracked.originalFrame ?? tracked.parking.restoreFrame else { return .restored }
            guard moveWithOwnedWindows(windowID: id, move: { writeFrame(tracked.element, frame: target) }) else {
                if recoveryJournal.records[id] != nil {
                    interruptedWindowIDs.insert(id)
                    deferredRecoveryWindowIDs.insert(id)
                }
                return .deferred
            }
            forgetRecovery(windowID: id)
            return .restored
        }
        // Do not discard the original frame if unparking failed.
        // A later recovery attempt must still know where the window started.
        guard restore(windowID: id) else { return .failed }
        if let originalFrame = tracked.originalFrame {
            guard moveWithOwnedWindows(windowID: id, move: {
                writeFrame(tracked.element, frame: originalFrame)
            }) else { return .failed }
            windows[id]?.originalFrame = nil
            try? recoveryJournal.remove(windowID: id)
        }
        interruptedWindowIDs.remove(id)
        return .restored
    }

    /// Accessibility calls to other processes run here so a busy app blocks
    /// neither ribbon motion nor the event taps.
    nonisolated static let accessibilityQueue = DispatchQueue(label: "app.stagehand.focus-accessibility", qos: .userInteractive)

    /// A panel from a process with no Dock presence, such as the system's
    /// authentication prompt, is placed by macOS at the screen's center. The
    /// ribbon keeps its focused window at the left, so the panel lands beside
    /// it. Move the panel over the window the user is working in; its key
    /// status is left to macOS. Only a macOS agent's panel above the modal
    /// level is moved: a launcher or a menu bar utility also activates without
    /// a Dock tile, and its window stays. Its AX subrole is no help, since the
    /// authentication panel reports a standard window. Runs on its own queue
    /// so a slow process never delays focus work.
    public func centerCompanionPanel(pid: pid_t, over anchor: CGRect, within bounds: CGRect) {
        let appElement = AXUIElementCreateApplication(pid)
        let diagnostics = focusDiagnosticsEnabled
        Self.companionQueue.async { [self] in
            // The panel can be created a moment after its process activates.
            for attempt in 0..<2 {
                let focused = copyAttribute(appElement, kAXFocusedWindowAttribute)
                if focused.error == .cannotComplete || focused.error == .apiDisabled {
                    if diagnostics { logger.notice("Companion panel pid=\(pid, privacy: .public) unavailable status=\(focused.error.rawValue, privacy: .public)") }
                    return
                }
                guard let value = focused.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    if attempt == 0 { usleep(50_000); continue }
                    if diagnostics { logger.notice("Companion panel pid=\(pid, privacy: .public) none status=\(focused.error.rawValue, privacy: .public)") }
                    return
                }
                let panel = unsafeDowncast(value, to: AXUIElement.self)
                guard let frame = readFrame(panel), frame.width > 1, frame.height > 1 else {
                    if diagnostics { logger.notice("Companion panel pid=\(pid, privacy: .public) no frame") }
                    return
                }
                // WindowServer lists the panel a moment after its process activates.
                var level = Self.windowLevel(pid: pid, frame: frame)
                if level == nil { usleep(50_000); level = Self.windowLevel(pid: pid, frame: frame) }
                guard Self.isCompanionPanel(level: level) else {
                    if diagnostics { logger.notice("Companion panel pid=\(pid, privacy: .public) skipped level=\(level.map(String.init) ?? "nil", privacy: .public) frame=\(String(describing: frame), privacy: .public)") }
                    return
                }
                let origin = Self.companionPanelOrigin(size: frame.size, over: anchor, within: bounds)
                var point = origin
                var status = AXError.success
                if !Self.samePosition(origin, frame.origin), let position = AXValueCreate(.cgPoint, &point) {
                    status = AXUIElementSetAttributeValue(panel, kAXPositionAttribute as CFString, position)
                }
                if diagnostics {
                    logger.notice("Companion panel pid=\(pid, privacy: .public) level=\(level ?? -1, privacy: .public) from=\(String(describing: frame.origin), privacy: .public) to=\(String(describing: origin), privacy: .public) status=\(status.rawValue, privacy: .public)")
                }
                return
            }
        }
    }

    nonisolated private static let companionQueue = DispatchQueue(label: "app.stagehand.companion-panel", qos: .userInteractive)

    /// A macOS agent with no Dock tile: authentication, Gatekeeper, alerts,
    /// permission prompts. Its panels serve whatever the user is working in.
    nonisolated static func isSystemAgent(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy != .regular && app.bundleURL?.path.hasPrefix("/System/") == true
    }

    /// WindowServer draws an agent's prompt above ordinary and modal windows;
    /// the authentication panel sits at level 1000. A window at or below the
    /// modal level is the agent's own interface and stays where it is.
    nonisolated static func isCompanionPanel(level: Int?) -> Bool {
        guard let level else { return false }
        return level > Int(CGWindowLevelForKey(.modalPanelWindow))
    }

    /// The WindowServer level of the process's on-screen window at `frame`.
    /// The private window-number lookup answers nil for an agent's secure
    /// panel, so the match is by owner and bounds.
    nonisolated private static func windowLevel(pid: pid_t, frame: CGRect) -> Int? {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in info where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  abs(bounds.minX - frame.minX) <= 1, abs(bounds.minY - frame.minY) <= 1,
                  abs(bounds.width - frame.width) <= 1, abs(bounds.height - frame.height) <= 1 else { continue }
            return window[kCGWindowLayer as String] as? Int
        }
        return nil
    }

    /// The origin that centers a panel of `size` on `anchor` without leaving `bounds`.
    nonisolated static func companionPanelOrigin(size: CGSize, over anchor: CGRect, within bounds: CGRect) -> CGPoint {
        let x = min(max(anchor.midX - size.width / 2, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        let y = min(max(anchor.midY - size.height / 2, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    public func focusedWindowID() -> String? {
        let id = NSApp?.isActive == true
            ? nativeWindows.focusedWindowID
            : resolveFocus(readFocus(systemElement: systemElement, frontmostPID: Self.activeFrontmostPID(),
                                     in: identitySnapshot()))
        lastObservedFocusedWindowID = id
        return id
    }

    private enum FocusRead: Sendable {
        case none
        case own
        case external(String?)
    }

    private func resolveFocus(_ read: FocusRead) -> String? {
        switch read {
        case .none: nil
        case .own: nativeWindows.focusedWindowID
        case .external(let id): id
        }
    }

    private static func activeFrontmostPID() -> pid_t? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.isActive else { return nil }
        return frontmost.resolvedProcessIdentifier
    }

    /// The AX part of focusedWindowID(). It waits on the focused app, so it may run off the main thread.
    nonisolated private func readFocus(systemElement: AXUIElement, frontmostPID: pid_t?,
                                       in snapshot: IdentitySnapshot) -> FocusRead {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let result = copyAttribute(systemElement, kAXFocusedApplicationAttribute)
        let focusedApp: AXUIElement
        if let value = result.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let reportedApp = unsafeDowncast(value, to: AXUIElement.self)
            var reportedPID: pid_t = 0
            // Global AX names a process that is not the active frontmost app:
            // Stagehand after its Start menu closes, or a non-activating panel
            // such as Raycast. The frontmost app's focused window is the one
            // the keyboard returns to.
            if AXUIElementGetPid(reportedApp, &reportedPID) == .success,
               let frontmostPID, frontmostPID != reportedPID {
                focusedApp = AXUIElementCreateApplication(frontmostPID)
            } else {
                focusedApp = reportedApp
            }
        } else if result.error == .noValue, let frontmostPID {
            // Match focus()'s narrow fallback. A remembered window in a background
            // app is not evidence of keyboard focus.
            focusedApp = AXUIElementCreateApplication(frontmostPID)
        } else {
            return .none
        }
        var focusedPID: pid_t = 0
        if AXUIElementGetPid(focusedApp, &focusedPID) == .success, focusedPID == ownPID { return .own }
        guard let focusedWindow = elementAttribute(focusedApp, kAXFocusedWindowAttribute) else { return .none }
        return .external(trackedWindowID(matching: focusedWindow, in: snapshot))
    }

    /// Reports focus changes macOS made, such as a click or Command-Tab. The newly
    /// active app answers AX only once its run loop is free, which can take hundreds
    /// of milliseconds, so the read runs off the main thread where the input taps
    /// live. Notifications arriving during a read coalesce into one more read.
    private func reportCurrentFocus() {
        guard onFocusedWindowChange != nil, wantsObservedFocus?() ?? true else { return }
        if NSApp?.isActive == true {
            if let id = nativeWindows.focusedWindowID { onFocusedWindowChange?(id) }
            return
        }
        guard !focusReportInFlight else {
            focusReportPending = true
            return
        }
        focusReportInFlight = true
        let request = FocusReadRequest(system: self, systemElement: systemElement,
                                       frontmostPID: Self.activeFrontmostPID(), snapshot: identitySnapshot())
        Self.focusObservationQueue.async {
            let read = request.system.readFocus(systemElement: request.systemElement,
                                                frontmostPID: request.frontmostPID, in: request.snapshot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { request.system.deliverFocusReport(read) }
            }
        }
    }

    private struct FocusReadRequest: @unchecked Sendable {
        let system: WindowSystem
        let systemElement: AXUIElement
        let frontmostPID: pid_t?
        let snapshot: IdentitySnapshot
    }

    private func deliverFocusReport(_ read: FocusRead) {
        focusReportInFlight = false
        if focusReportPending {
            focusReportPending = false
            reportCurrentFocus()
            return
        }
        guard started, let id = resolveFocus(read) else { return }
        lastObservedFocusedWindowID = id
        guard wantsObservedFocus?() ?? true else { return }
        if nativeWindows.contains(windowID: id) {
            onFocusedWindowChange?(id)
            return
        }
        // An app's delayed focus notification can arrive after it lost activation.
        // Resolve actual focus and independently reject background remembered windows.
        guard let tracked = windows[id], tracked.isAdmitted,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isActive, frontmost.resolvedProcessIdentifier == tracked.record.pid else { return }
        onFocusedWindowChange?(id)
    }

    /// Separate from accessibilityQueue so a slow observation never delays a focus request.
    nonisolated private static let focusObservationQueue = DispatchQueue(label: "app.stagehand.focus-observation",
                                                                         qos: .userInitiated)

    /// Returns success only after the target application and its exact window own focus.
    /// Callers must not report a successful transition before this confirmation.
    public func focus(windowID: String) async -> Bool {
        lastFocusReport = nil
        guard !Task.isCancelled else { return false }
        if nativeWindows.contains(windowID: windowID) {
            let began = ContinuousClock.now
            let success = await nativeWindows.focus(windowID: windowID)
            if success { lastObservedFocusedWindowID = windowID }
            if focusDiagnosticsEnabled {
                let elapsed = began.duration(to: .now)
                lastFocusReport = WindowFocusReport(targetPID: ProcessInfo.processInfo.processIdentifier,
                                                    outcome: success ? .focused : .timedOut,
                                                    elapsedMilliseconds: elapsed.wholeMilliseconds,
                                                    operations: [.init("nativeWindowFocus", accepted: success)],
                                                    initialObservation: nil, observations: [],
                                                    nativeObservation: nativeWindows.focusObservation(windowID: windowID))
            }
            return success
        }
        guard let tracked = windows[windowID],
              let app = NSRunningApplication(processIdentifier: tracked.record.pid),
              !app.isTerminated else {
            if focusDiagnosticsEnabled { lastFocusReport = WindowFocusReport(targetPID: windows[windowID]?.record.pid,
                                                outcome: .unavailable, elapsedMilliseconds: 0,
                                                operations: [.init("resolveTarget", accepted: false)],
                                                initialObservation: nil, observations: []) }
            return false
        }
        // Only a confirmed minimize or a destroyed element stops the focus here, so
        // the caller's unavailability check drops the window without pausing. A
        // busy app answers this read with cannotComplete, as Chrome does for its
        // remaining windows just after one closes; that is not a minimized window,
        // and the attempt below already waits for the app to answer.
        let minimizedRead = copyAttribute(tracked.element, kAXMinimizedAttribute)
        let availability = Self.availability(minimizedStatus: minimizedRead.error,
                                             minimized: minimizedRead.value as? Bool)
        guard availability == .available || availability == .unknown else {
            if focusDiagnosticsEnabled {
                lastFocusReport = WindowFocusReport(
                    targetPID: tracked.record.pid,
                    outcome: .unavailable,
                    elapsedMilliseconds: 0,
                    operations: [.init(availability == .closed ? "targetClosed" : "targetMinimized", accepted: false)],
                    initialObservation: nil,
                    observations: []
                )
            }
            return false
        }
        guard !Task.isCancelled else { return false }
        let restoreBegan = ContinuousClock.now
        let restoration = await Self.restoreForFocus(
            restore: { self.restore(windowID: windowID) },
            unavailable: { self.unavailability(windowID: windowID) != nil }
        )
        guard restoration.restored else {
            if focusDiagnosticsEnabled {
                let elapsed = restoreBegan.duration(to: .now)
                lastFocusReport = WindowFocusReport(targetPID: tracked.record.pid, outcome: .unavailable,
                                                    elapsedMilliseconds: elapsed.wholeMilliseconds,
                                                    operations: Array(repeating: .init("restoreTarget", accepted: false),
                                                                      count: restoration.attempts),
                                                    initialObservation: nil, observations: [])
            }
            return false
        }
        let driver = FocusDriver(system: self, tracked: tracked, app: app, recordsDiagnostics: focusDiagnosticsEnabled)
        let report = await WindowFocusAttempt.run(driver: driver, recordDiagnostics: focusDiagnosticsEnabled)
        if focusDiagnosticsEnabled { lastFocusReport = report }
        if report.outcome == .focused { lastObservedFocusedWindowID = windowID }
        return report.outcome == .focused
    }

    /// Runs one focus attempt's Accessibility calls on a background queue. A busy
    /// target app answers each call only when its run loop is free; waiting on the
    /// main thread would stall ribbon motion, gestures, and the keyboard tap.
    /// AppKit activation stays on the main actor, in the original order.
    @MainActor
    private final class FocusDriver: WindowFocusDriving {
        private struct Context: @unchecked Sendable {
            let system: WindowSystem
            let target: AXUIElement
            let targetID: String
            let targetPID: pid_t
            let appElement: AXUIElement
            let systemElement: AXUIElement
            let identities: IdentitySnapshot
        }

        private struct Step: Sendable {
            let name: String
            let status: Int32?
            var accepted: Bool? = nil
        }

        let targetPID: Int32
        private let context: Context
        private let app: NSRunningApplication
        private let start = ContinuousClock.now
        private let recordsDiagnostics: Bool
        private var canSetFocusedWindow = false
        private var focusBelongsToOwnedWindow = false
        private(set) var targetUnresponsive = false

        init(system: WindowSystem, tracked: TrackedWindow, app: NSRunningApplication, recordsDiagnostics: Bool) {
            targetPID = tracked.record.pid
            context = Context(system: system, target: tracked.element, targetID: tracked.record.id,
                              targetPID: tracked.record.pid,
                              appElement: AXUIElementCreateApplication(tracked.record.pid),
                              systemElement: system.systemElement, identities: system.identitySnapshot())
            self.app = app
            self.recordsDiagnostics = recordsDiagnostics
        }

        var elapsedMilliseconds: Int {
            start.duration(to: .now).wholeMilliseconds
        }

        func prepare() async -> [WindowFocusReport.Operation] {
            let context = self.context
            let (owned, settable) = await Self.accessibility { () -> (Bool, Step?) in
                // Focus already inside the target's sheet or dialog needs only activation.
                if let focused = context.system.elementAttribute(context.appElement, kAXFocusedWindowAttribute) {
                    let isSheet = context.system.attribute(focused, kAXRoleAttribute) as? String == kAXSheetRole
                    let owned = context.system.trackedWindowID(matching: focused, in: context.identities) == context.targetID
                        && (isSheet || context.system.directTrackedWindowID(matching: focused, in: context.identities) == nil)
                    if owned { return (true, nil) }
                }
                var writable: DarwinBoolean = false
                let status = AXUIElementIsAttributeSettable(context.appElement, kAXFocusedWindowAttribute as CFString, &writable)
                return (false, Step(name: "isFocusedWindowSettable", status: status.rawValue, accepted: writable.boolValue))
            }
            focusBelongsToOwnedWindow = owned
            canSetFocusedWindow = settable?.accepted == true
            var operations = record(settable.map { [$0] } ?? [])
            if app.isHidden { operations += record([Step(name: "unhide", status: nil, accepted: app.unhide())]) }
            if !owned {
                let canSetFocusedWindow = self.canSetFocusedWindow
                operations += record(await Self.accessibility {
                    var steps = [
                        Step(name: "raise", status: AXUIElementPerformAction(context.target, kAXRaiseAction as CFString).rawValue),
                        Step(name: "setMain", status: AXUIElementSetAttributeValue(
                            context.target, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue)
                    ]
                    if canSetFocusedWindow {
                        steps.append(Step(name: "setFocusedWindow", status: AXUIElementSetAttributeValue(
                            context.appElement, kAXFocusedWindowAttribute as CFString, context.target).rawValue))
                    }
                    steps.append(Step(name: "setFrontmost", status: AXUIElementSetAttributeValue(
                        context.appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue).rawValue))
                    return steps
                })
            }
            let activated = MainThreadActivity.during("activate pid=\(targetPID)") { app.activate(options: []) }
            operations += record([Step(name: "activate", status: nil, accepted: activated)])
            return operations
        }

        func requestFocus(attempt: Int) async -> [WindowFocusReport.Operation] {
            guard !focusBelongsToOwnedWindow else { return [] }
            let context = self.context
            let canSetFocusedWindow = self.canSetFocusedWindow
            return record(await Self.accessibility {
                var steps: [Step] = []
                if attempt % 4 == 0 {
                    steps.append(Step(name: "raise", status: AXUIElementPerformAction(
                        context.target, kAXRaiseAction as CFString).rawValue))
                    if canSetFocusedWindow {
                        steps.append(Step(name: "setFocusedWindow", status: AXUIElementSetAttributeValue(
                            context.appElement, kAXFocusedWindowAttribute as CFString, context.target).rawValue))
                    }
                }
                steps.append(Step(name: "setFocused", status: AXUIElementSetAttributeValue(
                    context.target, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue))
                return steps
            })
        }

        private func record(_ steps: [Step]) -> [WindowFocusReport.Operation] {
            if steps.contains(where: { $0.status == AXError.cannotComplete.rawValue }) { targetUnresponsive = true }
            guard recordsDiagnostics else { return [] }
            return steps.map { .init($0.name, accessibilityStatus: $0.status, accepted: $0.accepted) }
        }

        private struct AccessibilityFocus: Sendable {
            var focusedPID: pid_t?
            var applicationStatus: Int32
            var windowStatus: Int32?
            var matches = false
            var directStatus: Int32
            var directMatches = false
        }

        func observe() async -> WindowFocusReport.Observation {
            // Focus is confirmed only after AppKit reports the target active. Until
            // then AX reads cannot confirm it, and they wait while the app is busy.
            guard app.isActive else {
                return WindowFocusReport.Observation(
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.resolvedProcessIdentifier,
                    focusedApplicationPID: nil,
                    focusedApplicationStatus: nil,
                    focusedWindowStatus: nil,
                    directFocusedWindowStatus: nil,
                    directTargetWindowMatches: false,
                    targetApplicationActive: false,
                    targetWindowMatches: false
                )
            }
            let context = self.context
            let targetFrontmost = NSWorkspace.shared.frontmostApplication?.resolvedProcessIdentifier == context.targetPID
            let focus = await Self.accessibility { () -> AccessibilityFocus in
                let system = context.system
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let application = system.copyAttribute(context.systemElement, kAXFocusedApplicationAttribute)
                var result = AccessibilityFocus(applicationStatus: application.error.rawValue,
                                                directStatus: AXError.attributeUnsupported.rawValue)
                if let value = application.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let focusedApp = unsafeDowncast(value, to: AXUIElement.self)
                    var pid: pid_t = 0
                    if AXUIElementGetPid(focusedApp, &pid) == .success { result.focusedPID = pid }
                    // Stagehand's own windows are never the target of this driver.
                    if result.focusedPID != ownPID {
                        let window = system.copyAttribute(focusedApp, kAXFocusedWindowAttribute)
                        result.windowStatus = window.error.rawValue
                        if let focusedWindow = window.value, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                            result.matches = system.trackedWindowID(
                                matching: unsafeDowncast(focusedWindow, to: AXUIElement.self), in: context.identities
                            ) == context.targetID
                        }
                    }
                }
                // The direct read can confirm focus only while the target is frontmost.
                if targetFrontmost, WindowFocusReport.Observation.readsTargetDirectly(
                    focusedApplicationPID: result.focusedPID, focusedApplicationStatus: result.applicationStatus,
                    focusedWindowStatus: result.windowStatus, targetPID: context.targetPID
                ) {
                    let direct = system.copyAttribute(context.appElement, kAXFocusedWindowAttribute)
                    result.directStatus = direct.error.rawValue
                    result.directMatches = direct.value.map {
                        CFGetTypeID($0) == AXUIElementGetTypeID() && system.trackedWindowID(
                            matching: unsafeDowncast($0, to: AXUIElement.self), in: context.identities
                        ) == context.targetID
                    } ?? false
                }
                return result
            }
            return WindowFocusReport.Observation(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.resolvedProcessIdentifier,
                focusedApplicationPID: focus.focusedPID,
                focusedApplicationStatus: focus.applicationStatus,
                focusedWindowStatus: focus.windowStatus,
                directFocusedWindowStatus: focus.directStatus,
                directTargetWindowMatches: focus.directMatches,
                targetApplicationActive: app.isActive,
                targetWindowMatches: focus.matches
            )
        }

        func wait(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

        private static var queue: DispatchQueue { WindowSystem.accessibilityQueue }

        private static func accessibility<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work()) }
            }
        }
    }

    private func observeApplication(_ element: AXUIElement, pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, changedWindow, notification, context in
            guard let context else { return }
            // This observer is attached exclusively to the main run loop.
            MainActor.assumeIsolated {
                let owner = Unmanaged<WindowSystem>.fromOpaque(context).takeUnretainedValue()
                guard owner.started else { return }
                let name = notification as String
                MainThreadActivity.during("axCallback \(name) pid=\(WindowSystem.pid(of: changedWindow))") {
                    if owner.focusDiagnosticsEnabled {
                        var pid: pid_t = 0
                        _ = AXUIElementGetPid(changedWindow, &pid)
                        logger.notice("Discovery t=\(ProcessInfo.processInfo.systemUptime, privacy: .public) AX=\(name, privacy: .public) pid=\(pid, privacy: .public)")
                    }
                    if let availabilityChange = windowAvailabilityChange(for: name),
                       let id = owner.directTrackedWindowID(matching: changedWindow) {
                        owner.trackedStateGeneration &+= 1
                        switch availabilityChange {
                        case .destroyed:
                            owner.windows.removeValue(forKey: id)
                            try? owner.recoveryJournal.remove(windowID: id)
                            owner.interruptedWindowIDs.remove(id)
                            owner.onWindowDestroyed?(id)
                        case .minimized:
                            owner.onWindowMiniaturized?(id)
                            return
                        case .restored:
                            owner.completeDeferredRecovery(windowID: id)
                            owner.onWindowDeminiaturized?(id)
                            return
                        }
                    }
                    if name == kAXTitleChangedNotification,
                       let id = owner.directTrackedWindowID(matching: changedWindow),
                       let tracked = owner.windows[id], tracked.isAdmitted {
                        // Terminals and browsers retitle often. Update the one record
                        // instead of rescanning every window of every app.
                        if let title = owner.attribute(changedWindow, kAXTitleAttribute) as? String,
                           title != tracked.record.title {
                            owner.windows[id]?.record = tracked.record.withTitle(title)
                            owner.onTitleChange?(id, title)
                        }
                        return
                    }
                    if name == kAXFocusedWindowChangedNotification { owner.reportCurrentFocus() }
                    if owner.onFrameChange != nil,
                       name == kAXMovedNotification || name == kAXResizedNotification,
                       owner.wantsFrameChange?() ?? true,
                       let id = owner.directTrackedWindowID(matching: changedWindow),
                       let frame = owner.readFrame(changedWindow) {
                        owner.onFrameChange?(id, frame)
                    }
                    owner.onChange?()
                }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        observers[pid] = observer
        applicationObservations[pid] = ApplicationObservation()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        scheduleApplicationRegistration(element: element, pid: pid)
        for id in Array(windows.keys) where windows[id]?.record.pid == pid {
            guard let element = windows[id]?.element else { continue }
            windows[id]?.observationComplete = observeWindow(element, observer: observer)
        }
    }

    /// Registers on the app's own queue and applies the result on the main actor.
    /// Returns whether a subscription is still pending; false also when the
    /// observer was replaced or removed while the registration ran.
    private func registerApplicationNotifications(element: AXUIElement, pid: pid_t) async -> Bool {
        guard let observer = observers[pid], let pending = applicationObservations[pid]?.pending,
              !pending.isEmpty else { return false }
        let queue = observationQueues[pid] ?? DispatchQueue(label: "app.stagehand.observation.\(pid)",
                                                            qos: .userInitiated)
        observationQueues[pid] = queue
        let request = ObservationRequest(observer: observer, element: element,
                                         context: Unmanaged.passUnretained(self).toOpaque())
        let diagnostics = focusDiagnosticsEnabled
        let statuses = await withCheckedContinuation { continuation in
            queue.async {
                var statuses: [String: AXError] = [:]
                for name in pending {
                    let status = AXObserverAddNotification(request.observer, request.element,
                                                           name as CFString, request.context)
                    if diagnostics { logger.notice("Discovery observe pid=\(pid, privacy: .public) AX=\(name, privacy: .public) status=\(status.rawValue, privacy: .public)") }
                    statuses[name] = status
                }
                continuation.resume(returning: statuses)
            }
        }
        // A pause or an app relaunch tore this observer down while the
        // registration ran. Its run-loop source is gone, so nothing it
        // subscribed can be delivered.
        guard observers[pid] === observer, var registration = applicationObservations[pid] else { return false }
        let retry = registration.register { statuses[$0] ?? .cannotComplete }
        applicationObservations[pid] = registration
        return retry
    }

    private struct ObservationRequest: @unchecked Sendable {
        let observer: AXObserver
        let element: AXUIElement
        let context: UnsafeMutableRawPointer
    }

    /// Registers once right away, then retries an app that keeps answering
    /// .cannotComplete for as long as it runs, but at a widening interval, and
    /// requests a rescan only when a subscription actually registered.
    /// Rescanning on every failed attempt kept the whole system scanning every
    /// few seconds for one unresponsive app.
    private func scheduleApplicationRegistration(element: AXUIElement, pid: pid_t) {
        let delays = WindowTuning.observationRetryDelaysMilliseconds
        observationRetries[pid]?.cancel()
        observationRetries[pid] = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                if attempt > 0 {
                    let delay = delays[min(attempt - 1, delays.count - 1)]
                    do { try await Task.sleep(for: .milliseconds(delay)) }
                    catch { return }
                }
                guard let self, self.started, !Task.isCancelled else { return }
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    self.removeObserver(pid: pid)
                    return
                }
                let pendingBefore = self.applicationObservations[pid]?.pending
                let retry = await self.registerApplicationNotifications(element: element, pid: pid)
                guard !Task.isCancelled else { return }
                // Discover windows that appeared before registration succeeded.
                // The scan that created the observer no longer waits for the
                // first registration, so this covers the first attempt too.
                if self.applicationObservations[pid]?.pending != pendingBefore { self.onChange?() }
                if !retry { break }
                attempt += 1
            }
            self?.observationRetries.removeValue(forKey: pid)
        }
    }

    private func startApplicationInventory() {
        applicationInventoryTask?.cancel()
        let initialVisibleWindows = onScreenWindows()
        lastApplicationInventory = applicationInventory(
            eligible: eligibleApplications(from: NSWorkspace.shared.runningApplications,
                                           accessoryPIDs: Set(initialVisibleWindows.map(\.pid))),
            visibleWindows: initialVisibleWindows
        )
        applicationInventoryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(WindowTuning.applicationInventoryPollSeconds)) }
                catch { return }
                guard let self, self.started, !Task.isCancelled else { return }
                if self.inventoryPaused { continue }
                let visibleWindows = self.onScreenWindows()
                let eligible = self.eligibleApplications(from: NSWorkspace.shared.runningApplications,
                                                         accessoryPIDs: Set(visibleWindows.map(\.pid)))
                var scheduled = false
                for app in eligible where self.observers[app.resolvedProcessIdentifier] == nil {
                    scheduled = self.scheduleDiscovery(for: app) || scheduled
                }
                let inventory = self.applicationInventory(eligible: eligible, visibleWindows: visibleWindows)
                let changed = inventory != self.lastApplicationInventory
                self.lastApplicationInventory = inventory
                if scheduled || changed { self.onChange?() }
            }
        }
    }

    private func applicationInventory(
        eligible: [NSRunningApplication],
        visibleWindows: [VisibleWindow]
    ) -> ApplicationInventory {
        ApplicationInventory(
            applicationPIDs: Set(eligible.map(\.resolvedProcessIdentifier)),
            visibleWindows: Set(visibleWindows.map {
                VisibleWindowIdentity(pid: $0.pid, windowNumber: $0.windowNumber)
            })
        )
    }

    @discardableResult
    private func scheduleDiscovery(for app: NSRunningApplication) -> Bool {
        let pid = app.resolvedProcessIdentifier
        guard !app.isTerminated, pid != ProcessInfo.processInfo.processIdentifier,
              !windows.values.contains(where: { $0.record.pid == pid && $0.isAdmitted }) else { return false }
        return launchDiscovery.schedule(pid: pid) { [weak self] in
            guard let self, self.started,
                  let runningApp = NSRunningApplication(processIdentifier: pid), !runningApp.isTerminated,
                  !self.windows.values.contains(where: { $0.record.pid == pid && $0.isAdmitted }) else {
                return false
            }
            self.onChange?()
            return true
        }
    }

    private func eligibleApplications(
        from applications: [NSRunningApplication],
        accessoryPIDs: Set<pid_t>
    ) -> [NSRunningApplication] {
        applications.filter { app in
            let pid = app.resolvedProcessIdentifier
            return pid > 0 && pid != ProcessInfo.processInfo.processIdentifier &&
            managedBundleIdentifiers.map { allowed in app.bundleIdentifier.map(allowed.contains) ?? false } ?? true &&
            canManageWindows(
                for: app.activationPolicy,
                hasVisibleOrTrackedWindow: accessoryPIDs.contains(pid)
            ) && !app.isTerminated
        }
    }

    private func removeObserver(pid: pid_t) {
        launchDiscovery.cancel(pid: pid)
        observationRetries.removeValue(forKey: pid)?.cancel()
        observationQueues.removeValue(forKey: pid)
        let registration = applicationObservations.removeValue(forKey: pid)
        if let observer = observers.removeValue(forKey: pid) {
            // Unsubscribe before dropping the source so a late delivery cannot
            // reach a callback whose context no longer exists.
            let appElement = AXUIElementCreateApplication(pid)
            MainThreadActivity.during("unobserve pid=\(pid)") {
                for name in registration?.registered ?? [] {
                    AXObserverRemoveNotification(observer, appElement, name as CFString)
                }
                for tracked in windows.values where tracked.record.pid == pid {
                    unobserveWindow(tracked.element, observer: observer)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        for id in Array(windows.keys) where windows[id]?.record.pid == pid {
            windows[id]?.observationComplete = false
        }
    }

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
        kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification
    ]

    private func observeWindow(_ element: AXUIElement, observer: AXObserver) -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var complete = true
        for name in Self.windowNotifications {
            let status = MainThreadActivity.during("observe \(name) pid=\(Self.pid(of: element))") {
                AXObserverAddNotification(observer, element, name as CFString, context)
            }
            if status != .success, status != .notificationAlreadyRegistered { complete = false }
        }
        return complete
    }

    /// Removal of a notification that was never added, or of a dead element, fails
    /// harmlessly; the point is that no live subscription outlasts its element.
    private func unobserveWindow(_ element: AXUIElement, observer: AXObserver) {
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
    }

    nonisolated private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        copyAttribute(element, name).value
    }

    nonisolated private func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = MainThreadActivity.during("read \(name) pid=\(Self.pid(of: element))") {
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
        }
        return (error == .success ? value : nil, error)
    }

    /// For main-thread activity labels.
    nonisolated static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }

    private typealias VisibleWindow = (pid: pid_t, windowNumber: CGWindowID, frame: CGRect, isModalPanel: Bool)

    /// Normal-level windows on the current Desktop. App-modal alerts sit at the
    /// modal panel level instead.
    private func onScreenWindows(includingModalPanels: Bool = false) -> [VisibleWindow] {
        guard let info = MainThreadActivity.during("windowList", {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        }) as? [[String: Any]] else { return [] }
        let modalPanelLevel = Int(CGWindowLevelForKey(.modalPanelWindow))
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = window[kCGWindowNumber as String] as? NSNumber,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0 || includingModalPanels && layer == modalPanelLevel,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (pid.int32Value, windowNumber.uint32Value, frame, layer != 0)
        }
    }

    nonisolated private func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        guard let axWindowID = AccessibilityWindowNumber.function else { return nil }
        var identifier = CGWindowID(0)
        return axWindowID(element, &identifier) == .success && identifier != 0 ? identifier : nil
    }

    private func directTrackedWindowID(matching element: AXUIElement) -> String? {
        directTrackedWindowID(matching: element, in: identitySnapshot())
    }

    /// Main-actor window identity state, captured so focus matching can run off the main thread.
    fileprivate struct IdentitySnapshot: @unchecked Sendable {
        struct Window {
            let id: String
            let pid: pid_t
            let number: CGWindowID?
            let element: AXUIElement
            let admitted: Bool
        }
        let windows: [Window]
        let owned: [(element: AXUIElement, parentID: String)]
    }

    fileprivate func identitySnapshot() -> IdentitySnapshot {
        IdentitySnapshot(
            windows: windows.map { id, tracked in
                .init(id: id, pid: tracked.record.pid, number: tracked.windowNumber,
                      element: tracked.element, admitted: tracked.isAdmitted)
            },
            owned: ownedWindows.map { ($0.element, $0.parentID) }
        )
    }

    nonisolated private func directTrackedWindowID(matching element: AXUIElement,
                                                   in snapshot: IdentitySnapshot) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return Self.trackedWindowID(pid: pid, number: windowNumber(element), element: element, in: snapshot)
    }

    /// Same app, then same window number when both are known, else the same element.
    nonisolated private static func trackedWindowID(pid: pid_t, number: CGWindowID?, element: AXUIElement,
                                                    in snapshot: IdentitySnapshot) -> String? {
        snapshot.windows.first { window in
            guard window.pid == pid else { return false }
            if let number, let trackedNumber = window.number { return number == trackedNumber }
            return CFEqual(window.element, element)
        }?.id
    }

    /// Resolves a focused AX element to its managed window: the window itself, the
    /// owner of an attached sheet or dialog, or a unique same-geometry equivalent.
    nonisolated private func trackedWindowID(matching element: AXUIElement,
                                             in snapshot: IdentitySnapshot) -> String? {
        let isSheet = attribute(element, kAXRoleAttribute) as? String == kAXSheetRole
        if !isSheet, let id = directTrackedWindowID(matching: element, in: snapshot) { return id }
        if let owned = snapshot.owned.first(where: { sameWindow($0.element, element) }) {
            return owned.parentID
        }
        // AX reports an attached sheet as the focused window. Its AXWindow is
        // the owning standard window, which remains the managed focus target.
        if let owner = explicitOwner(of: element),
           let parentID = directTrackedWindowID(matching: owner, in: snapshot) {
            return parentID
        }
        // A newly opened modal can receive focus before the next window scan.
        if attribute(element, kAXModalAttribute) as? Bool == true {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success,
               let main = elementAttribute(AXUIElementCreateApplication(pid), kAXMainWindowAttribute),
               let parentID = directTrackedWindowID(matching: main, in: snapshot) {
                return parentID
            }
        }
        // Never infer a sheet or dialog owner from coincident geometry.
        guard !isSheet, attribute(element, kAXModalAttribute) as? Bool != true,
              let frame = readFrame(element) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return uniqueWindowID(
            matchingFrame: frame,
            among: snapshot.windows.compactMap { window in
                guard window.pid == pid, window.admitted else { return nil }
                return (id: window.id, frame: readFrame(window.element))
            }
        )
    }

    nonisolated private func explicitOwner(of element: AXUIElement) -> AXUIElement? {
        explicitOwner(
            of: element,
            candidates: [kAXWindowAttribute, kAXParentAttribute].map { elementAttribute(element, $0) },
            application: nil
        )
    }

    /// `candidates` are the element's AXWindow and AXParent values. A standard window
    /// reports itself and its application there, which need no further AX reads.
    nonisolated private func explicitOwner(of element: AXUIElement, candidates: [AXUIElement?],
                               application: AXUIElement?) -> AXUIElement? {
        for candidate in candidates {
            guard let owner = candidate, !CFEqual(owner, element),
                  application.map({ !CFEqual(owner, $0) }) ?? true,
                  !sameWindow(owner, element),
                  let role = attribute(owner, kAXRoleAttribute) as? String,
                  role == kAXWindowRole || role == kAXSheetRole else { continue }
            return role == kAXSheetRole ? elementAttribute(owner, kAXWindowAttribute) : owner
        }
        return nil
    }

    nonisolated private func sameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        guard attribute(lhs, kAXRoleAttribute) as? String == kAXWindowRole,
              attribute(rhs, kAXRoleAttribute) as? String == kAXWindowRole else { return false }
        let lhsNumber = windowNumber(lhs)
        let rhsNumber = windowNumber(rhs)
        return lhsNumber != nil && lhsNumber == rhsNumber
    }

    private func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1 &&
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    nonisolated private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    fileprivate struct ScanMetadata {
        let frame: CGRect?
        let subrole: String?
        let minimized: Bool?
        let modal: Bool
        let fullscreen: (value: CFTypeRef?, error: AXError)
        let title: String?
        /// AXWindow and AXParent, the places an attached sheet or dialog names its owner.
        let ownerCandidates: [AXUIElement?]
        /// Which of subrole, frame, and minimized the app did not supply, with the
        /// Accessibility error for each; nil when all three are present.
        let missing: String?

        static func missingDescription(subrole: (value: CFTypeRef?, error: AXError),
                                       position: (value: CFTypeRef?, error: AXError),
                                       size: (value: CFTypeRef?, error: AXError),
                                       minimized: (value: CFTypeRef?, error: AXError)) -> String? {
            var missing: [String] = []
            if subrole.value as? String == nil { missing.append("subrole=\(subrole.error.rawValue)") }
            if WindowSystem.point(position.value) == nil { missing.append("position=\(position.error.rawValue)") }
            if WindowSystem.size(size.value) == nil { missing.append("size=\(size.error.rawValue)") }
            if minimized.value as? Bool == nil { missing.append("minimized=\(minimized.error.rawValue)") }
            return missing.isEmpty ? nil : missing.joined(separator: " ")
        }
    }

    /// Everything a scan needs from one window, in a single round trip when the app
    /// supports batched requests.
    nonisolated private func readScanMetadata(_ element: AXUIElement) -> ScanMetadata {
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
                     kAXModalAttribute, "AXFullScreen", kAXTitleAttribute, kAXWindowAttribute, kAXParentAttribute]
        guard let values = copyAttributes(element, names) else {
            let subrole = copyAttribute(element, kAXSubroleAttribute)
            let position = copyAttribute(element, kAXPositionAttribute)
            let size = copyAttribute(element, kAXSizeAttribute)
            let minimized = copyAttribute(element, kAXMinimizedAttribute)
            return ScanMetadata(
                frame: readFrame(element),
                subrole: subrole.value as? String,
                minimized: minimized.value as? Bool,
                modal: attribute(element, kAXModalAttribute) as? Bool == true,
                fullscreen: copyAttribute(element, "AXFullScreen"),
                title: attribute(element, kAXTitleAttribute) as? String,
                ownerCandidates: [kAXWindowAttribute, kAXParentAttribute].map { elementAttribute(element, $0) },
                missing: ScanMetadata.missingDescription(subrole: subrole, position: position,
                                                         size: size, minimized: minimized)
                    .map { "unbatched " + $0 }
            )
        }
        let frame = Self.point(values[0].value).flatMap { position in
            Self.size(values[1].value).map { CGRect(origin: position, size: $0) }
        }
        return ScanMetadata(
            frame: frame,
            subrole: values[2].value as? String,
            minimized: values[3].value as? Bool,
            modal: values[4].value as? Bool == true,
            fullscreen: values[5],
            title: values[6].value as? String,
            ownerCandidates: values[7...8].map { value in
                value.value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID()
                    ? unsafeDowncast($0, to: AXUIElement.self) : nil }
            },
            missing: ScanMetadata.missingDescription(subrole: values[2], position: values[0],
                                                     size: values[1], minimized: values[3])
        )
    }

    /// Reads several attributes in one Accessibility round trip. Returns nil only when
    /// the app rejects batched requests; a busy app's timeout is returned per attribute
    /// so callers never multiply the wait with individual reads.
    nonisolated private func copyAttributes(_ element: AXUIElement, _ names: [String]) -> [(value: CFTypeRef?, error: AXError)]? {
        var raw: CFArray?
        let status = MainThreadActivity.during("read \(names.joined(separator: ",")) pid=\(Self.pid(of: element))") {
            AXUIElementCopyMultipleAttributeValues(
                element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
            )
        }
        return Self.batchedAttributes(status: status, values: raw as? [AnyObject], count: names.count)
    }

    nonisolated static func batchedAttributes(status: AXError, values: [AnyObject]?,
                                  count: Int) -> [(value: CFTypeRef?, error: AXError)]? {
        switch status {
        case .success:
            guard let values, values.count == count else { return nil }
            return values.map { value in
                if value is NSNull { return (nil, .noValue) }
                if CFGetTypeID(value) == AXValueGetTypeID() {
                    let axValue = unsafeDowncast(value, to: AXValue.self)
                    if AXValueGetType(axValue) == .axError {
                        var error = AXError.failure
                        _ = AXValueGetValue(axValue, .axError, &error)
                        return (nil, error)
                    }
                }
                return (value, .success)
            }
        case .cannotComplete, .invalidUIElement, .apiDisabled, .notificationUnsupported:
            return Array(repeating: (nil, status), count: count)
        default:
            return nil
        }
    }

    nonisolated private func readFrame(_ element: AXUIElement) -> CGRect? {
        // One request returns a position and size from the same app run-loop turn.
        if let values = copyAttributes(element, [kAXPositionAttribute, kAXSizeAttribute]) {
            guard let position = Self.point(values[0].value), let size = Self.size(values[1].value) else { return nil }
            return CGRect(origin: position, size: size)
        }
        guard let firstPosition = readPosition(element),
              let size = readSize(element),
              let secondPosition = readPosition(element) else { return nil }
        if Self.samePosition(firstPosition, secondPosition) {
            return CGRect(origin: secondPosition, size: size)
        }
        // Position and size are separate AX attributes. If motion crossed the
        // first read, pair the newer position with a newer size instead of
        // publishing a frame that never existed.
        guard let secondSize = readSize(element) else { return nil }
        return CGRect(origin: secondPosition, size: secondSize)
    }

    nonisolated private func readPosition(_ element: AXUIElement) -> CGPoint? {
        Self.point(attribute(element, kAXPositionAttribute))
    }

    nonisolated private func readSize(_ element: AXUIElement) -> CGSize? {
        Self.size(attribute(element, kAXSizeAttribute))
    }

    nonisolated static func point(_ raw: CFTypeRef?) -> CGPoint? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    nonisolated static func size(_ raw: CFTypeRef?) -> CGSize? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func writePosition(_ element: AXUIElement, position: CGPoint) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return MainThreadActivity.during("write position pid=\(Self.pid(of: element))") {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        } == .success
    }

    private func moveWithOwnedWindows(windowID: String, move: () -> Bool) -> Bool {
        if let pid = windows[windowID]?.record.pid { motionWriter.settle(pid: pid) }
        let children = ownedWindows.filter { $0.parentID == windowID }
        guard !children.isEmpty, let parent = windows[windowID]?.element,
              let before = readPosition(parent) else { return move() }
        let childPositions = children.map { readPosition($0.element) }
        let success = move()
        guard let after = readPosition(parent) else { return success }
        for (child, childBefore) in zip(children, childPositions) {
            guard let childBefore,
                  let destination = Self.ownedWindowPosition(
                    ownerBefore: before, ownerAfter: after,
                    childBefore: childBefore, childAfter: readPosition(child.element)
                  ) else { continue }
            _ = writePosition(child.element, position: destination)
        }
        return success
    }

    static func ownedWindowPosition(
        ownerBefore: CGPoint, ownerAfter: CGPoint,
        childBefore: CGPoint, childAfter: CGPoint?
    ) -> CGPoint? {
        guard let childAfter, !samePosition(ownerBefore, ownerAfter) else { return nil }
        let destination = CGPoint(
            x: childBefore.x + ownerAfter.x - ownerBefore.x,
            y: childBefore.y + ownerAfter.y - ownerBefore.y
        )
        return samePosition(childAfter, destination) ? nil : destination
    }

    private func writeFrame(_ element: AXUIElement, frame: CGRect, resizeFirst: Bool = true) -> Bool {
        Self.writeFrame(frame: frame, resizeFirst: resizeFirst, readFrame: { self.readFrame(element) }, setSize: { requested in
            var size = requested
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            return MainThreadActivity.during("write size pid=\(Self.pid(of: element))") {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
            } == .success
        }, setPosition: { self.writePosition(element, position: $0) })
    }

    /// A busy app can let the unparking write or its readback time out. Retry for
    /// the same recovery window focus confirmation allows a busy target, and stop
    /// early once the window is confirmed minimized or closed.
    static func restoreForFocus(budgetMilliseconds: Int = 1_500, restore: () -> Bool,
                                unavailable: () -> Bool) async -> (restored: Bool, attempts: Int) {
        let deadline = ContinuousClock.now + .milliseconds(budgetMilliseconds)
        var attempts = 0
        while true {
            attempts += 1
            if restore() { return (true, attempts) }
            guard !Task.isCancelled, !unavailable(), ContinuousClock.now < deadline else { return (false, attempts) }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return (false, attempts) }
        }
    }

    static func writeFrame(frame: CGRect, resizeFirst: Bool = true, readFrame: () -> CGRect?,
                           setSize: (CGSize) -> Bool, setPosition: (CGPoint) -> Bool) -> Bool {
        // Navigation usually changes only position. Avoid native resize animations
        // from the parking side, using layout's one-point size tolerance.
        if let current = readFrame(), abs(current.width - frame.width) <= 1,
           abs(current.height - frame.height) <= 1 {
            if samePosition(current.origin, frame.origin) { return true }
            _ = setPosition(frame.origin)
            guard let actual = readFrame() else { return false }
            return samePosition(actual.origin, frame.origin) &&
                abs(actual.width - frame.width) <= 1 && abs(actual.height - frame.height) <= 1
        }
        // Parked windows must leave the side before resizing. Other frame writes
        // retain size, position, size for display-dependent minimum sizes.
        if resizeFirst { _ = setSize(frame.size) }
        _ = setPosition(frame.origin)
        guard let moved = readFrame(), samePosition(moved.origin, frame.origin) else { return false }
        _ = setSize(frame.size)
        guard let actual = readFrame() else { return false }
        return samePosition(actual.origin, frame.origin) &&
            abs(actual.width - frame.width) <= 1 && abs(actual.height - frame.height) <= 1
    }

    nonisolated private static func samePosition(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }
}
