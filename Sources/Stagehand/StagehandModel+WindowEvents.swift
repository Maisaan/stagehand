import AppKit
import StagehandCore
import StagehandPlatform

/// Reactions to windows and apps changing outside a layout pass.
extension StagehandModel {
    func windowTitleChanged(windowID: String, title: String) {
        guard isRunning, !isSuspended,
              let index = windows.firstIndex(where: { $0.id == windowID }) else { return }
        windows[index] = windows[index].withTitle(title)
        overlays.updateNavigation(state: state, windows: windows)
    }

    /// Delay before retrying a refresh. Waits for a busy worker stay short; a
    /// stale background scan backs off exponentially from 100 ms to 2 s.
    static func refreshRetryDelay(staleScans: Int) -> Duration {
        guard staleScans > 0 else { return .milliseconds(100) }
        return .milliseconds(min(2_000, 100 << min(staleScans, 10)))
    }

    func scheduleRefresh(immediately: Bool = false) {
        guard isRunning, !isSuspended else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var attempts = 0
            var staleScans = 0
            var delay: Duration = immediately ? .zero : .milliseconds(100)
            while !Task.isCancelled {
                do {
                    if delay == .zero { await Task.yield() }
                    else { try await Task.sleep(for: delay) }
                }
                catch { return }
                guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended else { return }
                attempts += 1
                guard attempts <= self.refreshRetryLimit else {
                    // Something has kept the ribbon busy or unreadable for the whole
                    // budget. Stop polling; the next window change schedules again.
                    self.diagnostics.record("refresh_starved", details: [
                        "attempts": String(attempts - 1),
                        "staleScans": String(staleScans),
                        "workerActive": String(self.changes.isProcessing),
                        "motionRunning": String(self.ribbonMotion.isRunning),
                        "gestureActive": String(self.gestureBase != nil)
                    ])
                    return
                }
                delay = Self.refreshRetryDelay(staleScans: staleScans)
                guard !self.changes.isProcessing, !self.ribbonMotion.isRunning,
                      self.gestureBase == nil, !self.isLayingOutWindows else { continue }
                // Scanning on another Desktop could admit its windows.
                guard self.desktopScope.refresh() == .home else {
                    self.nativeDesktopChanged()
                    return
                }
                let current: [WindowRecord]
                if staleScans >= self.refreshStaleScanFallback {
                    // Windows keep changing under the background reader. One
                    // synchronous scan cannot be invalidated the same way.
                    self.diagnostics.record("refresh_scan_fallback", details: ["staleScans": String(staleScans)])
                    current = self.windowSystem.scanWindows()
                } else {
                    // Read windows off the main thread. Windows changed during the read
                    // (closed, minimized, another scan) make it stale; try again.
                    guard let scanned = await self.windowSystem.scanWindowsOffMain() else {
                        staleScans += 1
                        delay = Self.refreshRetryDelay(staleScans: staleScans)
                        continue
                    }
                    current = scanned
                }
                // Focus, like the scan, is read off the main thread.
                let observedFocus = await self.windowSystem.focusedWindowIDOffMain()
                guard !Task.isCancelled, self.isRunning, !self.isSuspended else { return }
                guard !self.changes.isProcessing, !self.ribbonMotion.isRunning,
                      self.gestureBase == nil, !self.isLayingOutWindows else { continue }
                guard self.desktopScope.refresh() == .home else {
                    self.nativeDesktopChanged()
                    return
                }
                self.applyRefresh(current, observedFocusedWindowID: .some(observedFocus))
                return
            }
        }
    }

    func applicationTerminated(pid: Int32) {
        removeFromRibbon(forgetFocus: true, event: "application_removed", remove: {
            removeTerminatedApplication(
                pid: pid, windows: &windows, state: &state, restoration: &workspaceRestoration,
                trackedWindowIDs: windowSystem.trackedWindowIDs
            )
        }, details: { ["pid": String(pid), "windowCount": String($0.count)] })
    }

    @discardableResult
    func windowDestroyed(windowID: String) -> Bool {
        removeFromRibbon(forgetFocus: true, event: "window_removed", remove: {
            removeDestroyedWindow(
                windowID: windowID, windows: &windows, state: &state,
                restoration: &workspaceRestoration, trackedWindowIDs: windowSystem.trackedWindowIDs
            ) ? [windowID] : []
        }, details: { _ in ["windowID": windowID] })
    }

    /// A minimized window keeps its focus history so it can return to its membership.
    @discardableResult
    func windowMiniaturized(windowID: String) -> Bool {
        let removed = removeFromRibbon(forgetFocus: false, event: "window_unavailable", remove: {
            removeUnavailableWindow(
                windowID: windowID, windows: &windows, state: &state,
                restoration: &workspaceRestoration, trackedWindowIDs: windowSystem.trackedWindowIDs
            ) ? [windowID] : []
        }, details: { _ in ["windowID": windowID, "reason": "minimized"] })
        if removed { minimizedWindowIDs.insert(windowID) }
        return removed
    }

    /// Applies a removal immediately and animates the remaining ribbon closed.
    @discardableResult
    func removeFromRibbon(
        forgetFocus: Bool,
        event: String,
        remove: () -> Set<String>,
        details: (Set<String>) -> [String: String]
    ) -> Bool {
        guard isRunning, !isSuspended else { return false }
        refreshTask?.cancel()
        let previousState = state
        let motionStart = navigationFrames()
        let focusedWindowID = state.focusedWindowID
        let removedIDs = remove()
        guard !removedIDs.isEmpty else { return false }
        if forgetFocus { focusHistory.remove(windowIDs: removedIDs) }
        focusMostRecentWindowAfterLoss(
            previousFocusedWindowID: focusedWindowID,
            history: focusHistory,
            state: &state
        )
        finishRemovingWindows(removedIDs, focusedWindowID: focusedWindowID)
        diagnostics.record(event, details: details(removedIDs))
        enqueue(.windowRemoval, transitionFrom: previousState, motionStart: motionStart)
        onStateChange?()
        return true
    }

    /// Handles a minimize or close that the app never reported, found while
    /// focusing or parking the window.
    @discardableResult
    func dropUnavailableWindow(_ windowID: String, reason: WindowUnavailability,
                                       detectedBy source: String) -> Bool {
        diagnostics.record("window_unavailable_detected", details: [
            "detectedBy": source,
            "reason": reason.rawValue,
            "windowID": windowID
        ])
        switch reason {
        case .minimized: return windowMiniaturized(windowID: windowID)
        case .closed: return windowDestroyed(windowID: windowID)
        }
    }

    func windowDeminiaturized(windowID: String) {
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
        if !placeRestoredWindows() {
            // Minimized while paused: it returns to its saved slot.
            if state.currentSpace.windowIDs.contains(windowID) {
                state.focus(windowID: windowID)
            } else if let spaceIndex = state.spaces.firstIndex(where: { $0.windowIDs.contains(windowID) }) {
                state.focus(windowID: windowID, inSpace: spaceIndex)
            }
        }
        diagnostics.record("window_available", details: ["windowID": windowID, "reason": "restored"])
        enqueue(.refresh)
        onStateChange?()
    }

    /// Puts windows that returned from the Dock directly after the focused window
    /// of their space and focuses them. Returns whether any window was placed.
    @discardableResult
    func placeRestoredWindows() -> Bool {
        minimizedWindowIDs.formIntersection(windowSystem.trackedWindowIDs)
        var placed = false
        for windowID in minimizedWindowIDs where windows.contains(where: { $0.id == windowID }) {
            minimizedWindowIDs.remove(windowID)
            let spaceIndex = state.currentSpace.windowIDs.contains(windowID)
                ? state.activeSpaceIndex
                : state.spaces.firstIndex { $0.windowIDs.contains(windowID) }
            guard let spaceIndex, state.placeAfterFocused(windowID: windowID, inSpace: spaceIndex) else { continue }
            placed = true
            diagnostics.record("restored_window_placed", details: [
                "windowID": windowID,
                "space": String(spaceIndex + 1),
                "index": String(state.spaces[spaceIndex].windowIDs.firstIndex(of: windowID) ?? -1)
            ])
        }
        return placed
    }

    func finishRemovingWindows(_ removedIDs: Set<String>, focusedWindowID: String?) {
        if ribbonMotion.isRunning {
            presentationFrames = ribbonMotion.frames.filter { !removedIDs.contains($0.key) }
            ribbonMotion.cancel()
        }
        if focusedWindowID.map(removedIDs.contains) == true {
            focusGate.cancelAll()
        }
        preferredHeights = preferredHeights.filter { !removedIDs.contains($0.key) }
        lastAppliedFrames = lastAppliedFrames.filter { !removedIDs.contains($0.key) }
        knownFrames = knownFrames.filter { !removedIDs.contains($0.key) }
        motionWrittenPositions = motionWrittenPositions.filter { !removedIDs.contains($0.key) }
        presentationFrames = presentationFrames?.filter { !removedIDs.contains($0.key) }
        gestureBase = gestureBase?.filter { !removedIDs.contains($0.key) }
        gesturePrepared.subtract(removedIDs)
        if focusBorder.windowID.map(removedIDs.contains) == true { focusBorder.hide() }
    }

    func observedFocusChanged(windowID: String) {
        guard isRunning, !isSuspended, !changes.isProcessing, gestureBase == nil,
              windows.contains(where: { $0.id == windowID }), desktopScope.refresh() == .home else { return }
        if windowID == state.focusedWindowID {
            // Activating the already-selected app can raise its window above the
            // still-visible border without changing logical focus.
            if let frame = windowSystem.frame(windowID: windowID) {
                updateFocusBorder(
                    windowID: windowID,
                    frame: frame,
                    refreshShape: false,
                    raiseBorder: true
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
            guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, !self.changes.isProcessing,
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

    func refreshWindows(forceLayout: Bool = false) {
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        applyRefresh(windowSystem.scanWindows(), forceLayout: forceLayout)
    }

    /// Reconciles the workspace with a completed scan.
    /// `forceLayout` lays the ribbon out even when nothing changed, as after
    /// returning to the Desktop, instead of only redrawing the border.
    /// `observedFocusedWindowID` is the focus read with the scan; nil reads it now, on
    /// the main thread, for the synchronous callers (resume, launch, fallbacks).
    func applyRefresh(_ current: [WindowRecord], forceLayout: Bool = false,
                      observedFocusedWindowID observed: String?? = nil) {
        let motionStart = navigationFrames()
        let oldState = state
        windows = current
        // The scan read every frame off the main thread; the next slide starts from them.
        for window in current { knownFrames[window.id] = window.frame }
        workspaceRestoration.reconcile(state: &state, windowIDs: current.map(\.id),
                                       trackedWindowIDs: windowSystem.trackedWindowIDs,
                                       initialWidthFractions: initialWidthFractions(for: current))
        let observedFocusedWindowID = observed ?? windowSystem.focusedWindowID()
        // A window restored from the Dock takes focus even if macOS has not reported it yet.
        let placedRestoredWindow = placeRestoredWindows()
        if !placedRestoredWindow, oldState.activeSpaceIndex == state.activeSpaceIndex,
           let focused = observedFocusedWindowID,
           current.contains(where: { $0.id == focused }) {
            // External app activation follows an existing membership; shared windows stay in this space.
            if !state.currentSpace.windowIDs.contains(focused),
               let space = state.spaces.firstIndex(where: { $0.windowIDs.contains(focused) }) {
                state.apply(.goToSpace(index: space))
            }
            state.focus(windowID: focused)
        }
        // Do not fight a title-bar drag or resize. Observe the window while the
        // mouse is held, then apply its drop to the ribbon after mouse-up. A
        // drag-and-drop moves no window, so the ribbon follows it as usual.
        let dragAndDrop = pointer.isButtonDown && pointer.isDragAndDrop
        if pointer.isButtonDown, !dragAndDrop {
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
        // A deferral begun earlier in this press, before its drag session started,
        // keeps its pending layout but has no window drop to apply.
        let interaction = dragAndDrop ? nil : pointerInteraction
        var needsLayout = pointerInteraction?.needsLayout ?? false
        pointerInteraction = nil
        if let availableFrame {
            let activeWindowIDs = Set(state.currentSpace.windowIDs)
            if let reappeared = current.first(where: { window in
                guard !activeWindowIDs.contains(window.id),
                      let frame = windowSystem.observedFrame(windowID: window.id) else { return false }
                return frame.intersection(availableFrame).width > 64
            }) {
                needsLayout = true
                diagnostics.record("off_space_window_reappeared", details: [
                    "windowID": reappeared.id,
                    "activeSpace": String(state.activeSpaceIndex + 1)
                ])
            }
        }
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
                    preferredHeights[focused.id] = preferredHeightAfterResize(
                        previous: previous, observed: focused.frame, available: frame
                    )
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
                    guard !Task.isCancelled, let self, self.isRunning, !self.isSuspended, !self.changes.isProcessing else { return }
                    self.refreshWindows()
                }
            }
        }
        if oldState != state || needsLayout || (forceLayout && !changes.isProcessing) {
            let removedFromCurrentSpace = Set(oldState.currentSpace.windowIDs)
                .subtracting(current.map(\.id))
            if !removedFromCurrentSpace.isEmpty {
                enqueue(.windowRemoval, transitionFrom: oldState, motionStart: motionStart)
            } else {
                // Preferences layouts follow the old system focus; a restored window must win.
                enqueue(preferencesNeedLayout && !placedRestoredWindow ? .preferences : .refresh)
            }
        } else if preferencesNeedLayout,
                  LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: observedFocusedWindowID) != nil {
            enqueue(.preferences)
        } else if let id = state.focusedWindowID, let frame = knownFrame(windowID: id) {
            updateFocusBorder(windowID: id, frame: frame,
                              raiseBorder: observedFocusedWindowID == id)
        }
        onStateChange?()
    }

    func initialWidthFractions(for windows: [WindowRecord]) -> [String: Double] {
        guard let availableFrame, availableFrame.width.isFinite, availableFrame.width > 0 else { return [:] }
        return Dictionary(windows.compactMap { window in
            guard window.frame.width.isFinite, window.frame.width > 0 else { return nil }
            return (window.id, Double(window.frame.width / availableFrame.width))
        }, uniquingKeysWith: { first, _ in first })
    }
}
