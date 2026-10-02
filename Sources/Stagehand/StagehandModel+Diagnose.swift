import AppKit
import StagehandCore
import StagehandPlatform

/// `--diagnose-*` commands. They drive the real Start path against disposable windows.
extension StagehandModel {
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
        while (changes.isProcessing || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, !isSuspended,
              let emptyIndex = state.spaces.indices.last(where: { state.spaces[$0].windowIDs.isEmpty }) else {
            return "Last-close setup failed. Running: \(isRunning). Warning: \(warning ?? "none")"
        }
        focusWindow(disposableID)
        while (changes.isProcessing || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isRunning, state.focusedWindowID == disposableID else {
            return "Last-close setup could not focus the disposable window. Warning: \(warning ?? "none")"
        }
        navigate(.moveToSpace(index: emptyIndex, follow: true))
        while (changes.isProcessing || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
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
            if !isRunning || (state.spaces[emptyIndex].windowIDs.isEmpty && !changes.isProcessing &&
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
        while (changes.isProcessing || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        var focusChecks: [String] = []
        if includeSettings {
            for id in state.currentSpace.windowIDs {
                guard isRunning, !isSuspended, ContinuousClock.now < deadline else { break }
                focusWindow(id)
                while (changes.isProcessing || ribbonMotion.isRunning) && ContinuousClock.now < deadline {
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
        Border corner radius: \(focusBorder.cornerRadius.map { String(describing: $0) } ?? "fallback")
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
    func diagnoseDiscovery(probeURL: URL, settlingWindow: Bool = false,
                           standaloneDialog: Bool = false) async -> String {
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
        while changes.isProcessing && ContinuousClock.now < preparationDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        navigate(.goToSpace(index: WorkspaceState.spaceCount - 1))
        while changes.isProcessing && ContinuousClock.now < preparationDeadline {
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
            configuration.arguments = (settlingWindow ? ["--settling-window"] : []) +
                (standaloneDialog ? ["--standalone-dialog"] : [])
            probe = try await NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration)
        } catch {
            return "Discovery failed: could not launch the disposable probe."
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while isRunning, !isSuspended, ContinuousClock.now < deadline {
            let discovered = windows.filter { $0.bundleIdentifier == probeID }
            if !discovered.isEmpty, discovered.allSatisfy({ state.currentSpace.windowIDs.contains($0.id) }),
               !changes.isProcessing, !ribbonMotion.isRunning { break }
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
}
