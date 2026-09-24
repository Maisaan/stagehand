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
    public var onApplicationTerminated: ((pid_t) -> Void)?
    public var onWindowDestroyed: ((String) -> Void)?
    public var onWindowMiniaturized: ((String) -> Void)?
    public var onWindowDeminiaturized: ((String) -> Void)?
    public var onNativeDesktopChange: (() -> Void)?
    public var onScreenParametersChange: (() -> Void)?
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    public var focusDiagnosticsEnabled = false
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

    private struct VisibleWindowIdentity: Hashable {
        let pid: pid_t
        let windowNumber: CGWindowID
    }

    private struct ApplicationInventory: Equatable {
        let applicationPIDs: Set<pid_t>
        let visibleWindows: Set<VisibleWindowIdentity>
    }

    private var windows: [String: TrackedWindow] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var applicationObservations: [pid_t: ApplicationObservation] = [:]
    private var observationRetries: [pid_t: Task<Void, Never>] = [:]
    private let launchDiscovery = ApplicationLaunchDiscovery()
    private var applicationInventoryTask: Task<Void, Never>?
    private var lastApplicationInventory: ApplicationInventory?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var applicationTokens: [NSObjectProtocol] = []
    private var parkingValidationIDs = Set<String>()
    private var nextFallbackID: UInt64 = 0
    private var started = false
    private let systemElement = AXUIElementCreateSystemWide()
    private let nativeWindows = NativeWindowRegistry()

    public init() {
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
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
                MainActor.assumeIsolated {
                    guard let self, self.started else { return }
                    if self.focusDiagnosticsEnabled {
                        print("Discovery t=\(ProcessInfo.processInfo.systemUptime) workspace=\(name.rawValue) pid=\(pid)")
                    }
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self.reportCurrentFocus()
                    }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        self.removeObserver(pid: pid)
                        let removedIDs = self.windows.compactMap {
                            $0.value.record.pid == pid ? $0.key : nil
                        }
                        for id in removedIDs {
                            self.windows.removeValue(forKey: id)
                            self.parkingValidationIDs.remove(id)
                        }
                        if !removedIDs.isEmpty { self.onApplicationTerminated?(pid) }
                    }
                    if name == NSWorkspace.didLaunchApplicationNotification || name == NSWorkspace.didActivateApplicationNotification,
                       let app = NSRunningApplication(processIdentifier: pid) {
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
                self.parkingValidationIDs = Set(self.windows.compactMap {
                    $0.value.parking.isParked ? $0.key : nil
                })
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
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
        applicationTokens.removeAll()
        parkingValidationIDs.removeAll()
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
        let runningApps = NSWorkspace.shared.runningApplications
        let visibleWindows = onScreenWindows()
        let accessoryPIDs = Set(visibleWindows.map(\.pid)).union(windows.values.map(\.record.pid))
        let apps = eligibleApplications(from: runningApps, accessoryPIDs: accessoryPIDs)
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            removeObserver(pid: pid)
        }
        var seen = Set<String>()
        var result: [WindowRecord] = []
        if focusDiagnosticsEnabled {
            print("Scan t=\(ProcessInfo.processInfo.systemUptime) runningApps=\(runningApps.count) eligibleApps=\(apps.count) cgVisibleWindows=\(visibleWindows.count)")
        }
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if started { observeApplication(appElement, pid: app.processIdentifier) }
            let windowList = copyAttribute(appElement, kAXWindowsAttribute)
            if focusDiagnosticsEnabled {
                print("Scan pid=\(app.processIdentifier) AXWindowsStatus=\(windowList.error.rawValue) count=\((windowList.value as? [AXUIElement])?.count ?? -1)")
            }
            guard let elements = windowList.value as? [AXUIElement] else {
                // A temporarily busy application must not lose its space memberships.
                for tracked in windows.values where tracked.record.pid == app.processIdentifier {
                    seen.insert(tracked.record.id)
                    if tracked.isAdmitted { result.append(tracked.record) }
                }
                continue
            }
            let candidates = elements.map { element in
                return (element: element, windowNumber: windowNumber(element), frame: readFrame(element))
            }
            for candidate in candidates {
                let element = candidate.element
                let identityMatch = windows.first {
                    guard $0.value.record.pid == app.processIdentifier else { return false }
                    if let candidateNumber = candidate.windowNumber,
                       let trackedNumber = $0.value.windowNumber {
                        return candidateNumber == trackedNumber
                    }
                    return CFEqual($0.value.element, element)
                }?.key
                let geometryMatches = candidate.frame.map { frame in
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
                guard let subrole = attribute(element, kAXSubroleAttribute) as? String,
                      let currentFrame = candidate.frame,
                      let minimized = attribute(element, kAXMinimizedAttribute) as? Bool else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=missingMetadata") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                let fullscreen = copyAttribute(element, "AXFullScreen")
                if fullscreen.error == .cannotComplete {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=fullscreenReadTimeout") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard subrole == kAXStandardWindowSubrole,
                      currentFrame.width > 1, currentFrame.height > 1 else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=nonstandardOrInvalidFrame") }
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
                        $0.frame.map { sameBounds($0, currentFrame) } == true
                    }).count
                    guard visibleMatch, candidate.windowNumber != nil || geometryMatches == 1 else {
                        if focusDiagnosticsEnabled {
                            print("Scan pid=\(app.processIdentifier) rejected=desktopAdmission visibleMatch=\(visibleMatch) sameGeometryCount=\(geometryMatches)")
                        }
                        continue
                    }
                }
                var movable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable) == .success else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=positionSettableReadFailed") }
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard movable.boolValue else {
                    if focusDiagnosticsEnabled { print("Scan pid=\(app.processIdentifier) rejected=notMovable") }
                    continue
                }
                var resizable: DarwinBoolean = false
                let sizeStatus = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
                let id: String
                if let existingID {
                    id = existingID
                } else if let windowNumber = candidate.windowNumber {
                    id = "\(app.processIdentifier):\(windowNumber)"
                } else {
                    nextFallbackID += 1
                    id = "\(app.processIdentifier):fallback:\(nextFallbackID)"
                }
                let record = WindowRecord(
                    id: id,
                    appName: app.localizedName ?? "Unknown app",
                    title: attribute(element, kAXTitleAttribute) as? String ?? existing?.record.title ?? "",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    frame: windows[id]?.logicalFrame ?? currentFrame,
                    isResizable: sizeStatus == .success ? resizable.boolValue : existing?.record.isResizable ?? false
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
        }
        for id in Array(windows.keys) where !seen.contains(id) {
            guard let pid = windows[id]?.record.pid, livePIDs.contains(pid) else {
                windows.removeValue(forKey: id)
                continue
            }
            windows[id]?.missedScans += 1
            if windows[id]?.missedScans ?? 0 >= 2 {
                windows.removeValue(forKey: id)
            } else if let tracked = windows[id], tracked.isAdmitted {
                result.append(tracked.record)
            }
        }
        if focusDiagnosticsEnabled { print("Scan admittedExternal=\(result.count) registeredNative=\(nativeWindows.records.count)") }
        return result + nativeWindows.records
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
        captureOriginalFrame(windowID: windowID)
        return writePosition(tracked.element, position: position)
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
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.frame(windowID: windowID) }
        guard let tracked = windows[windowID] else { return nil }
        return readFrame(tracked.element)
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
        captureOriginalFrame(windowID: windowID)
        if tracked.parking.restoreFrame != nil {
            guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else { return false }
            var parking = tracked.parking
            let success = parking.restore(to: frame, setFrame: { self.writeFrame(tracked.element, frame: $0, resizeFirst: false) },
                                          readFrame: { self.readFrame(tracked.element) })
            windows[windowID]?.parking = parking
            return success
        }
        return writeFrame(tracked.element, frame: frame)
    }

    /// Parks just this window, preserving other windows belonging to the same app.
    /// A thin side remnant avoids macOS's fully-offscreen clamp without changing Y.
    @discardableResult
    public func park(windowID: String, preferredSide: WindowParkingSide? = nil) -> Bool {
        if nativeWindows.contains(windowID: windowID) { return nativeWindows.park(windowID: windowID) }
        guard let tracked = windows[windowID] else { return false }
        let needsValidation = parkingValidationIDs.remove(windowID) != nil
        if tracked.parking.isParked, !needsValidation { return true }
        guard attribute(tracked.element, kAXMinimizedAttribute) as? Bool == false else { return false }
        guard let currentFrame = readFrame(tracked.element) else { return false }
        captureOriginalFrame(windowID: windowID)
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
            let accepted = self.writePosition(tracked.element, position: position)
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
        let success = parking.restore(setFrame: { self.writeFrame(tracked.element, frame: $0, resizeFirst: false) },
                                      readFrame: { self.readFrame(tracked.element) })
        windows[windowID]?.parking = parking
        if focusDiagnosticsEnabled {
            print("Parking restore pid=\(tracked.record.pid) success=\(success) actual=\(String(describing: readFrame(tracked.element))) restorePending=\(parking.restoreFrame != nil)")
        }
        return success
    }

    public func captureOriginalFrame(windowID: String) {
        if nativeWindows.contains(windowID: windowID) {
            nativeWindows.captureOriginalFrame(windowID: windowID)
            return
        }
        guard let tracked = windows[windowID], tracked.originalFrame == nil else { return }
        windows[windowID]?.originalFrame = readFrame(tracked.element)
    }

    /// Call on pause/quit, before releasing tracking, to return windows to their original positions.
    public func restoreAll() {
        nativeWindows.restoreAll()
        for id in Array(windows.keys) {
            guard let tracked = windows[id] else { continue }
            // Entering native fullscreen hands the window back to macOS.
            guard attribute(tracked.element, "AXFullScreen") as? Bool != true else { continue }
            // Do not discard the original frame if unparking failed.
            // A later recovery attempt must still know where the window started.
            guard restore(windowID: id) else { continue }
            if let originalFrame = tracked.originalFrame {
                if writeFrame(tracked.element, frame: originalFrame) {
                    windows[id]?.originalFrame = nil
                }
            }
        }
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

    @MainActor
    private final class FocusDriver: WindowFocusDriving {
        let targetPID: Int32
        private let system: WindowSystem
        private let target: AXUIElement
        private let targetWindowID: String
        private let app: NSRunningApplication
        private let appElement: AXUIElement
        private let start = ContinuousClock.now
        private let recordsDiagnostics: Bool
        private var canSetFocusedWindow = false

        init(system: WindowSystem, tracked: TrackedWindow, app: NSRunningApplication, recordsDiagnostics: Bool) {
            self.system = system
            self.target = tracked.element
            self.targetWindowID = tracked.record.id
            self.targetPID = tracked.record.pid
            self.app = app
            self.recordsDiagnostics = recordsDiagnostics
            self.appElement = AXUIElementCreateApplication(tracked.record.pid)
        }

        var elapsedMilliseconds: Int {
            let duration = start.duration(to: .now).components
            return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
        }

        func prepare() -> [WindowFocusReport.Operation] {
            var writable: DarwinBoolean = false
            let status = AXUIElementIsAttributeSettable(appElement, kAXFocusedWindowAttribute as CFString, &writable)
            canSetFocusedWindow = writable.boolValue
            var operations: [WindowFocusReport.Operation] = []
            record("isFocusedWindowSettable", status: status.rawValue, accepted: writable.boolValue, into: &operations)
            if app.isHidden { record("unhide", accepted: app.unhide(), into: &operations) }
            record("raise", status: AXUIElementPerformAction(target, kAXRaiseAction as CFString).rawValue, into: &operations)
            record("setMain", status:
                AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue, into: &operations)
            if canSetFocusedWindow {
                record("setFocusedWindow", status:
                    AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, target).rawValue, into: &operations)
            }
            record("setFrontmost", status:
                AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue).rawValue, into: &operations)
            record("activate", accepted: app.activate(options: []), into: &operations)
            return operations
        }

        func requestFocus(attempt: Int) -> [WindowFocusReport.Operation] {
            var operations: [WindowFocusReport.Operation] = []
            if attempt % 4 == 0 {
                record("raise", status: AXUIElementPerformAction(target, kAXRaiseAction as CFString).rawValue, into: &operations)
                if canSetFocusedWindow {
                    record("setFocusedWindow", status:
                        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, target).rawValue, into: &operations)
                }
            }
            record("setFocused", status:
                AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue, into: &operations)
            return operations
        }

        private func record(_ name: String, status: Int32? = nil, accepted: Bool? = nil,
                            into operations: inout [WindowFocusReport.Operation]) {
            guard recordsDiagnostics else { return }
            operations.append(.init(name, accessibilityStatus: status, accepted: accepted))
        }

        func observe() -> WindowFocusReport.Observation {
            let application = system.copyAttribute(system.systemElement, kAXFocusedApplicationAttribute)
            var focusedPID: pid_t?
            var windowStatus: Int32?
            var matches = false
            if let value = application.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let focusedApp = unsafeDowncast(value, to: AXUIElement.self)
                var pid: pid_t = 0
                if AXUIElementGetPid(focusedApp, &pid) == .success { focusedPID = pid }
                if focusedPID == ProcessInfo.processInfo.processIdentifier {
                    // The target is an external app. Never synchronously query
                    // our own AX window from the main thread while handing off.
                    windowStatus = nil
                } else {
                    let window = system.copyAttribute(focusedApp, kAXFocusedWindowAttribute)
                    windowStatus = window.error.rawValue
                    if let focusedWindow = window.value, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                        matches = system.trackedWindowID(
                            matching: unsafeDowncast(focusedWindow, to: AXUIElement.self)
                        ) == targetWindowID
                    }
                }
            }
            // Read the target directly when global AX has not caught up with
            // AppKit after Stagehand's Start menu closes.
            let applicationUnavailable = WindowFocusReport.Observation.isUnavailable(application.error.rawValue)
            let focusedApplicationIsStagehand = focusedPID == ProcessInfo.processInfo.processIdentifier &&
                targetPID != ProcessInfo.processInfo.processIdentifier
            let focusedWindowUnavailable = focusedPID == targetPID && windowStatus.map {
                WindowFocusReport.Observation.isUnavailable($0)
            } == true
            let directWindow = applicationUnavailable || focusedApplicationIsStagehand || focusedWindowUnavailable
                ? system.copyAttribute(appElement, kAXFocusedWindowAttribute)
                : (value: nil, error: AXError.attributeUnsupported)
            let directMatches = directWindow.value.map {
                CFGetTypeID($0) == AXUIElementGetTypeID() &&
                    system.trackedWindowID(matching: unsafeDowncast($0, to: AXUIElement.self)) == targetWindowID
            } ?? false
            return WindowFocusReport.Observation(
                frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                focusedApplicationPID: focusedPID,
                focusedApplicationStatus: application.error.rawValue,
                focusedWindowStatus: windowStatus,
                directFocusedWindowStatus: directWindow.error.rawValue,
                directTargetWindowMatches: directMatches,
                targetApplicationActive: app.isActive,
                targetWindowMatches: matches
            )
        }

        func wait(milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
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
                   let id = owner.trackedWindowID(matching: changedWindow) {
                    switch availabilityChange {
                    case .destroyed:
                        owner.windows.removeValue(forKey: id)
                        owner.parkingValidationIDs.remove(id)
                        owner.onWindowDestroyed?(id)
                    case .minimized:
                        owner.onWindowMiniaturized?(id)
                        return
                    case .restored:
                        owner.onWindowDeminiaturized?(id)
                        return
                    }
                }
                if name == kAXFocusedWindowChangedNotification { owner.reportCurrentFocus() }
                if owner.onFrameChange != nil,
                   name == kAXMovedNotification || name == kAXResizedNotification,
                   let id = owner.trackedWindowID(matching: changedWindow),
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
        applications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            canManageWindows(
                for: $0.activationPolicy,
                hasVisibleOrTrackedWindow: accessoryPIDs.contains($0.processIdentifier)
            ) && !$0.isTerminated
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

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        copyAttribute(element, name).value
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
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

    private func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        var identifier = CGWindowID(0)
        return axWindowID(element, &identifier) == .success && identifier != 0 ? identifier : nil
    }

    private func trackedWindowID(matching element: AXUIElement) -> String? {
        // AX reports an attached sheet as the focused window. Its AXWindow is
        // the owning standard window, which remains the managed focus target.
        let isSheet = attribute(element, kAXRoleAttribute) as? String == kAXSheetRole
        guard let window = isSheet ? elementAttribute(element, kAXWindowAttribute) : element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        let identifier = windowNumber(window)
        if let exactMatch = windows.first(where: { _, tracked in
            guard tracked.record.pid == pid else { return false }
            if let identifier, let trackedIdentifier = tracked.windowNumber {
                return identifier == trackedIdentifier
            }
            return CFEqual(tracked.element, window)
        })?.key {
            return exactMatch
        }
        // A sheet may only inherit an exact parent window identity. Matching
        // its owner by geometry could send buffered input to another window.
        guard !isSheet, let frame = readFrame(window) else { return nil }
        return uniqueWindowID(
            matchingFrame: frame,
            among: windows.compactMap { id, tracked in
                guard tracked.record.pid == pid, tracked.isAdmitted else { return nil }
                return (id: id, frame: readFrame(tracked.element))
            }
        )
    }

    private func sameBounds(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1 && abs(lhs.minY - rhs.minY) < 1 &&
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func readFrame(_ element: AXUIElement) -> CGRect? {
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

    private func readPosition(_ element: AXUIElement) -> CGPoint? {
        guard let raw = attribute(element, kAXPositionAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func readSize(_ element: AXUIElement) -> CGSize? {
        guard let raw = attribute(element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
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

    private static func samePosition(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 1 && abs(lhs.y - rhs.y) <= 1
    }
}
