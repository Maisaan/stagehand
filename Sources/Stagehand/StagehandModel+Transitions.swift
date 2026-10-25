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
        if change == .preferences, changes.contains(where: { $0.change == .preferences }) { return }
        // Capture typing before the asynchronous AX activation starts.
        let token = change.policy.beginInputTransfer {
            focusGate.isAvailable ? focusGate.beginTransfer() : nil
        }
        changes.append(PendingChange(
            change: change,
            token: token,
            initialHorizontalVelocity: initialHorizontalVelocity,
            previousState: previousState,
            motionStart: motionStart
        ))
        diagnostics.record("change_queued", details: [
            "operation": change.diagnosticName,
            "pendingChanges": String(changes.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        if change.isWindowNavigation, changes.isProcessing, ribbonMotion.isAnimating {
            ribbonMotion.cancel()
        }
        changes.startIfIdle { [weak self] generation in await self?.processChanges(generation: generation) }
    }

    /// Consecutive navigation steps without typing share one motion from the first start.
    struct NavigationBatch {
        var motionStart: [String: CGRect]?
        var initialHorizontalVelocity: CGFloat?
    }

    private func processChanges(generation: Int) async {
        var batch = NavigationBatch()
        while isRunning, !isSuspended, !Task.isCancelled, let pendingChange = changes.removeFirst() {
            guard await process(pendingChange, batch: &batch, generation: generation) else { return }
        }
        guard changes.finish(generation: generation) else { return }
        onStateChange?()
        scheduleRefresh()
    }

    /// Applies one change. Returns false when processing must end (pause or stale).
    private func process(_ pendingChange: PendingChange, batch: inout NavigationBatch,
                         generation: Int) async -> Bool {
        let change = pendingChange.change
        let token = pendingChange.token
        diagnostics.record("change_started", details: [
            "operation": change.diagnosticName,
            "pendingChanges": String(changes.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        let previousState = pendingChange.previousState
            ?? workspaceRestoration.transitionStart(
                windowIDs: windows.map(\.id),
                trackedWindowIDs: windowSystem.trackedWindowIDs
            )
            ?? state
        workspaceRestoration.beginTransition(from: state)
        let hadPreview = presentationFrames != nil
        let motionStart = pendingChange.motionStart ?? batch.motionStart ?? navigationFrames()
        let initialHorizontalVelocity = batch.initialHorizontalVelocity ?? pendingChange.initialHorizontalVelocity
        ribbonMotion.cancel()
        presentationFrames = nil
        if gestureAxis != nil { input.cancelGestureSequence() }
        resetGestureTracking()
        guard applyToState(change) else {
            if let token { focusGate.cancelTransfer(token: token) }
            workspaceRestoration.endTransition()
            return true
        }
        if change.isWindowNavigation, changes.first?.change.isWindowNavigation == true,
           let token, focusGate.cancelTransferIfEmpty(token: token) {
            // Keep every navigation step in state, but avoid flashing intermediate
            // windows when no typing belongs to them. Never merge input tokens.
            batch = NavigationBatch(motionStart: motionStart, initialHorizontalVelocity: initialHorizontalVelocity)
            return true
        }
        batch = NavigationBatch()
        guard prepareLayoutState(for: change) else {
            workspaceRestoration.endTransition()
            return true
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let canSlide = shouldSlideRibbon(
            from: previousState,
            to: state,
            source: change.ribbonTransitionSource,
            hadPreview: hadPreview,
            reduceMotion: reduceMotion
        )
        recordMotionPlan(change: change, previousState: previousState, hadPreview: hadPreview,
                         motionStartCount: motionStart.count, reduceMotion: reduceMotion, canSlide: canSlide)
        let outcome = await applyLayout(token: token, request: change.policy,
                                        operation: change.diagnosticName,
                                        slideFrom: canSlide ? motionStart : nil,
                                        initialHorizontalVelocity: canSlide ? initialHorizontalVelocity : nil,
                                        focusAlongsideSlide: change.focusesAlongsideRibbon)
        guard changes.isCurrent(generation) else { return false }
        return finish(change, outcome: outcome)
    }

    /// Updates the logical workspace for a change. Returns false when it does nothing.
    private func applyToState(_ change: Change) -> Bool {
        switch change {
        case .action(let action) where action == .shrinkHeight || action == .growHeight:
            return adjustFocusedWindowHeight(growing: action == .growHeight)
        case .action(let action):
            let sourceSpaceIndex = state.activeSpaceIndex
            guard state.apply(action, widthPresets: widthPresets) else { return false }
            if action == .moveWindowUpSpace {
                workspaceRestoration.compactEmptySpace(state: &state, at: sourceSpaceIndex)
            }
        case .remove(let id): state.removeFromCurrentSpace(windowID: id)
        case .share(let id, let index): state.share(windowID: id, toSpace: index)
        case .focus(let id): state.focus(windowID: id)
        case .moveMembership(let id, let sourceIndex, let destinationIndex):
            state.move(windowID: id, fromSpace: sourceIndex, toSpace: destinationIndex)
        case .shareMembership(let id, let sourceIndex, let destinationIndex):
            state.share(windowID: id, fromSpace: sourceIndex, toSpace: destinationIndex)
        case .removeMembership(let id, let sourceIndex):
            state.remove(windowID: id, fromSpace: sourceIndex)
        case .reorderWindow(let id, let index, let spaceIndex):
            state.reorderWindow(windowID: id, to: index, inSpace: spaceIndex)
        case .focusInSpace(let id, let spaceIndex):
            state.focus(windowID: id, inSpace: spaceIndex)
        case .windowRemoval, .refresh, .preferences, .observedFocus: break
        }
        return true
    }

    /// Preference changes lay out around the window macOS reports focused. Returns
    /// false when that focus moved before the layout could start.
    private func prepareLayoutState(for change: Change) -> Bool {
        guard change.policy == .preferences else { return true }
        let focusedWindowID = windowSystem.focusedWindowID()
        let prepared: WorkspaceState?
        if case .observedFocus(let notificationWindowID) = change {
            prepared = prepareObservedFocus(
                state: state,
                notificationWindowID: notificationWindowID,
                focusedWindowID: focusedWindowID
            )
        } else {
            preferencesNeedLayout = true
            prepared = change.policy.prepare(state: state, focusedWindowID: focusedWindowID)
        }
        guard let prepared else {
            if case .observedFocus = change {
                diagnostics.record("change_skipped", details: [
                    "operation": change.diagnosticName,
                    "reason": "focus_changed_before_layout"
                ])
            }
            return false
        }
        preferencesNeedLayout = true
        state = prepared
        return true
    }

    private func recordMotionPlan(change: Change, previousState: WorkspaceState, hadPreview: Bool,
                                  motionStartCount: Int, reduceMotion: Bool, canSlide: Bool) {
        guard change.policy == .navigation, diagnostics.isEnabled else { return }
        let destinationID = state.focusedWindowID
        let observedFocus = windowSystem.lastObservedFocusedWindowID
        let membershipCount = destinationID.map { state.spaces.membershipCount(of: $0) } ?? 0
        diagnostics.record("navigation_motion_planned", details: [
            "destinationFocusedWindowID": destinationID ?? "none",
            "destinationMembershipCount": String(membershipCount),
            "destinationParked": String(destinationID.map { windowSystem.isParked(windowID: $0) } ?? false),
            "destinationSpace": String(state.activeSpaceIndex + 1),
            "destinationWasSystemFocused": String(destinationID != nil && destinationID == observedFocus),
            "hadGesturePreview": String(hadPreview),
            "motionStartWindowCount": String(motionStartCount),
            "observedFocusedWindowID": observedFocus ?? "none",
            "operation": change.diagnosticName,
            "previousFocusedWindowID": previousState.focusedWindowID ?? "none",
            "previousSpace": String(previousState.activeSpaceIndex + 1),
            "reduceMotion": String(reduceMotion),
            "slideEnabled": String(canSlide)
        ])
    }

    /// Records a finished change, or pauses and restores after a failure.
    /// Returns false when processing must end.
    private func finish(_ change: Change, outcome: LayoutOutcome) -> Bool {
        let failureReason: String
        switch outcome {
        case .completed:
            if let focusedWindowID = state.focusedWindowID { focusHistory.record(windowID: focusedWindowID) }
            diagnostics.record("change_completed", details: ["operation": change.diagnosticName])
            if recoveryInProgress && change == .refresh {
                recoveryInProgress = false
                automaticResumeAttempted = false
                diagnostics.record("automatic_resume_succeeded")
            }
            workspaceRestoration.endTransition()
            return true
        case .targetUnavailable(let windowID, let reason):
            // The destination disappeared without a notification. Drop it like any
            // other unavailable window; its removal layout is now pending and keeps
            // this transition's rollback.
            if dropUnavailableWindow(windowID, reason: reason, detectedBy: "focus") { return true }
            failureReason = "focus_target_unavailable"
        case .failed(let reason):
            failureReason = reason
        case .interrupted:
            // Interruptions normally end this worker's generation first.
            failureReason = "layout_stopped_unexpectedly"
        }
        workspaceRestoration.rollBack(state: &state, windowIDs: windows.map(\.id),
                                      trackedWindowIDs: windowSystem.trackedWindowIDs)
        stop(reason: failureReason, automatic: true, details: ["operation": change.diagnosticName])
        return false
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

    /// The built-in display, or nil when the lid is closed or the Mac has none.
    /// Stagehand manages only that display (README), so there is no fallback to
    /// an external one.
    static func builtInDisplay() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    var builtInScreen: NSScreen? { builtInScreenProvider() }

    static let missingDisplayWarning = "Stagehand paused because the built-in display is unavailable. It manages only the built-in display, so it restored your windows. Press Start once the display is back."

    /// Pauses if the built-in display is still missing after display changes settled.
    func pauseIfBuiltInDisplayMissing() {
        guard isRunning, !isSuspended else { return }
        guard builtInScreen == nil else {
            enqueue(.preferences)
            return
        }
        stop(reason: "built_in_display_unavailable", automatic: false,
             details: ["screenCount": String(NSScreen.screens.count)])
        warning = Self.missingDisplayWarning
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
            "remnantWidth": String(Double(parkedRemnantWidth(forBundleIdentifier: window.bundleIdentifier))),
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
        // Diagnostics use the focus already observed; a new read would wait on the
        // outgoing app, on the main thread, before the attempt even starts.
        let observedFocusBefore = diagnostics.isEnabled ? windowSystem.lastObservedFocusedWindowID : nil
        let confirmation = await request.confirmFocus(
            windowID: record.id,
            currentFocus: { windowSystem.focusedWindowID() },
            activate: { await windowSystem.focus(windowID: record.id) },
            unavailability: { windowSystem.unavailability(windowID: record.id) },
            isParked: { windowSystem.isParked(windowID: record.id) }
        )
        let focused = confirmation == .focused
        if request == .navigation, diagnostics.isEnabled {
            // A confirmed focus already observed the target. Avoid another
            // synchronous AX read while the newly active app may still be busy.
            let observedFocusAfter = focused ? record.id : windowSystem.lastObservedFocusedWindowID
            var details = [
                "focusConfirmed": String(focused),
                "membershipCount": String(state.spaces.membershipCount(of: record.id)),
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
        lastFocusTokenExpired = token.map { expiredTokens.remove($0) != nil } ?? false
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
        }
        guard isRunning, !isSuspended, !Task.isCancelled else {
            if let token { focusGate.cancelTransfer(token: token) }
            return .interrupted
        }
        guard focused else {
            if let token { focusGate.cancelTransfer(token: token) }
            if case .unavailable(let reason) = confirmation {
                return .targetUnavailable(windowID: record.id, reason: reason)
            }
            warning = "Stagehand couldn't focus \(record.appName). It paused and restored your windows. Check for an open dialog or changed permissions."
            var details = [
                "bundleIdentifier": record.bundleIdentifier,
                "focusConfirmed": String(focused),
                "pid": String(record.pid),
                "transferExpired": String(lastFocusTokenExpired),
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
                lastLayoutMilliseconds = layoutStart.duration(to: .now).wholeMilliseconds
                if request == .navigation { emptySpace.hide() }
                if slideFrom == nil {
                    if request == .navigation, pass == 0 {
                        // Show the destination at once: raise it and clear the outgoing
                        // windows before the slow part, the app's activation. Waiting
                        // for activation kept the old space on screen until it finished.
                        windowSystem.raiseWithoutActivating(windowID: record.id)
                        let shownIDs = Set(placements.filter(\.isVisible).map(\.windowID))
                        let frames = Dictionary(placements.map { ($0.windowID, $0.frame) },
                                                uniquingKeysWith: { first, _ in first })
                        switch await parkHiddenWindows(keeping: shownIDs, layoutFrames: frames) {
                        case .interrupted: return .interrupted
                        case .failed(let details): return failLayout("window_parking_failed", details: details)
                        case .completed: break
                        }
                    }
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
        let sliding = placements.filter {
            $0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true
        }
        let animatedWindowIDs = slideFrom == nil ? Set<String>() : Set(sliding.map(\.windowID))
        guard preferenceFocusStillMatches(request) else { return .completed }
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
        }
        let placementFrames = Dictionary(placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
        switch await parkHiddenWindows(keeping: visibleIDs.union(animatedWindowIDs), layoutFrames: placementFrames) {
        case .interrupted: return .interrupted
        case .failed(let details): return failLayout("window_parking_failed", details: details)
        case .completed: break
        }
        guard preferenceFocusStillMatches(request) else { return .completed }
        preferencesNeedLayout = false
        if slideFrom != nil {
            let starts = Dictionary(sliding.compactMap { placement in
                windowSystem.frame(windowID: placement.windowID).map { (placement.windowID, $0) }
            }, uniquingKeysWith: { first, _ in first })
            let targets = Dictionary(sliding.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
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
                guard self.changes.count > 0 else { return RibbonTranslationOutcome.readyForFocus }
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
            // Motion-first navigation activates the destination only as the slide
            // ends. Raise it now so it slides in on top instead of popping forward.
            if !focusAlongsideSlide, let focusedID = state.focusedWindowID {
                windowSystem.raiseWithoutActivating(windowID: focusedID)
            }
            let outcome = if focusAlongsideSlide {
                await runConcurrentNavigation(
                    revealBorderFirst: false,
                    translate: translate,
                    cancelTranslation: { self.ribbonMotion.cancel() },
                    focus: focus,
                    focusConfirmed: focusConfirmed,
                    commitInput: commitInput,
                    revealBorder: revealBorder
                )
            } else {
                await runMotionFirstNavigation(
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
            if !focusAlongsideSlide, let focusedID = state.focusedWindowID {
                // An app can resize its window while activating. Correct it now that
                // the motion has ended. Each frame read is a blocking AX round trip,
                // so read once and again only after a write.
                var frame = windowSystem.frame(windowID: focusedID)
                if let target = placements.first(where: { $0.windowID == focusedID })?.frame,
                   let actual = frame, !framesMatch(observed: actual, target: target) {
                    _ = windowSystem.setFrame(windowID: focusedID, frame: target)
                    frame = windowSystem.frame(windowID: focusedID)
                    lastAppliedFrames[focusedID] = frame
                }
                if let frame { updateFocusBorder(windowID: focusedID, frame: frame, raiseBorder: true) }
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
        let actual = Dictionary(windows.filter { members.contains($0.id) }.compactMap { window in
            windowSystem.frame(windowID: window.id).map { (window.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let placements = WindowLayout.placements(for: state, availableFrame: availableFrame, gap: gap,
                                                 observedWidths: actual.mapValues(\.width),
                                                 observedHeights: actual.mapValues(\.height))
        var frames = Dictionary(placements.map {
            ($0.windowID, $0.isVisible ? actual[$0.windowID] ?? $0.frame : $0.frame)
        }, uniquingKeysWith: { first, _ in first })
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
            let remnantWidth = parkedRemnantWidth(forBundleIdentifier: window.bundleIdentifier)
            let parking = await parkWindow(
                windowID: window.id,
                park: { windowSystem.park(windowID: $0, preferredSide: parkingSide, remnantWidth: remnantWidth) },
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
                    + (remnantWidth > WindowTuning.parkedRemnantWidth ? ""
                       : " If \(window.appName) keeps its windows on screen, allow it a wider parked edge in Settings > Layout.")
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
            setPosition: { windowSystem.setMotionPosition(windowID: $0, position: $1) }
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
        _ = windowSystem.motionWriteStatistics(reset: true, focusedWindowID: nil)
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
        guard completed else { return false }
        // Let the last motion writes land so the commit reads settled positions.
        await windowSystem.finishMotionWrites()
        guard isRunning, !isSuspended, !Task.isCancelled, desktopScope.refresh() == .home else { return false }
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
            diagnostics.record("ribbon_animation_completed", details: windowSystem.motionWriteStatistics(reset: false, focusedWindowID: state.focusedWindowID).merging([
                "elapsedMilliseconds": String(elapsedMilliseconds),
                "focusedWindowID": state.focusedWindowID ?? "none",
                "observedFocusedWindowID": windowSystem.lastObservedFocusedWindowID ?? "none",
                "operation": operation,
                "windowCount": String(to.count)
            ]) { _, new in new })
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
