import AppKit
import StagehandCore
import StagehandPlatform

/// The change queue and the layout, focus, parking, and ribbon motion of each change.
extension StagehandModel {
    func enqueue(
        _ change: Change,
        initialHorizontalVelocity: CGFloat? = nil,
        transitionFrom previousState: WorkspaceState? = nil,
        motionStart: [String: CGRect]? = nil
    ) {
        if traceGestures, gestureAxis != nil {
            NSLog("[DEBUG-gesture] layout requested during drag: %@", String(describing: change))
        }
        guard isRunning, !isSuspended else { return }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return
        }
        if change == .preferences, pending.contains(where: { $0.change == .preferences }) { return }
        // Capture typing before the asynchronous AX activation starts.
        let token = change.policy.beginInputTransfer {
            focusGate.isAvailable ? focusGate.beginTransfer() : nil
        }
        pending.append(PendingChange(
            change: change,
            token: token,
            initialHorizontalVelocity: initialHorizontalVelocity,
            previousState: previousState,
            motionStart: motionStart
        ))
        diagnostics.record("change_queued", details: [
            "operation": change.diagnosticName,
            "pendingChanges": String(pending.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        if change.isWindowNavigation, worker != nil, ribbonMotion.isAnimating {
            ribbonMotion.cancel()
        }
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            guard let self else { return }
            var batchMotionStart: [String: CGRect]?
            var batchInitialHorizontalVelocity: CGFloat?
            while self.isRunning && !self.isSuspended && !Task.isCancelled && !self.pending.isEmpty {
                let pendingChange = self.pending.removeFirst()
                let change = pendingChange.change
                let token = pendingChange.token
                self.diagnostics.record("change_started", details: [
                    "operation": change.diagnosticName,
                    "pendingChanges": String(self.pending.count),
                    "transferToken": token.map(String.init) ?? "none"
                ])
                let previousState = pendingChange.previousState
                    ?? self.workspaceRestoration.transitionStart(
                        windowIDs: self.windows.map(\.id),
                        trackedWindowIDs: self.windowSystem.trackedWindowIDs
                    )
                    ?? self.state
                self.workspaceRestoration.beginTransition(from: self.state)
                let hadPreview = self.presentationFrames != nil
                let motionStart = pendingChange.motionStart ?? batchMotionStart ?? self.navigationFrames()
                let initialHorizontalVelocity = batchInitialHorizontalVelocity
                    ?? pendingChange.initialHorizontalVelocity
                self.ribbonMotion.cancel()
                self.presentationFrames = nil
                if self.gestureAxis != nil { self.input.cancelGestureSequence() }
                self.resetGestureTracking()
                switch change {
                case .action(let action) where action == .shrinkHeight || action == .growHeight:
                    guard self.adjustFocusedWindowHeight(growing: action == .growHeight) else {
                        if let token { self.focusGate.cancelTransfer(token: token) }
                        self.workspaceRestoration.endTransition()
                        continue
                    }
                case .action(let action):
                    let sourceSpaceIndex = self.state.activeSpaceIndex
                    guard self.state.apply(action) else {
                        if let token { self.focusGate.cancelTransfer(token: token) }
                        self.workspaceRestoration.endTransition()
                        continue
                    }
                    if action == .moveWindowUpSpace {
                        self.workspaceRestoration.compactEmptySpace(
                            state: &self.state, at: sourceSpaceIndex
                        )
                    }
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
                case .windowRemoval, .refresh, .preferences, .observedFocus: break
                }
                if change.isWindowNavigation, self.pending.first?.change.isWindowNavigation == true,
                   let token, self.focusGate.cancelTransferIfEmpty(token: token) {
                    // Keep every navigation step in state, but avoid flashing intermediate
                    // windows when no typing belongs to them. Never merge input tokens.
                    batchMotionStart = motionStart
                    batchInitialHorizontalVelocity = initialHorizontalVelocity
                    continue
                }
                batchMotionStart = nil
                batchInitialHorizontalVelocity = nil
                if change.policy == .preferences {
                    let focusedWindowID = self.windowSystem.focusedWindowID()
                    let prepared: WorkspaceState?
                    if case .observedFocus(let notificationWindowID) = change {
                        prepared = prepareObservedFocus(
                            state: self.state,
                            notificationWindowID: notificationWindowID,
                            focusedWindowID: focusedWindowID
                        )
                    } else {
                        self.preferencesNeedLayout = true
                        prepared = change.policy.prepare(state: self.state, focusedWindowID: focusedWindowID)
                    }
                    guard let prepared else {
                        if case .observedFocus = change {
                            self.diagnostics.record("change_skipped", details: [
                                "operation": change.diagnosticName,
                                "reason": "focus_changed_before_layout"
                            ])
                        }
                        self.workspaceRestoration.endTransition()
                        continue
                    }
                    self.preferencesNeedLayout = true
                    self.state = prepared
                }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let canSlide = shouldSlideRibbon(
                    from: previousState,
                    to: self.state,
                    source: change.ribbonTransitionSource,
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
                let outcome = await self.applyLayout(token: token, request: change.policy,
                                                       operation: change.diagnosticName,
                                                       slideFrom: canSlide ? motionStart : nil,
                                                       initialHorizontalVelocity: canSlide
                                                        ? initialHorizontalVelocity : nil,
                                                       focusAlongsideSlide: change.focusesAlongsideRibbon)
                guard generation == self.workerGeneration, !Task.isCancelled else { return }
                let failureReason: String
                switch outcome {
                case .completed:
                    failureReason = ""
                case .targetUnavailable(let windowID, let reason):
                    // The destination disappeared without a notification. Drop it like
                    // any other unavailable window; its removal layout is now pending.
                    if self.dropUnavailableWindow(windowID, reason: reason, detectedBy: "focus") { continue }
                    failureReason = "focus_target_unavailable"
                case .failed(let reason):
                    failureReason = reason
                case .interrupted:
                    // Interruptions normally end this worker's generation above.
                    failureReason = "layout_stopped_unexpectedly"
                }
                guard outcome == .completed else {
                    self.workspaceRestoration.rollBack(
                        state: &self.state,
                        windowIDs: self.windows.map(\.id),
                        trackedWindowIDs: self.windowSystem.trackedWindowIDs
                    )
                    self.stop(
                        reason: failureReason,
                        automatic: true,
                        details: ["operation": change.diagnosticName]
                    )
                    return
                }
                if let focusedWindowID = self.state.focusedWindowID {
                    self.focusHistory.record(windowID: focusedWindowID)
                }
                self.diagnostics.record("change_completed", details: ["operation": change.diagnosticName])
                if self.recoveryInProgress && change == .refresh {
                    self.recoveryInProgress = false
                    self.automaticResumeAttempted = false
                    self.diagnostics.record("automatic_resume_succeeded")
                }
                self.workspaceRestoration.endTransition()
            }
            guard generation == self.workerGeneration, !Task.isCancelled else { return }
            self.worker = nil
            self.onStateChange?()
            self.scheduleRefresh()
        }
    }

    func adjustFocusedWindowHeight(growing: Bool) -> Bool {
        guard let windowID = state.focusedWindowID,
              let availableFrame else { return false }
        let currentHeight = windowSystem.frame(windowID: windowID)?.height
            ?? preferredHeights[windowID]
            ?? availableFrame.height
        guard let height = adjustedWindowHeight(
            current: currentHeight,
            available: availableFrame.height,
            growing: growing
        ) else { return false }
        preferredHeights[windowID] = height
        return true
    }

    var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.main
    }

    var availableFrame: CGRect? {
        guard let screen = builtInScreen, let primary = NSScreen.screens.first else { return nil }
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    func failLayout(_ reason: String, details: [String: String] = [:]) -> LayoutOutcome {
        var context = workspaceDetails()
        context["reason"] = reason
        context.merge(details) { _, new in new }
        diagnostics.record("layout_failed", details: context)
        return .failed(reason: reason)
    }

    func parkingFailureDetails(window: WindowRecord, preferredSide: WindowParkingSide?) -> [String: String] {
        var details = [
            "bundleIdentifier": window.bundleIdentifier,
            "pid": String(window.pid),
            "windowID": window.id,
            "preferredSide": preferredSide == .left ? "left" : preferredSide == .right ? "right" : "none",
            "parked": String(windowSystem.isParked(windowID: window.id))
        ]
        if let frame = windowSystem.observedFrame(windowID: window.id) {
            details["observedX"] = String(Double(frame.minX))
            details["observedY"] = String(Double(frame.minY))
            details["observedWidth"] = String(Double(frame.width))
            details["observedHeight"] = String(Double(frame.height))
        }
        return details
    }

    func focusManagedWindow(_ record: WindowRecord, token: UInt64?,
                                    request: LayoutRequestPolicy, operation: String) async -> LayoutOutcome {
        let observedFocusBefore = diagnostics.isEnabled ? windowSystem.focusedWindowID() : nil
        let confirmation = await request.confirmFocus(
            windowID: record.id,
            currentFocus: { windowSystem.focusedWindowID() },
            activate: { await windowSystem.focus(windowID: record.id) },
            unavailability: { windowSystem.unavailability(windowID: record.id) }
        )
        let focused = confirmation == .focused
        if request == .navigation, diagnostics.isEnabled {
            // A confirmed focus already observed the target. Avoid another
            // synchronous AX read while the newly active app may still be busy.
            let observedFocusAfter = focused ? record.id : windowSystem.focusedWindowID()
            var details = [
                "focusConfirmed": String(focused),
                "membershipCount": String(state.spaces.count { $0.windowIDs.contains(record.id) }),
                "observedFocusedWindowIDAfter": observedFocusAfter ?? "none",
                "observedFocusedWindowIDBefore": observedFocusBefore ?? "none",
                "operation": operation,
                "parkedAfter": String(windowSystem.isParked(windowID: record.id)),
                "systemFocusedAfter": String(observedFocusAfter == record.id),
                "systemFocusedBefore": String(observedFocusBefore == record.id),
                "windowID": record.id
            ]
            if observedFocusBefore != record.id, let report = windowSystem.lastFocusReport {
                details["focusReport"] = report.summary
            }
            diagnostics.record("navigation_focus_confirmed", details: details)
        }
        if request == .preferences, !focused { return .completed }
        lastFocusTokenExpired = token.map { expiredTokens.contains($0) } ?? false
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
        }
        guard isRunning, !isSuspended, !Task.isCancelled else {
            if let token { focusGate.cancelTransfer(token: token) }
            return .interrupted
        }
        guard focused, token.map({ expiredTokens.contains($0) }) != true else {
            if let token { focusGate.cancelTransfer(token: token) }
            if case .unavailable(let reason) = confirmation {
                return .targetUnavailable(windowID: record.id, reason: reason)
            }
            warning = "Stagehand couldn't focus \(record.appName). It paused and restored your windows. Check for an open dialog or changed permissions."
            var details = [
                "bundleIdentifier": record.bundleIdentifier,
                "focusConfirmed": String(focused),
                "pid": String(record.pid),
                "transferExpired": String(token.map { expiredTokens.contains($0) } ?? false),
                "windowID": record.id
            ]
            if let report = windowSystem.lastFocusReport { details["focusReport"] = report.summary }
            return failLayout("focus_confirmation_failed", details: details)
        }
        return .completed
    }

    func applyLayout(token: UInt64?, request: LayoutRequestPolicy, operation: String,
                             slideFrom: [String: CGRect]? = nil,
                             initialHorizontalVelocity: CGFloat? = nil,
                             focusAlongsideSlide: Bool = false) async -> LayoutOutcome {
        let layoutStart = ContinuousClock.now
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
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
        // Capture a new window's preferred height before the first managed size write.
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
        // Read accepted sizes after focus, then repack and center app-constrained windows.
        // Repacking may reveal another window. Bound this by the number of windows;
        // the input gate's deadline also applies to the whole transition.
        let maximumPass = state.currentSpace.windowIDs.count
        for pass in 0...maximumPass {
            guard preferenceFocusStillMatches(request) else { return .completed }
            placements = WindowLayout.placements(for: state, availableFrame: availableFrame, gap: gap,
                                                 observedWidths: observedWidths, preferredHeights: preferredHeights,
                                                 observedHeights: observedHeights)
            let visible = placements.filter { $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true }
            // Position neighbors first. Raising the focused real window last keeps clamped neighbors behind it.
            for placement in visible.sorted(by: { !$0.isFocused && $1.isFocused }) {
                // A correction pass only writes windows whose geometry actually changed.
                var preparedFrame = placement.frame
                if let start = slideFrom?[placement.windowID] { preparedFrame.origin.x = start.minX }
                if pass > 0, acceptedFrames[placement.windowID] == preparedFrame { continue }
                if !windowSystem.isParked(windowID: placement.windowID),
                   let current = windowSystem.frame(windowID: placement.windowID),
                   framesMatch(observed: current, target: preparedFrame) {
                    acceptedFrames[placement.windowID] = current
                    lastAppliedFrames[placement.windowID] = current
                    continue
                }
                let frameWritten = windowSystem.setFrame(windowID: placement.windowID, frame: preparedFrame)
                let actualFrame = windowSystem.frame(windowID: placement.windowID)
                if !frameWritten, placement.isFocused {
                    recordWindowGeometry(
                        event: "frame_write_constrained",
                        windowID: placement.windowID,
                        requestedFrame: preparedFrame,
                        actualFrame: actualFrame,
                        details: ["pass": String(pass + 1)]
                    )
                }
                lastAppliedFrames[placement.windowID] = actualFrame
            }
            if let focusedID = state.focusedWindowID,
               let record = windows.first(where: { $0.id == focusedID }) {
                let preparation = layoutStart.duration(to: .now).components
                lastLayoutMilliseconds = Int(preparation.seconds * 1_000 + preparation.attoseconds / 1_000_000_000_000_000)
                if request == .navigation { emptySpace.hide() }
                if slideFrom == nil {
                    let focus = await focusManagedWindow(record, token: token, request: request, operation: operation)
                    guard focus == .completed else { return focus }
                    destinationPID = record.pid
                }
                var constrained = false
                for placement in visible {
                    guard let actual = windowSystem.frame(windowID: placement.windowID) else { continue }
                    acceptedFrames[placement.windowID] = actual
                    var constrainedAxes: [String] = []
                    if actual.width.isFinite, actual.width > 0,
                       abs(actual.width - placement.frame.width) > 1 {
                        observedWidths[placement.windowID] = actual.width
                        state.setWidthFraction(actual.width / availableFrame.width, for: placement.windowID)
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
            } else {
                guard request == .navigation else { return .completed }
                // An empty space owns a real blank window so typing cannot leak to a parked app.
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return .interrupted
                }
                let focused = await emptySpace.show(space: state.activeSpaceIndex + 1, frame: availableFrame)
                guard desktopScope.refresh() == .home else {
                    nativeDesktopChanged()
                    return .interrupted
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
        let visibleIDs = Set(placements.filter(\.isVisible).map(\.windowID))
        let motionCandidates = placements.filter {
            $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true
        }
        let sliding = motionCandidates
        let animatedWindowIDs = slideFrom == nil ? Set<String>() : Set(sliding.map(\.windowID))
        guard preferenceFocusStillMatches(request) else { return .completed }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
        }
        let placementFrames = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
        switch await parkHiddenWindows(keeping: visibleIDs.union(animatedWindowIDs), layoutFrames: placementFrames) {
        case .interrupted: return .interrupted
        case .failed(let details): return failLayout("window_parking_failed", details: details)
        case .completed: break
        }
        guard preferenceFocusStillMatches(request) else { return .completed }
        preferencesNeedLayout = false
        if slideFrom != nil {
            let starts = Dictionary(uniqueKeysWithValues: sliding.compactMap { placement in
                windowSystem.frame(windowID: placement.windowID).map { (placement.windowID, $0) }
            })
            let targets = Dictionary(uniqueKeysWithValues: sliding.map { ($0.windowID, $0.frame) })
            let translate = {
                let completed = await self.settleRibbon(
                    from: starts,
                    to: targets,
                    visibleIDs: visibleIDs,
                    operation: operation,
                    initialHorizontalVelocity: initialHorizontalVelocity
                )
                if completed { return RibbonTranslationOutcome.readyForFocus }
                guard self.isRunning, !self.isSuspended, !Task.isCancelled else {
                    return RibbonTranslationOutcome.failed
                }
                guard !self.pending.isEmpty else { return RibbonTranslationOutcome.readyForFocus }
                guard let token else { return RibbonTranslationOutcome.superseded }
                return self.focusGate.cancelTransferIfEmpty(token: token)
                    ? RibbonTranslationOutcome.superseded : RibbonTranslationOutcome.readyForFocus
            }
            var focusOutcome = LayoutOutcome.completed
            let focus = {
                guard let focusedID = self.state.focusedWindowID,
                      let record = self.windows.first(where: { $0.id == focusedID }) else {
                    focusOutcome = self.failLayout("focus_target_missing")
                    return false
                }
                focusOutcome = await self.focusManagedWindow(
                    record, token: token, request: request, operation: operation
                )
                guard focusOutcome == .completed else { return false }
                destinationPID = record.pid
                guard !focusAlongsideSlide else { return true }
                // The newly active app may still be busy. Each frame read is a
                // blocking AX round trip, so read once and again only after a write.
                var frame = self.windowSystem.frame(windowID: focusedID)
                if let target = placements.first(where: { $0.windowID == focusedID })?.frame,
                   let actual = frame, !framesMatch(observed: actual, target: target) {
                    _ = self.windowSystem.setFrame(windowID: focusedID, frame: target)
                    frame = self.windowSystem.frame(windowID: focusedID)
                    self.lastAppliedFrames[focusedID] = frame
                }
                if let frame {
                    self.updateFocusBorder(windowID: focusedID, frame: frame, raiseBorder: true)
                }
                return true
            }
            let focusConfirmed = {
                if request == .navigation {
                    self.overlays.showNavigation(state: self.state, windows: self.windows)
                }
            }
            let commitInput = {
                if let token, let destinationPID {
                    self.focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                }
            }
            let revealBorder = {
                if let focused = self.state.focusedWindowID,
                   let frame = self.windowSystem.frame(windowID: focused) {
                    self.updateFocusBorder(windowID: focused, frame: frame)
                } else {
                    self.focusBorder.hide()
                }
            }
            let outcome = if focusAlongsideSlide {
                await runConcurrentRemovalNavigation(
                    translate: translate,
                    cancelTranslation: { self.ribbonMotion.cancel() },
                    focus: focus,
                    focusConfirmed: focusConfirmed,
                    commitInput: commitInput,
                    revealBorder: revealBorder
                )
            } else {
                await runFocusFirstNavigation(
                    translate: translate,
                    focus: focus,
                    focusConfirmed: focusConfirmed,
                    commitInput: commitInput,
                    revealBorder: revealBorder
                )
            }
            switch outcome {
            case .superseded: return .completed
            case .failed: return focusOutcome == .completed ? .interrupted : focusOutcome
            case .completed: break
            }
            if token != nil, destinationPID != nil {
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return .interrupted }
            }
        } else {
            lastTransition = Date()
            if let token, let destinationPID {
                focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                // Posting to a process is asynchronous, not an OS delivery acknowledgement.
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return .interrupted }
            }
            if let focused = state.focusedWindowID, let frame = windowSystem.frame(windowID: focused) {
                updateFocusBorder(windowID: focused, frame: frame, raiseBorder: true)
            } else {
                focusBorder.hide()
            }
        }
        overlays.setBorderColor(focusBorderColor)
        if request == .navigation { overlays.showNavigation(state: state, windows: windows) }
        else { overlays.updateNavigation(state: state, windows: windows) }
        return .completed
    }

    func navigationFrames() -> [String: CGRect] {
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

    enum HiddenWindowParking {
        case completed
        case interrupted
        case failed(details: [String: String])
    }

    /// Parks every managed window outside `keeping`, on the side its layout frame
    /// falls. A window that turns out to be minimized or closed leaves the ribbon.
    func parkHiddenWindows(keeping keptIDs: Set<String>,
                                   layoutFrames: [String: CGRect]) async -> HiddenWindowParking {
        let bounds = availableFrame
        for window in windows where !keptIDs.contains(window.id) {
            let parkingSide = bounds.flatMap {
                preferredParkingSide(for: layoutFrames[window.id], relativeTo: $0)
            }
            let parking = await parkWindow(
                windowID: window.id,
                park: { windowSystem.park(windowID: $0, preferredSide: parkingSide) },
                observedFrame: { windowSystem.observedFrame(windowID: $0) },
                unavailability: { windowSystem.unavailability(windowID: $0) },
                canRetry: { self.isRunning && !self.isSuspended && self.desktopScope.refresh() == .home }
            )
            guard isRunning, !isSuspended, !Task.isCancelled else { return .interrupted }
            guard desktopScope.refresh() == .home else {
                nativeDesktopChanged()
                return .interrupted
            }
            switch parking {
            case .unavailable(let reason):
                dropUnavailableWindow(window.id, reason: reason, detectedBy: "parking")
            case .failed:
                warning = "Stagehand couldn't move \(window.appName) out of this space. It paused and restored your windows."
                return .failed(details: parkingFailureDetails(window: window, preferredSide: parkingSide))
            case .parked, .deferred:
                break
            }
        }
        return .completed
    }

    func applyMotionFrames(_ frames: [String: CGRect]) {
        guard isRunning, !isSuspended, desktopScope.relation == .home else {
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
        writeRibbonPositions(
            frames: frames,
            writtenPositions: &motionWrittenPositions,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) }
        )
        // The border is a Stagehand overlay, so it can follow the destination at
        // display cadence without activating that app or disturbing ribbon motion.
        if gestureBase == nil,
           let focused = state.focusedWindowID,
           focusBorder.windowID == focused,
           var frame = frames[focused] {
            frame.origin = motionWrittenPositions[focused]
                ?? RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: motionBackingScaleFactor)
            // Motion is horizontal, so the shape cannot change. An unresolved radius
            // would otherwise query WindowServer on every display tick.
            updateFocusBorder(windowID: focused, frame: frame, refreshShape: false)
        }
    }

    func settleRibbon(from: [String: CGRect], to: [String: CGRect], visibleIDs: Set<String>,
                              operation: String, initialHorizontalVelocity: CGFloat? = nil) async -> Bool {
        motionBackingScaleFactor = builtInScreen?.backingScaleFactor ?? 1
        motionWrittenPositions = from.mapValues {
            RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
        }
        var animationConfiguration = ribbonAnimationConfiguration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animationConfiguration.duration = 0 }
        if diagnostics.isEnabled {
            diagnostics.record("ribbon_animation_started", details: [
                "curve": animationConfiguration.curve.diagnosticDescription,
                "durationMilliseconds": String(Int((animationConfiguration.duration * 1_000).rounded())),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "initialHorizontalVelocity": initialHorizontalVelocity.map { String(Double($0)) } ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ])
        }
        let animationStart = ProcessInfo.processInfo.systemUptime
        let completed = await ribbonMotion.animate(
            from: from,
            to: to,
            configuration: animationConfiguration,
            initialHorizontalVelocity: initialHorizontalVelocity,
            update: { [weak self] in self?.applyMotionFrames($0) }
        )
        guard completed, isRunning, !isSuspended, desktopScope.refresh() == .home else { return false }
        var visibleFrames = to.filter { visibleIDs.contains($0.key) }
        var commitFailures = commitRibbonPositions(
            frames: visibleFrames,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
            observedFrame: { windowSystem.observedFrame(windowID: $0) }
        )
        for delay in [8, 24, 56] where !commitFailures.isEmpty {
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { return false }
            guard isRunning, !isSuspended, !Task.isCancelled,
                  desktopScope.refresh() == .home else { return false }
            let failedIDs = Set(commitFailures.map(\.windowID))
            visibleFrames = visibleFrames.filter { failedIDs.contains($0.key) }
            commitFailures = commitRibbonPositions(
                frames: visibleFrames,
                backingScaleFactor: motionBackingScaleFactor,
                setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
                observedFrame: { windowSystem.observedFrame(windowID: $0) }
            )
        }
        if let failure = commitFailures.first {
            recordWindowGeometry(
                event: "ribbon_position_commit_failed",
                windowID: failure.windowID,
                requestedFrame: failure.requestedFrame,
                actualFrame: failure.actualFrame,
                details: ["attempts": "4"]
            )
            // Motion ends here without pausing. Rewrite the ribbon with verified frame
            // writes and parking so no window stays outside its slot.
            enqueue(.refresh)
            return false
        }
        if diagnostics.isEnabled {
            let elapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - animationStart) * 1_000).rounded())
            diagnostics.record("ribbon_animation_completed", details: [
                "elapsedMilliseconds": String(elapsedMilliseconds),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ])
        }
        switch await parkHiddenWindows(keeping: visibleIDs, layoutFrames: to) {
        case .interrupted: return false
        case .failed(let details):
            stop(reason: "ribbon_parking_failed", automatic: true, details: details)
            return false
        case .completed: break
        }
        for id in visibleIDs { lastAppliedFrames[id] = windowSystem.frame(windowID: id) }
        lastTransition = Date()
        return true
    }

    func preferenceFocusStillMatches(_ request: LayoutRequestPolicy) -> Bool {
        request == .navigation || (state.focusedWindowID != nil && windowSystem.focusedWindowID() == state.focusedWindowID)
    }

    func updateFocusBorder(
        windowID: String,
        frame: CGRect,
        refreshShape: Bool = true,
        raiseBorder: Bool = false
    ) {
        focusBorder.show(windowID: windowID, frame: frame, color: focusBorderColor,
                         refreshShape: refreshShape, raise: raiseBorder)
    }
}
