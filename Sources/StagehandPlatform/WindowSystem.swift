import AppKit
@preconcurrency import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var focusDiagnosticsEnabled = false
    /// Restricts management to these apps, excluding Stagehand's own windows. The
    /// acceptance runner uses it so disposable windows are the only ones moved.
    public var managedBundleIdentifiers: Set<String>?
    public private(set) var lastFocusReport: WindowFocusReport?

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
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var observationRetries: [pid_t: Task<Void, Never>] = [:]
    private let launchDiscovery = ApplicationLaunchDiscovery()
    private var applicationInventoryTask: Task<Void, Never>?
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
    /// Windows an earlier pass could not put back. Each still has a journal record.
    public var pendingRecoveryWindowIDs: Set<String> {
        interruptedWindowIDs.filter { recoveryJournal.records[$0] != nil }
    }
    public var hasPendingRecovery: Bool { !pendingRecoveryWindowIDs.isEmpty }

    public init() {
        interruptedWindowIDs = Set(recoveryJournal.records.keys)
        AXUIElementSetMessagingTimeout(systemElement, 0.1)
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
               record.isOwnedByProcess(pid: owner.processIdentifier, launchDate: owner.launchDate) {
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
                                        pid: app.processIdentifier, launchDate: app.launchDate) else {
                try? recoveryJournal.remove(windowID: record.windowID)
                continue
            }
            let appElement = AXUIElementCreateApplication(record.pid)
            guard let elements = copyAttribute(appElement, kAXWindowsAttribute).value as? [AXUIElement] else {
                foundInterruptedWindow = true
                continue
            }
            guard let element = elements.first(where: { windowNumber($0) == record.windowNumber }) else {
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
            if minimized || fullscreen.value as? Bool == true {
                forgetRecovery(windowID: record.windowID)
                continue
            }
            if let current = readFrame(element), sameBounds(current, record.frame) ||
                writeFrame(element, frame: record.frame) {
                forgetRecovery(windowID: record.windowID)
            }
        }
        interruptedWindowIDs = interruptedWindowIDs.filter { recoveryJournal.records[$0] != nil }
        return foundInterruptedWindow
    }

    /// The window is back where it started, or macOS now owns it. Clear the record
    /// and any tracking left from this process so the next move captures afresh.
    private func forgetRecovery(windowID: String) {
        try? recoveryJournal.remove(windowID: windowID)
        interruptedWindowIDs.remove(windowID)
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
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    if self.focusDiagnosticsEnabled {
                        print("Discovery t=\(ProcessInfo.processInfo.systemUptime) workspace=\(name.rawValue) pid=\(pid.map(String.init) ?? "nil")")
                    }
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self.reportCurrentFocus()
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
                    self.onNativeDesktopChange?()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
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
        lastApplicationInventory = nil
        launchDiscovery.cancelAll()
        restoreAll()
        // A subsequent Start can happen on a different native Desktop. Keep
        // stable identities, but admit only its visible windows again.
        for id in Array(windows.keys) { windows[id]?.isAdmitted = false }
        for id in Array(windows.keys) { windows[id]?.observationComplete = false }
        ownedWindows.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
        applicationTokens.removeAll()
        for retry in observationRetries.values { retry.cancel() }
        observationRetries.removeAll()
        applicationObservations.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
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

    private struct ScanPlan: @unchecked Sendable {
        let apps: [NSRunningApplication]
        let livePIDs: Set<pid_t>
        let visibleWindows: [(pid: pid_t, windowNumber: CGWindowID, frame: CGRect)]
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
            /// Read only for windows that pass the cheap metadata filters.
            let movable: (status: AXError, value: Bool)?
            let resizable: (status: AXError, value: Bool)?
        }
        let windowsStatus: AXError
        let candidates: [Candidate]?
    }

    private func beginScan() -> ScanPlan {
        let runningApps = NSWorkspace.shared.runningApplications
        let visibleWindows = onScreenWindows()
        let accessoryPIDs = Set(visibleWindows.map(\.pid)).union(windows.values.map(\.record.pid))
        let apps = eligibleApplications(from: runningApps, accessoryPIDs: accessoryPIDs)
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            removeObserver(pid: pid)
        }
        if focusDiagnosticsEnabled {
            print("Scan t=\(ProcessInfo.processInfo.systemUptime) runningApps=\(runningApps.count) eligibleApps=\(apps.count) cgVisibleWindows=\(visibleWindows.count)")
        }
        if started {
            for app in apps {
                observeApplication(AXUIElementCreateApplication(app.processIdentifier), pid: app.processIdentifier)
            }
        }
        return ScanPlan(apps: apps, livePIDs: livePIDs, visibleWindows: visibleWindows,
                        reads: ScanReadRequest(system: self, pids: apps.map(\.processIdentifier),
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
            let eligible = !isChild && (metadata.subrole == kAXStandardWindowSubrole || hostsTrackedChild) &&
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
                movable: movable,
                resizable: movable?.value == true ? settable(kAXSizeAttribute) : nil
            )
        }
        return ApplicationRead(windowsStatus: windowList.error, candidates: candidates)
    }

    private func applyScan(_ plan: ScanPlan, reads: [pid_t: ApplicationRead]) -> [WindowRecord] {
        trackedStateGeneration &+= 1
        let visibleWindows = plan.visibleWindows
        var seen = Set<String>()
        var result: [WindowRecord] = []
        var ownedWindows: [OwnedWindow] = []
        for app in plan.apps {
            guard let read = reads[app.processIdentifier] else { continue }
            if focusDiagnosticsEnabled {
                print("Scan pid=\(app.processIdentifier) AXWindowsStatus=\(read.windowsStatus.rawValue) count=\(read.candidates?.count ?? -1)")
            }
            guard let candidates = read.candidates else {
                // A temporarily busy application must not lose its space memberships.
                for tracked in windows.values where tracked.record.pid == app.processIdentifier {
                    seen.insert(tracked.record.id)
                    if tracked.isAdmitted { result.append(tracked.record) }
                }
                ownedWindows.append(contentsOf: self.ownedWindows.filter {
                    var pid: pid_t = 0
                    return AXUIElementGetPid($0.element, &pid) == .success && pid == app.processIdentifier
                })
                continue
            }
            for candidate in candidates where !candidate.isChild {
                let element = candidate.element
                let identityMatch = windows.first {
                    guard $0.value.record.pid == app.processIdentifier else { return false }
                    if let candidateNumber = candidate.windowNumber,
                       let trackedNumber = $0.value.windowNumber {
                        return candidateNumber == trackedNumber
                    }
                    return CFEqual($0.value.element, element)
                }?.key
                let geometryMatches = candidate.metadata.frame.map { frame in
                    windows.filter {
                        $0.value.record.pid == app.processIdentifier &&
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
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=missingMetadata") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                let fullscreen = candidate.metadata.fullscreen
                if fullscreen.error == .cannotComplete {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=fullscreenReadTimeout") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard subrole == kAXStandardWindowSubrole || (candidate.hostsTrackedChild && existing?.isAdmitted == true),
                      currentFrame.width > 1, currentFrame.height > 1 else {
                    if focusDiagnosticsEnabled {
                        print("Scan pid=\(app.processIdentifier) rejected=nonstandardOrInvalidFrame window=\(candidate.windowNumber.map(String.init) ?? "nil") subrole=\(subrole) modal=\(candidate.metadata.modal) frame=\(currentFrame) tracked=\(existingID ?? "nil")")
                    }
                    continue
                }
                guard fullscreen.value as? Bool != true else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) unavailable=fullscreen") }
                    continue
                }
                guard !minimized else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) unavailable=minimized") }
                    continue
                }
                if existing?.isAdmitted != true {
                    // PID and bounds remain available without Screen Recording access.
                    // Reject ambiguous geometry rather than accidentally admitting a
                    // same-sized window belonging to another native macOS Desktop.
                    let visibleMatch = visibleWindows.contains { visible in
                        guard visible.pid == app.processIdentifier else { return false }
                        return candidate.windowNumber.map { $0 == visible.windowNumber }
                            ?? sameBounds(visible.frame, currentFrame)
                    }
                    let geometryMatches = candidates.filter({
                        $0.metadata.frame.map { sameBounds($0, currentFrame) } == true
                    }).count
                    guard visibleMatch, candidate.windowNumber != nil || geometryMatches == 1 else {
                        if focusDiagnosticsEnabled {
                            print("Scan pid=\(app.processIdentifier) rejected=desktopAdmission visibleMatch=\(visibleMatch) sameGeometryCount=\(geometryMatches)")
                        }
                        continue
                    }
                }
                guard let movable = candidate.movable, movable.status == .success else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=positionSettableReadFailed") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard movable.value else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=notMovable") }
                    continue
                }
                let id: String
                if let existingID {
                    id = existingID
                } else if let windowNumber = candidate.windowNumber {
                    id = "\(app.processIdentifier):\(windowNumber)"
                } else {
                    nextFallbackID += 1
                    id = "\(app.processIdentifier):fallback:\(nextFallbackID)"
                }
                let resizable = candidate.resizable
                let record = WindowRecord(
                    id: id,
                    appName: app.localizedName ?? "Unknown app",
                    title: candidate.metadata.title ?? existing?.record.title ?? "",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    frame: windows[id]?.logicalFrame ?? currentFrame,
                    isResizable: resizable?.status == .success ? resizable?.value == true
                        : existing?.record.isResizable ?? false
                )
                if windows[id] != nil {
                    var replacedElement = false
                    if let currentElement = windows[id]?.element, !CFEqual(currentElement, element) {
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
                    if let observer = observers[app.processIdentifier],
                       replacedElement || windows[id]?.observationComplete == false {
                        windows[id]?.observationComplete = observeWindow(element, observer: observer)
                    }
                } else {
                    windows[id] = TrackedWindow(
                        element: element,
                        windowNumber: candidate.windowNumber,
                        record: record
                    )
                    if let observer = observers[app.processIdentifier] {
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
                    print("Scan pid=\(app.processIdentifier) child window=\(candidate.windowNumber.map(String.init) ?? "nil") subrole=\(candidate.metadata.subrole ?? "nil") modal=\(candidate.metadata.modal) owner=\(candidate.ownerNumber.map(String.init) ?? "nil")")
                }
            }
            for candidate in candidates where candidate.isChild && candidate.metadata.minimized != true {
                guard let owner = candidate.owner, let ownerPID = candidate.ownerPID,
                      let parentID = Self.trackedWindowID(pid: ownerPID, number: candidate.ownerNumber,
                                                          element: owner, in: identities),
                      windows[parentID]?.isAdmitted == true else { continue }
                if let previousID = Self.trackedWindowID(pid: app.processIdentifier, number: candidate.windowNumber,
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
        if focusDiagnosticsEnabled { print("Scan admittedExternal=\(result.count) registeredNative=\(nativeWindows.records.count)") }
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
            if focusDiagnosticsEnabled { print("Scan dropped=\(id) restoreFailed=true recordKept=true") }
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
        if minimized.error == .invalidUIElement { return .closed }
        return minimized.value as? Bool == true ? .minimized : nil
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
            guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else { return false }
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
    public func park(windowID: String, preferredSide: WindowParkingSide? = nil) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.park(windowID: windowID) }
        guard let tracked = windows[windowID] else { return false }
        // AX can move a parked window back onscreen after our last frame read.
        // Check its physical position on every parking request.
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else { return false }
        guard let currentFrame = readFrame(tracked.element) else { return false }
        guard captureOriginalFrame(windowID: windowID) else { return false }
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return false }
        let displays = screens.map { screen -> CGRect in
            CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        guard let screenIndex = displays.indices.max(by: {
            let lhs = displays[$0].intersection(currentFrame)
            let rhs = displays[$1].intersection(currentFrame)
            return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
        }) else { return false }
        let visible = screens[screenIndex].visibleFrame
        let bounds = CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                            width: visible.width, height: visible.height)
        var parking = tracked.parking
        let success = parking.park(frame: currentFrame, bounds: bounds, displays: displays,
                                   preferredSide: preferredSide,
                                   setPosition: { position in
            let accepted = self.moveWithOwnedWindows(windowID: windowID) {
                self.writePosition(tracked.element, position: position)
            }
            if self.focusDiagnosticsEnabled { print("Parking write pid=\(tracked.record.pid) requested=\(position) accepted=\(accepted)") }
            return accepted
        },
                                   readFrame: { self.readFrame(tracked.element) })
        windows[windowID]?.parking = parking
        if focusDiagnosticsEnabled {
            print("Parking pid=\(tracked.record.pid) success=\(success) actual=\(String(describing: readFrame(tracked.element))) minimized=\(String(describing: attribute(tracked.element, kAXMinimizedAttribute) as? Bool)) restorePending=\(parking.restoreFrame != nil)")
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
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else { return false }
        var parking = tracked.parking
        let success = parking.restore(setFrame: { requested in
            self.moveWithOwnedWindows(windowID: windowID) {
                self.writeFrame(tracked.element, frame: requested, resizeFirst: false)
            }
        },
                                      readFrame: { self.readFrame(tracked.element) })
        windows[windowID]?.parking = parking
        if focusDiagnosticsEnabled {
            print("Parking restore pid=\(tracked.record.pid) success=\(success) actual=\(String(describing: readFrame(tracked.element))) restorePending=\(parking.restoreFrame != nil)")
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
        guard let frame = readFrame(tracked.element) else { return false }
        // Without an on-disk record a crash would leave the window wherever the
        // ribbon or parking put it. Refuse to move it at all in that case.
        guard let record = Self.recoveryRecord(
            windowID: windowID, bundleIdentifier: tracked.record.bundleIdentifier, pid: tracked.record.pid,
            windowNumber: tracked.windowNumber,
            launchDate: NSRunningApplication(processIdentifier: tracked.record.pid)?.launchDate,
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            ownerLaunchDate: NSRunningApplication.current.launchDate, frame: frame
        ) else {
            NSLog("Stagehand refused to manage window %@: no recovery record can be written", windowID)
            return false
        }
        do {
            try recoveryJournal.save(record)
        } catch {
            NSLog("Stagehand window recovery save failed: %@", error.localizedDescription)
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
        for delay in [50, 100] where !failed.isEmpty {
            Thread.sleep(forTimeInterval: Double(delay) / 1_000)
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

    public func focusedWindowID() -> String? {
        if NSApp?.isActive == true { return nativeWindows.focusedWindowID }
        let result = copyAttribute(systemElement, kAXFocusedApplicationAttribute)
        let focusedApp: AXUIElement
        if let value = result.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let reportedApp = unsafeDowncast(value, to: AXUIElement.self)
            var reportedPID: pid_t = 0
            if AXUIElementGetPid(reportedApp, &reportedPID) == .success,
               reportedPID == ProcessInfo.processInfo.processIdentifier,
               let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.isActive,
               frontmost.processIdentifier != reportedPID {
                focusedApp = AXUIElementCreateApplication(frontmost.processIdentifier)
            } else {
                focusedApp = reportedApp
            }
        } else if result.error == .noValue,
                  let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.isActive {
            // Match focus()'s narrow fallback. A remembered window in a background
            // app is not evidence of keyboard focus.
            focusedApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        } else {
            return nil
        }
        var focusedPID: pid_t = 0
        if AXUIElementGetPid(focusedApp, &focusedPID) == .success,
           focusedPID == ProcessInfo.processInfo.processIdentifier {
            return nativeWindows.focusedWindowID
        }
        guard let focusedWindow = elementAttribute(focusedApp, kAXFocusedWindowAttribute) else { return nil }
        return trackedWindowID(matching: focusedWindow)
    }

    private func reportCurrentFocus() {
        guard onFocusedWindowChange != nil, let id = focusedWindowID() else { return }
        if nativeWindows.contains(windowID: id) {
            onFocusedWindowChange?(id)
            return
        }
        // An app's delayed focus notification can arrive after it lost activation.
        // Resolve actual focus and independently reject background remembered windows.
        guard let tracked = windows[id], tracked.isAdmitted,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isActive, frontmost.processIdentifier == tracked.record.pid else { return }
        onFocusedWindowChange?(id)
    }

    /// Returns success only after the target application and its exact window own focus.
    /// Callers must not report a successful transition before this confirmation.
    public func focus(windowID: String) async -> Bool {
        lastFocusReport = nil
        guard !Task.isCancelled else { return false }
        if nativeWindows.contains(windowID: windowID) {
            let began = ContinuousClock.now
            let success = await nativeWindows.focus(windowID: windowID)
            if focusDiagnosticsEnabled {
                let elapsed = began.duration(to: .now).components
                lastFocusReport = WindowFocusReport(targetPID: ProcessInfo.processInfo.processIdentifier,
                                                    outcome: success ? .focused : .timedOut,
                                                    elapsedMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
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
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else {
            if focusDiagnosticsEnabled {
                lastFocusReport = WindowFocusReport(
                    targetPID: tracked.record.pid,
                    outcome: .unavailable,
                    elapsedMilliseconds: 0,
                    operations: [.init("targetMinimized", accepted: false)],
                    initialObservation: nil,
                    observations: []
                )
            }
            return false
        }
        guard !Task.isCancelled else { return false }
        guard restore(windowID: windowID) else {
            if focusDiagnosticsEnabled { lastFocusReport = WindowFocusReport(targetPID: tracked.record.pid, outcome: .unavailable,
                                                elapsedMilliseconds: 0,
                                                operations: [.init("restoreTarget", accepted: false)],
                                                initialObservation: nil, observations: []) }
            return false
        }
        let driver = FocusDriver(system: self, tracked: tracked, app: app, recordsDiagnostics: focusDiagnosticsEnabled)
        let report = await WindowFocusAttempt.run(driver: driver, recordDiagnostics: focusDiagnosticsEnabled)
        if focusDiagnosticsEnabled { lastFocusReport = report }
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
            let duration = start.duration(to: .now).components
            return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
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
            operations += record([Step(name: "activate", status: nil, accepted: app.activate(options: []))])
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
                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
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
                // Read the target directly when global AX has not caught up with
                // AppKit after Stagehand's Start menu closes.
                let applicationUnavailable = WindowFocusReport.Observation.isUnavailable(application.error.rawValue)
                let focusedApplicationIsStagehand = result.focusedPID == ownPID && context.targetPID != ownPID
                let focusedWindowUnavailable = result.focusedPID == context.targetPID
                    && result.windowStatus.map(WindowFocusReport.Observation.isUnavailable) == true
                if applicationUnavailable || focusedApplicationIsStagehand || focusedWindowUnavailable {
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
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
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

        private static let queue = DispatchQueue(label: "app.stagehand.focus-accessibility", qos: .userInteractive)

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
                if owner.focusDiagnosticsEnabled {
                    var pid: pid_t = 0
                    _ = AXUIElementGetPid(changedWindow, &pid)
                    print("Discovery t=\(ProcessInfo.processInfo.systemUptime) AX=\(name) pid=\(pid)")
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
                   let id = owner.directTrackedWindowID(matching: changedWindow),
                   let frame = owner.readFrame(changedWindow) {
                    owner.onFrameChange?(id, frame)
                }
                owner.onChange?()
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        observers[pid] = observer
        applicationObservations[pid] = ApplicationObservation()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        if registerApplicationNotifications(element: element, pid: pid) {
            scheduleObservationRetries(element: element, pid: pid)
        }
        for id in Array(windows.keys) where windows[id]?.record.pid == pid {
            guard let element = windows[id]?.element else { continue }
            windows[id]?.observationComplete = observeWindow(element, observer: observer)
        }
    }

    private func registerApplicationNotifications(element: AXUIElement, pid: pid_t) -> Bool {
        guard let observer = observers[pid], var registration = applicationObservations[pid] else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let retry = registration.register { name in
            let status = AXObserverAddNotification(observer, element, name as CFString, context)
            if focusDiagnosticsEnabled { print("Discovery observe pid=\(pid) AX=\(name) status=\(status.rawValue)") }
            return status
        }
        applicationObservations[pid] = registration
        return retry
    }

    private func scheduleObservationRetries(element: AXUIElement, pid: pid_t) {
        let delays = [100, 200, 400, 800, 1600, 3200, 5000]
        observationRetries[pid] = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = delays[min(attempt, delays.count - 1)]
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                guard let self, self.started, !Task.isCancelled else { return }
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                    self.removeObserver(pid: pid)
                    return
                }
                let retry = self.registerApplicationNotifications(element: element, pid: pid)
                // Discover windows that appeared before registration succeeded.
                self.onChange?()
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
            applications: NSWorkspace.shared.runningApplications,
            visibleWindows: initialVisibleWindows
        )
        applicationInventoryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                guard let self, self.started, !Task.isCancelled else { return }
                let visibleWindows = self.onScreenWindows()
                let applications = NSWorkspace.shared.runningApplications
                let visiblePIDs = Set(visibleWindows.map(\.pid))
                var scheduled = false
                for app in self.eligibleApplications(
                    from: applications,
                    accessoryPIDs: visiblePIDs
                )
                where self.observers[app.processIdentifier] == nil {
                    scheduled = self.scheduleDiscovery(for: app) || scheduled
                }
                let inventory = self.applicationInventory(
                    applications: applications,
                    visibleWindows: visibleWindows
                )
                let changed = inventory != self.lastApplicationInventory
                self.lastApplicationInventory = inventory
                if scheduled || changed { self.onChange?() }
            }
        }
    }

    private func applicationInventory(
        applications: [NSRunningApplication],
        visibleWindows: [(pid: pid_t, windowNumber: CGWindowID, frame: CGRect)]
    ) -> ApplicationInventory {
        let visiblePIDs = Set(visibleWindows.map(\.pid))
        return ApplicationInventory(
            applicationPIDs: Set(eligibleApplications(
                from: applications,
                accessoryPIDs: visiblePIDs
            ).map(\.processIdentifier)),
            visibleWindows: Set(visibleWindows.map {
                VisibleWindowIdentity(pid: $0.pid, windowNumber: $0.windowNumber)
            })
        )
    }

    @discardableResult
    private func scheduleDiscovery(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
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
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            managedBundleIdentifiers.map { allowed in app.bundleIdentifier.map(allowed.contains) ?? false } ?? true &&
            canManageWindows(
                for: app.activationPolicy,
                hasVisibleOrTrackedWindow: accessoryPIDs.contains(app.processIdentifier)
            ) && !app.isTerminated
        }
    }

    private func removeObserver(pid: pid_t) {
        launchDiscovery.cancel(pid: pid)
        observationRetries.removeValue(forKey: pid)?.cancel()
        applicationObservations.removeValue(forKey: pid)
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        for id in Array(windows.keys) where windows[id]?.record.pid == pid {
            windows[id]?.observationComplete = false
        }
    }

    private func observeWindow(_ element: AXUIElement, observer: AXObserver) -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        var complete = true
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification] {
            let status = AXObserverAddNotification(observer, element, name as CFString, context)
            if status != .success, status != .notificationAlreadyRegistered { complete = false }
        }
        return complete
    }

    nonisolated private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        copyAttribute(element, name).value
    }

    nonisolated private func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private func onScreenWindows() -> [(pid: pid_t, windowNumber: CGWindowID, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = window[kCGWindowNumber as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (pid.int32Value, windowNumber.uint32Value, frame)
        }
    }

    nonisolated private func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        var identifier = CGWindowID(0)
        return axWindowID(element, &identifier) == .success && identifier != 0 ? identifier : nil
    }

    private func directTrackedWindowID(matching element: AXUIElement) -> String? {
        directTrackedWindowID(matching: element, in: identitySnapshot())
    }

    private func trackedWindowID(matching element: AXUIElement) -> String? {
        trackedWindowID(matching: element, in: identitySnapshot())
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
    }

    /// Everything a scan needs from one window, in a single round trip when the app
    /// supports batched requests.
    nonisolated private func readScanMetadata(_ element: AXUIElement) -> ScanMetadata {
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
                     kAXModalAttribute, "AXFullScreen", kAXTitleAttribute, kAXWindowAttribute, kAXParentAttribute]
        guard let values = copyAttributes(element, names) else {
            return ScanMetadata(
                frame: readFrame(element),
                subrole: attribute(element, kAXSubroleAttribute) as? String,
                minimized: attribute(element, kAXMinimizedAttribute) as? Bool,
                modal: attribute(element, kAXModalAttribute) as? Bool == true,
                fullscreen: copyAttribute(element, "AXFullScreen"),
                title: attribute(element, kAXTitleAttribute) as? String,
                ownerCandidates: [kAXWindowAttribute, kAXParentAttribute].map { elementAttribute(element, $0) }
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
            }
        )
    }

    /// Reads several attributes in one Accessibility round trip. Returns nil only when
    /// the app rejects batched requests; a busy app's timeout is returned per attribute
    /// so callers never multiply the wait with individual reads.
    nonisolated private func copyAttributes(_ element: AXUIElement, _ names: [String]) -> [(value: CFTypeRef?, error: AXError)]? {
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw
        )
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
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func moveWithOwnedWindows(windowID: String, move: () -> Bool) -> Bool {
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
            return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
        }, setPosition: { self.writePosition(element, position: $0) })
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
