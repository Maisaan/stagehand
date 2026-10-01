import AppKit
import StagehandCore
import StagehandPlatform

/// Reactions to windows and apps changing outside a layout pass.
extension StagehandModel {
    func scheduleRefresh(immediately: Bool = false) {
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
        removeFromRibbon(forgetFocus: false, event: "window_unavailable", remove: {
            removeUnavailableWindow(
                windowID: windowID, windows: &windows, state: &state,
                restoration: &workspaceRestoration, trackedWindowIDs: windowSystem.trackedWindowIDs
            ) ? [windowID] : []
        }, details: { _ in ["windowID": windowID, "reason": "minimized"] })
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
        if state.currentSpace.windowIDs.contains(windowID) {
            state.focus(windowID: windowID)
        } else if let spaceIndex = state.spaces.firstIndex(where: { $0.windowIDs.contains(windowID) }) {
            state.focus(windowID: windowID, inSpace: spaceIndex)
        }
        diagnostics.record("window_available", details: ["windowID": windowID, "reason": "restored"])
        enqueue(.refresh)
        onStateChange?()
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
        motionWrittenPositions = motionWrittenPositions.filter { !removedIDs.contains($0.key) }
        presentationFrames = presentationFrames?.filter { !removedIDs.contains($0.key) }
        gestureBase = gestureBase?.filter { !removedIDs.contains($0.key) }
        gesturePrepared.subtract(removedIDs)
        if focusBorder.windowID.map(removedIDs.contains) == true { focusBorder.hide() }
    }

    func observedFocusChanged(windowID: String) {
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

    func refreshWindows() {
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
        let observedFocusedWindowID = windowSystem.focusedWindowID()
        if oldState.activeSpaceIndex == state.activeSpaceIndex,
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
                  LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: observedFocusedWindowID) != nil {
            enqueue(.preferences)
        } else if let id = state.focusedWindowID, let frame = windowSystem.frame(windowID: id) {
            updateFocusBorder(windowID: id, frame: frame,
                              raiseBorder: observedFocusedWindowID == id)
        }
        onStateChange?()
    }

    func initialWidthFractions(for windows: [WindowRecord]) -> [String: Double] {
        guard let availableFrame, availableFrame.width.isFinite, availableFrame.width > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            guard window.frame.width.isFinite, window.frame.width > 0 else { return nil }
            return (window.id, Double(window.frame.width / availableFrame.width))
        })
    }
}
