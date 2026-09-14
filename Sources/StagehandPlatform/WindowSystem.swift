import AppKit
@preconcurrency import ApplicationServices

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

/// Controls real application windows. It never activates a Stagehand window.
@MainActor
public final class WindowSystem {
    public var onChange: (() -> Void)?
    public var onNativeDesktopChange: (() -> Void)?
    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    private struct TrackedWindow {
        let element: AXUIElement
        var record: WindowRecord
        var originalFrame: CGRect?
        var parkedFrame: CGRect?
        var minimizedByStagehand = false
        var isAdmitted = true
    }

    private var windows: [String: TrackedWindow] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var nextID: UInt64 = 0
    private var started = false
    private let systemElement = AXUIElementCreateSystemWide()

    public init() {
        AXUIElementSetMessagingTimeout(systemElement, 0.1)
    }

    public func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.started else { return }
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
        _ = scanWindows()
    }

    public func stop() {
        started = false
        restoreAll()
        // A subsequent Start can happen on a different native Desktop. Keep
        // stable identities, but admit only its visible windows again.
        for id in Array(windows.keys) { windows[id]?.isAdmitted = false }
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
    }

    public func scanWindows() -> [WindowRecord] {
        guard isAccessibilityTrusted else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        var seen = Set<String>()
        var result: [WindowRecord] = []
        let visibleWindows = onScreenWindows()
        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.1)
            if started { observeApplication(appElement, pid: app.processIdentifier) }
            guard let elements = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
                // A temporarily busy application must not lose its space memberships.
                for tracked in windows.values where tracked.record.pid == app.processIdentifier {
                    seen.insert(tracked.record.id)
                    if tracked.isAdmitted { result.append(tracked.record) }
                }
                continue
            }
            let candidates = elements.map { element in
                AXUIElementSetMessagingTimeout(element, 0.1)
                return (element: element, frame: readFrame(element))
            }
            for candidate in candidates {
                let element = candidate.element
                let existingID = windows.first {
                    $0.value.record.pid == app.processIdentifier && CFEqual($0.value.element, element)
                }?.key
                let existing = existingID.flatMap { windows[$0] }
                // Presence in AXWindows means the window still exists, even if an
                // individual attribute temporarily times out. Keep restoration data.
                if let existingID { seen.insert(existingID) }
                guard let subrole = attribute(element, kAXSubroleAttribute) as? String,
                      let currentFrame = candidate.frame,
                      let minimized = attribute(element, kAXMinimizedAttribute) as? Bool else {
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                let fullscreen = copyAttribute(element, "AXFullScreen")
                if fullscreen.error == .cannotComplete {
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard subrole == kAXStandardWindowSubrole,
                      fullscreen.value as? Bool != true,
                      currentFrame.width > 1, currentFrame.height > 1 else { continue }
                guard !minimized || existingID.flatMap({ windows[$0]?.minimizedByStagehand }) == true else {
                    continue
                }
                if existing?.isAdmitted != true {
                    // PID and bounds remain available without Screen Recording access.
                    // Reject ambiguous geometry rather than accidentally admitting a
                    // same-sized window belonging to another native macOS Desktop.
                    guard visibleWindows.contains(where: {
                        $0.pid == app.processIdentifier && sameBounds($0.frame, currentFrame)
                    }), candidates.filter({
                        $0.frame.map { sameBounds($0, currentFrame) } == true
                    }).count == 1 else { continue }
                }
                var movable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable) == .success else {
                    if let existing, existing.isAdmitted { result.append(existing.record) }
                    continue
                }
                guard movable.boolValue else { continue }
                var resizable: DarwinBoolean = false
                let sizeStatus = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable)
                let id: String
                if let existingID {
                    id = existingID
                } else {
                    nextID += 1
                    id = "\(app.processIdentifier):\(nextID)"
                }
                let record = WindowRecord(
                    id: id,
                    appName: app.localizedName ?? "Application",
                    title: attribute(element, kAXTitleAttribute) as? String ?? existing?.record.title ?? "",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    frame: windows[id]?.parkedFrame ?? currentFrame,
                    isResizable: sizeStatus == .success ? resizable.boolValue : existing?.record.isResizable ?? false
                )
                if windows[id] != nil {
                    windows[id]?.record = record
                    windows[id]?.isAdmitted = true
                } else {
                    windows[id] = TrackedWindow(element: element, record: record)
                    if let observer = observers[app.processIdentifier] { observeWindow(element, observer: observer) }
                }
                seen.insert(id)
                result.append(record)
            }
        }
        windows = windows.filter { seen.contains($0.key) }
        return result
    }

    public func frame(windowID: String) -> CGRect? {
        guard let tracked = windows[windowID] else { return nil }
        return tracked.parkedFrame ?? readFrame(tracked.element)
    }

    @discardableResult
    public func setFrame(windowID: String, frame: CGRect) -> Bool {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0,
              let tracked = windows[windowID] else { return false }
        captureOriginalFrame(windowID: windowID)
        guard restore(windowID: windowID) else { return false }
        return writeFrame(tracked.element, frame: frame)
    }

    /// Parks just this window, preserving other windows belonging to the same app.
    /// Some apps clamp offscreen positions; those windows are minimized as a fallback.
    @discardableResult
    public func park(windowID: String) -> Bool {
        guard let tracked = windows[windowID] else { return false }
        if tracked.parkedFrame != nil { return true }
        guard let currentFrame = readFrame(tracked.element) else { return false }
        captureOriginalFrame(windowID: windowID)
        let displays = NSScreen.screens.map { screen -> CGRect in
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            return CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                          width: screen.frame.width, height: screen.frame.height)
        }
        guard let rightEdge = displays.map(\.maxX).max() else { return false }
        var parked = currentFrame
        parked.origin.x = rightEdge + 32
        windows[windowID]?.parkedFrame = currentFrame
        if writePosition(tracked.element, position: parked.origin),
           let actual = readFrame(tracked.element),
           displays.allSatisfy({ !$0.intersects(actual) }) {
            return true
        }
        // Restore the visible position before minimizing so the Dock restores it correctly.
        _ = writePosition(tracked.element, position: currentFrame.origin)
        if AXUIElementSetAttributeValue(tracked.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            windows[windowID]?.minimizedByStagehand = true
            return true
        }
        windows[windowID]?.parkedFrame = nil
        return false
    }

    /// Unparks without requesting app activation. Focus is a separate operation.
    @discardableResult
    public func restore(windowID: String) -> Bool {
        guard let tracked = windows[windowID] else { return false }
        guard let parkedFrame = tracked.parkedFrame else { return true }
        if tracked.minimizedByStagehand {
            guard AXUIElementSetAttributeValue(tracked.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                return false
            }
        }
        windows[windowID]?.minimizedByStagehand = false
        windows[windowID]?.parkedFrame = nil
        return writeFrame(tracked.element, frame: parkedFrame)
    }

    public func captureOriginalFrame(windowID: String) {
        guard let tracked = windows[windowID], tracked.originalFrame == nil else { return }
        windows[windowID]?.originalFrame = readFrame(tracked.element)
    }

    /// Call on pause/quit, before releasing tracking, to return windows to their original positions.
    public func restoreAll() {
        for id in Array(windows.keys) {
            guard let tracked = windows[id] else { continue }
            // Entering native fullscreen hands the window back to macOS.
            guard attribute(tracked.element, "AXFullScreen") as? Bool != true else { continue }
            // Do not discard the original frame if unminimizing/unparking failed.
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
        guard let focusedApp = elementAttribute(systemElement, kAXFocusedApplicationAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focusedApp, 0.1)
        guard let focusedWindow = elementAttribute(focusedApp, kAXFocusedWindowAttribute) else { return nil }
        return windows.first { CFEqual($0.value.element, focusedWindow) }?.key
    }

    /// Returns success only after the target application and its exact window own focus.
    /// Callers must not report a successful transition before this confirmation.
    public func focus(windowID: String) async -> Bool {
        guard let tracked = windows[windowID],
              let app = NSRunningApplication(processIdentifier: tracked.record.pid),
              !app.isTerminated,
              restore(windowID: windowID) else { return false }
        let appElement = AXUIElementCreateApplication(tracked.record.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        var canSetFocusedWindow: DarwinBoolean = false
        AXUIElementIsAttributeSettable(appElement, kAXFocusedWindowAttribute as CFString, &canSetFocusedWindow)
        if app.isHidden { app.unhide() }
        _ = AXUIElementPerformAction(tracked.element, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(tracked.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if canSetFocusedWindow.boolValue {
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, tracked.element)
        }
        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = app.activate(options: [])
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        var attempt = 0
        repeat {
            guard !Task.isCancelled else { return false }
            if attempt % 4 == 0 {
                _ = AXUIElementPerformAction(tracked.element, kAXRaiseAction as CFString)
                if canSetFocusedWindow.boolValue {
                    _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, tracked.element)
                }
            }
            _ = AXUIElementSetAttributeValue(tracked.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if app.isActive && focusedWindowID() == windowID { return true }
            attempt += 1
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }

    private func observeApplication(_ element: AXUIElement, pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            // This observer is attached exclusively to the main run loop.
            MainActor.assumeIsolated {
                let owner = Unmanaged<WindowSystem>.fromOpaque(context).takeUnretainedValue()
                if owner.started { owner.onChange?() }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        observers[pid] = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                     kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for tracked in windows.values where tracked.record.pid == pid {
            observeWindow(tracked.element, observer: observer)
        }
    }

    private func observeWindow(_ element: AXUIElement, observer: AXObserver) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXTitleChangedNotification, kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        copyAttribute(element, name).value
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    private func onScreenWindows() -> [(pid: pid_t, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (pid.int32Value, frame)
        }
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
        guard let positionValue = attribute(element, kAXPositionAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetType(positionAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &point), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func writePosition(_ element: AXUIElement, position: CGPoint) -> Bool {
        var point = position
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func writeFrame(_ element: AXUIElement, frame: CGRect) -> Bool {
        var size = frame.size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        // Size, position, size handles apps whose minimum size depends on their display.
        let resized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
        let positioned = writePosition(element, position: frame.origin)
        if resized { _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        return positioned && (resized || readFrame(element)?.size == frame.size)
    }
}
