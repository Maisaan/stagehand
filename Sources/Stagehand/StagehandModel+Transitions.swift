import AppKit
import StagehandCore
import StagehandPlatform

/// The change queue and the layout, focus, parking, and ribbon motion of each change.
extension StagehandModel {
    func enqueue(
        _ change: Change,
        initialHorizontalVelocity: CGFloat? = nil,
        transitionFrom previousState: WorkspaceState? = nil,
        motionStart: [String: CGRect]? = nil,
        gestureID: Int? = nil,
        crossingDisplays: Bool = false
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
        lastChangeID += 1
        changes.append(PendingChange(
            id: lastChangeID,
            change: change,
            token: token,
            initialHorizontalVelocity: initialHorizontalVelocity,
            previousState: previousState,
            motionStart: motionStart,
            trace: ChangeTrace(input: InputArrival.beingDelivered),
            crossesDisplays: crossingDisplays
        ))
        var queuedDetails = [
            "changeID": String(lastChangeID),
            "operation": change.diagnosticName,
            "origin": gestureID == nil ? change.diagnosticOrigin : "gesture",
            "pendingChanges": String(changes.count),
            "transferToken": token.map(String.init) ?? "none"
        ]
        if let gestureID { queuedDetails["gestureID"] = String(gestureID) }
        diagnostics.record("change_queued", details: queuedDetails)
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
        activeChange = ActiveChange(id: pendingChange.id, operation: change.diagnosticName,
                                    trace: pendingChange.trace)
        stampTrace(pendingChange.id) { $0.started = ChangeTrace.now }
        // change_completed reports only this change's calls and parking requests.
        _ = MainThreadActivity.takeAppCallCount()
        _ = windowSystem.takeParkingStatistics()
        diagnostics.record("change_started", details: [
            "changeID": String(pendingChange.id),
            "operation": change.diagnosticName,
            "pendingChanges": String(changes.count),
            "transferToken": token.map(String.init) ?? "none"
        ])
        if change == .contestedWindowsFollowPointer {
            guard moveContestedWindowsToPointer() else {
                endActiveChange(.noEffect, reason: "no_holder_change")
                return true
            }
            return finish(pendingChange, outcome: .completed)
        }
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
        let stateBeforeChange = state
        let application = applyToState(change, crossingDisplays: pendingChange.crossesDisplays)
        guard application == .applied else {
            if let token { focusGate.cancelTransfer(token: token) }
            workspaceRestoration.endTransition()
            if application == .refused {
                endActiveChange(.refused, reason: "tile_refused_before_change")
            } else {
                endActiveChange(.noEffect, reason: "state_unchanged")
            }
            return true
        }
        if change.isWindowNavigation, let next = changes.first, next.change.isWindowNavigation,
           let token, focusGate.cancelTransferIfEmpty(token: token) {
            // Keep every navigation step in state, but avoid flashing intermediate
            // windows when no typing belongs to them. Never merge input tokens.
            batch = NavigationBatch(motionStart: motionStart, initialHorizontalVelocity: initialHorizontalVelocity)
            endActiveChange(.merged, reason: "navigation_batched", successorID: next.id)
            return true
        }
        batch = NavigationBatch()
        guard prepareLayoutState(for: change) else {
            workspaceRestoration.endTransition()
            if case .observedFocus = change {
                endActiveChange(.skipped, reason: "focus_changed_before_layout")
            } else {
                endActiveChange(.skipped, reason: "no_managed_window_focused")
            }
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
        recordMotionPlan(change: change, changeID: pendingChange.id, previousState: previousState,
                         hadPreview: hadPreview, motionStartCount: motionStart.count,
                         reduceMotion: reduceMotion, canSlide: canSlide)
        let outcome = await applyLayout(token: token, request: change.policy,
                                        operation: change.diagnosticName,
                                        slideFrom: canSlide ? motionStart : nil,
                                        initialHorizontalVelocity: canSlide ? initialHorizontalVelocity : nil,
                                        focusAlongsideSlide: change.focusesAlongsideRibbon)
        // A stale worker's change was already ended by cancelChanges.
        guard changes.isCurrent(generation) else { return false }
        if outcome == .completed, case .tiles(let tileChange) = change,
           undoTileChangeThatDidNotFit(tileChange, stateBefore: stateBeforeChange) {
            // Refused without pausing; the restored tiles are laid out next.
            workspaceRestoration.endTransition()
            endActiveChange(.refused, reason: "tile_did_not_fit")
            return true
        }
        return finish(pendingChange, outcome: outcome)
    }

    private enum StateApplication { case applied, unchanged, refused }

    /// Updates the logical workspace for a change.
    private func applyToState(_ change: Change, crossingDisplays: Bool) -> StateApplication {
        switch change {
        case .action(let action) where action == .shrinkHeight || action == .growHeight:
            return adjustFocusedWindowHeight(growing: action == .growHeight) ? .applied : .unchanged
        case .action(let action) where crossingDisplays && (action == .focusNext || action == .focusPrevious):
            return state.focusWindowCrossingDisplays(by: action == .focusNext ? 1 : -1,
                                                     visibleTiles: visibleTileRange(ofSpace:)) ? .applied : .unchanged
        case .action(let action):
            let sourceSpaceIndex = state.activeSpaceIndex
            guard state.apply(action, widthPresets: widthPresets) else { return .unchanged }
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
        case .tiles(let tileChange):
            switch applyTileChange(tileChange) {
            case .applied: return .applied
            case .unchanged: return .unchanged
            case .refused: return .refused
            }
        case .windowRemoval, .refresh, .preferences, .observedFocus, .contestedWindowsFollowPointer: break
        }
        return .applied
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
                focusedWindowID: focusedWindowID,
                focusedWindowDisplay: focusedWindowID.flatMap(managedDisplay(holdingWindow:))
            )
        } else {
            preferencesNeedLayout = true
            prepared = change.policy.prepare(state: state, focusedWindowID: focusedWindowID,
                                             focusedWindowDisplay: focusedWindowID.flatMap(managedDisplay(holdingWindow:)))
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

    private func recordMotionPlan(change: Change, changeID: Int, previousState: WorkspaceState, hadPreview: Bool,
                                  motionStartCount: Int, reduceMotion: Bool, canSlide: Bool) {
        guard change.policy == .navigation, diagnostics.isEnabled else { return }
        let destinationID = state.focusedWindowID
        let observedFocus = windowSystem.lastObservedFocusedWindowID
        let membershipCount = destinationID.map { state.spaces.membershipCount(of: $0) } ?? 0
        diagnostics.record("navigation_motion_planned", details: [
            "changeID": String(changeID),
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
        ].merging(pointerDetails()) { current, _ in current })
    }

    /// Records a finished change, or pauses and restores after a failure.
    /// Returns false when processing must end.
    private func finish(_ pendingChange: PendingChange, outcome: LayoutOutcome) -> Bool {
        let change = pendingChange.change
        let failureReason: String
        switch outcome {
        case .completed:
            if let focusedWindowID = state.focusedWindowID { focusHistory.record(windowID: focusedWindowID) }
            // What the change cost the main thread in calls to other apps, and how many
            // parking requests could trust a window already at the side.
            let cost = [
                "appCallsOnMain": String(MainThreadActivity.takeAppCallCount())
            ].merging(windowSystem.takeParkingStatistics()) { current, _ in current }
            if let successorID = activeChange?.supersededBy {
                endActiveChange(.superseded, reason: "slide_cut_short", successorID: successorID, details: cost)
            } else {
                let trace = closeTrace(activeChange?.trace ?? pendingChange.trace, changeID: pendingChange.id,
                                       operation: change.diagnosticName, outcome: "completed")
                activeChange = nil
                diagnostics.record("change_completed", details: [
                    "changeID": String(pendingChange.id),
                    "operation": change.diagnosticName
                ].merging(cost) { current, _ in current }.merging(trace) { current, _ in current })
            }
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
            endActiveChange(.failed, reason: "focus_target_unavailable")
            if dropUnavailableWindow(windowID, reason: reason, detectedBy: "focus") { return true }
            failureReason = "focus_target_unavailable"
        case .failed(let reason):
            endActiveChange(.failed, reason: reason)
            failureReason = reason
        case .interrupted:
            // Interruptions normally end this worker's generation first.
            failureReason = "layout_stopped_unexpectedly"
            endActiveChange(.interrupted, reason: failureReason)
        }
        workspaceRestoration.rollBack(state: &state, windowIDs: windows.map(\.id),
                                      trackedWindowIDs: windowSystem.trackedWindowIDs)
        stop(reason: failureReason, automatic: true, details: ["operation": change.diagnosticName])
        return false
    }

    /// Logs the active change's terminal event. Every queued change gets exactly
    /// one: change_completed, or change_ended from here or from cancelChanges.
    func endActiveChange(_ outcome: ChangeEnd, reason: String, successorID: Int? = nil,
                         details: [String: String] = [:]) {
        guard let ended = activeChange else { return }
        activeChange = nil
        recordChangeEnded(id: ended.id, operation: ended.operation, outcome: outcome, reason: reason,
                          trace: ended.trace, successorID: successorID, details: details)
    }

    /// Drops pending changes and invalidates the worker, ending each change's trace.
    func cancelChanges(reason: String) {
        let dropped = changes.cancel()
        endActiveChange(.interrupted, reason: reason)
        for pending in dropped {
            recordChangeEnded(id: pending.id, operation: pending.change.diagnosticName, outcome: .cancelled,
                              reason: reason, trace: pending.trace)
        }
    }

    private func recordChangeEnded(id: Int, operation: String, outcome: ChangeEnd, reason: String,
                                   trace: ChangeTrace, successorID: Int? = nil, details: [String: String] = [:]) {
        var context = details
        context["changeID"] = String(id)
        context["operation"] = operation
        context["outcome"] = outcome.rawValue
        context["reason"] = reason
        if let successorID { context["successorChangeID"] = String(successorID) }
        context.merge(closeTrace(trace, changeID: id, operation: operation, outcome: outcome.rawValue)) { current, _ in
            current
        }
        diagnostics.record("change_ended", details: context)
    }

    /// Stamps the change still being processed; a worker that outlived its change stamps nothing.
    func stampTrace(_ changeID: Int?, _ stamp: (inout ChangeTrace) -> Void) {
        guard let changeID, var active = activeChange, active.id == changeID else { return }
        stamp(&active.trace)
        activeChange = active
    }

    /// Hands the ended trace to the sink and returns its fields for the terminal event.
    private func closeTrace(_ trace: ChangeTrace, changeID: Int, operation: String,
                            outcome: String) -> [String: String] {
        var trace = trace
        trace.ended = ChangeTrace.now
        changeTraceSink?(EndedChangeTrace(changeID: changeID, operation: operation, outcome: outcome, trace: trace))
        return trace.details
    }

    func adjustFocusedWindowHeight(growing: Bool) -> Bool {
        guard let windowID = state.focusedWindowID,
              let availableFrame else { return false }
        // The height shortcuts set a lone window's preferred height. A pane's
        // height is its share of the tile; changing the preference there would
        // only change the height it takes when it is alone again.
        if let tile = state.currentSpace.tileIndex(of: windowID),
           state.currentSpace.tiles[tile].isMultiPane { return false }
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

    var displayArrangement: DisplayArrangement { displayArrangementProvider() }

    /// The display showing the focused space; before Start sets the displays, the
    /// arrangement's fallback: the built-in display, else the menu-bar display.
    var focusedDisplay: Display? { focusedDisplay(in: displayArrangement) }

    func focusedDisplay(in arrangement: DisplayArrangement) -> Display? {
        (state.focusedDisplay ?? arrangement.fallback).flatMap(arrangement.display)
    }

    // Kept for StagehandModel+Benchmark.swift until slice B.
    var builtInScreen: NSScreen? {
        displayArrangement.builtIn.flatMap { NSScreen.screen(displayNumber: $0.number) }
    }

    var availableFrame: CGRect? { focusedDisplay?.visibleFrame }

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
                                    request: LayoutRequestPolicy, operation: String,
                                    changeID: Int? = nil) async -> LayoutOutcome {
        // Diagnostics use the focus already observed; a new read would wait on the
        // outgoing app, on the main thread, before the attempt even starts.
        let observedFocusBefore = diagnostics.isEnabled ? windowSystem.lastObservedFocusedWindowID : nil
        stampTrace(changeID) { $0.focusRequested = $0.focusRequested ?? ChangeTrace.now }
        let confirmation = await request.confirmFocus(
            windowID: record.id,
            currentFocus: { windowSystem.focusedWindowID() },
            activate: { await windowSystem.focus(windowID: record.id) },
            unavailability: { windowSystem.unavailability(windowID: record.id) },
            isParked: { windowSystem.isParked(windowID: record.id) },
            mayHoldFocus: { windowSystem.mayHoldFocus(windowID: record.id) }
        )
        let focused = confirmation == .focused
        if focused { stampTrace(changeID) { $0.focusConfirmed = $0.focusConfirmed ?? ChangeTrace.now } }
        if request == .navigation {
            diagnostics.observe(focused ? "navigation_focus_succeeded" : "navigation_focus_rejected")
        }
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
            if let changeID { details["changeID"] = String(changeID) }
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
        // Read before any await: work that outlives the change keeps its own ID.
        let changeID = activeChange?.id
        guard desktopScope.refresh() == .home else {
            nativeDesktopChanged()
            return .interrupted
        }
        let arrangement = displayArrangement
        guard let display = focusedDisplay(in: arrangement) else {
            if let token { focusGate.cancelTransfer(token: token) }
            return failLayout("display_frame_unavailable")
        }
        let availableFrame = display.visibleFrame
        let sharedEdges = arrangement.sharedEdges(of: display.id)
        var snappedBeforeMotion: Set<String> = []
        var heldElsewhere: Set<String> = []
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
        if !learnedMinimumWidths.isEmpty {
            learnedMinimumWidths = learnedMinimumWidths.filter { knownIDs.contains($0.key) }
        }
        if !learnedMinimumHeights.isEmpty {
            learnedMinimumHeights = learnedMinimumHeights.filter { knownIDs.contains($0.key) }
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
            placements = restingOffSharedEdges(
                WindowLayout.placements(for: state.currentSpace, availableFrame: availableFrame,
                                        tileGap: gap, paneGap: paneGap,
                                        observedWidths: observedWidths, preferredHeights: preferredHeights,
                                        observedHeights: observedHeights,
                                        minimumWidths: learnedMinimumWidths,
                                        minimumHeights: learnedMinimumHeights),
                displayFrame: display.frame, sharedEdges: sharedEdges)
            var slideStarts = slideFrom
            if let slideFrom, !sharedEdges.isEmpty {
                let slide = sharedEdgeSafeSlide(
                    from: slideFrom,
                    to: Dictionary(placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first }),
                    displayFrame: display.frame,
                    sharedEdges: sharedEdges
                )
                slideStarts = slide.from
                if pass == 0 { snappedBeforeMotion = slide.snappedWindowIDs }
            }
            if pass == 0 {
                heldElsewhere = holdContestedWindows(on: display, placements: placements, slideFrom: slideFrom,
                                                     slideStarts: slideStarts, in: arrangement)
            }
            let visible = placements.filter {
                !heldElsewhere.contains($0.windowID)
                    && ($0.isVisible || slideFrom?[$0.windowID]?.intersects(availableFrame) == true)
            }
            // Position neighbors first. Raising the focused real window last keeps clamped neighbors behind it.
            for placement in visible.sorted(by: { !$0.isFocused && $1.isFocused }) {
                // A correction pass only writes windows whose geometry actually changed.
                var preparedFrame = placement.frame
                if let start = slideStarts?[placement.windowID] { preparedFrame.origin.x = start.minX }
                if pass > 0, acceptedFrames[placement.windowID] == preparedFrame { continue }
                // A sliding window is where the slide starts: a frame Stagehand wrote and
                // verified or the last scan read. Only a window without one is read now.
                // A parked window is always written; its logical frame is not its position.
                let current = windowSystem.isParked(windowID: placement.windowID)
                    ? nil : slideFrom?[placement.windowID] ?? windowSystem.frame(windowID: placement.windowID)
                if let current, framesMatch(observed: current, target: preparedFrame) {
                    acceptedFrames[placement.windowID] = current
                    noteAppliedFrame(current, windowID: placement.windowID)
                    continue
                }
                let frameWritten = windowSystem.setFrame(windowID: placement.windowID, frame: preparedFrame)
                // setFrame verified an accepted write to within a point; read back a refusal.
                let actualFrame = frameWritten ? preparedFrame : windowSystem.frame(windowID: placement.windowID)
                if let actualFrame { acceptedFrames[placement.windowID] = actualFrame }
                if !frameWritten, placement.isFocused {
                    recordWindowGeometry(
                        event: "frame_write_constrained",
                        windowID: placement.windowID,
                        requestedFrame: preparedFrame,
                        actualFrame: actualFrame,
                        details: ["pass": String(pass + 1)]
                    )
                }
                noteAppliedFrame(actualFrame, windowID: placement.windowID)
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
                        let shownIDs = Set(placements.filter(\.isVisible).map(\.windowID)).subtracting(heldElsewhere)
                        let frames = Dictionary(placements.map { ($0.windowID, $0.frame) },
                                                uniquingKeysWith: { first, _ in first })
                        switch await parkHiddenWindows(keeping: shownIDs, layoutFrames: frames) {
                        case .interrupted: return .interrupted
                        case .failed(let details): return failLayout("window_parking_failed", details: details)
                        case .completed: break
                        }
                    }
                    let focus = await focusManagedWindow(record, token: token, request: request, operation: operation,
                                                         changeID: changeID)
                    guard focus == .completed else { return focus }
                    destinationPID = record.pid
                }
                var constrained = false
                for placement in visible {
                    // A slide's windows were matched or written just above. A space
                    // switch reads back after activation, when an app may have resized.
                    guard let actual = slideFrom != nil
                        ? acceptedFrames[placement.windowID]
                        : windowSystem.frame(windowID: placement.windowID) else { continue }
                    acceptedFrames[placement.windowID] = actual
                    var constrainedAxes: [String] = []
                    if actual.width.isFinite, actual.width > 0,
                       abs(actual.width - placement.frame.width) > 1 {
                        observedWidths[placement.windowID] = actual.width
                        if let tile = state.currentSpace.tileIndex(of: placement.windowID),
                           !state.currentSpace.tiles[tile].isMultiPane {
                            state.setWidthFraction(actual.width / availableFrame.width, for: placement.windowID)
                        }
                        constrained = true
                        constrainedAxes.append("width")
                    }
                    if actual.height.isFinite, actual.height > 0,
                       abs(actual.height - placement.frame.height) > 1 {
                        observedHeights[placement.windowID] = actual.height
                        constrained = true
                        constrainedAxes.append("height")
                    }
                    noteLayoutSize(windowID: placement.windowID, requested: placement.frame.size,
                                   actual: actual.size)
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
                widenTilesToLearnedMinimums(holding: visible.map(\.windowID), availableWidth: availableFrame.width)
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
                stampTrace(changeID) { $0.focusRequested = $0.focusRequested ?? ChangeTrace.now }
                let focused = await emptySpace.show(space: state.activeSpaceIndex + 1, frame: availableFrame)
                if focused { stampTrace(changeID) { $0.focusConfirmed = $0.focusConfirmed ?? ChangeTrace.now } }
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
        let visibleIDs = Set(placements.filter(\.isVisible).map(\.windowID)).subtracting(heldElsewhere)
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
            // Pass 0 left every sliding window at its accepted frame, and each placeholder at its start.
            let placeholderStarts = focusedDisplayPlaceholderFrames
            let starts = Dictionary(sliding.compactMap { placement in
                (heldElsewhere.contains(placement.windowID)
                    ? placeholderStarts[placement.windowID]
                    : acceptedFrames[placement.windowID] ?? windowSystem.frame(windowID: placement.windowID))
                    .map { (placement.windowID, $0) }
            }, uniquingKeysWith: { first, _ in first })
            let targets = Dictionary(sliding.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
            var slideFinished = false
            let translate = {
                let completed = await self.settleRibbon(
                    from: starts,
                    to: targets,
                    visibleIDs: visibleIDs,
                    operation: operation,
                    initialHorizontalVelocity: initialHorizontalVelocity,
                    snappedBeforeMotion: snappedBeforeMotion,
                    changeID: changeID
                )
                if completed {
                    slideFinished = true
                    return RibbonTranslationOutcome.readyForFocus
                }
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
                    record, token: token, request: request, operation: operation, changeID: changeID
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
                    let release = self.focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                    self.stampTrace(changeID) { $0.heldInput = release }
                }
            }
            let revealBorder = {
                // The border follows the frames the slide was given: the start before
                // the motion, the target once it has settled.
                if let focused = self.state.focusedWindowID,
                   let frame = (slideFinished ? targets : starts)[focused] ?? self.windowSystem.frame(windowID: focused) {
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
            case .superseded:
                if let changeID, activeChange?.id == changeID { activeChange?.supersededBy = changes.first?.id }
                return .completed
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
                    let written = windowSystem.setFrame(windowID: focusedID, frame: target)
                    frame = written ? target : windowSystem.frame(windowID: focusedID)
                }
                if let frame {
                    noteAppliedFrame(frame, windowID: focusedID)
                    updateFocusBorder(windowID: focusedID, frame: frame, raiseBorder: true)
                }
            }
            if token != nil, destinationPID != nil {
                try? await Task.sleep(for: .milliseconds(12))
                guard isRunning, !isSuspended, !Task.isCancelled else { return .interrupted }
            }
        } else {
            lastTransition = Date()
            if let token, let destinationPID {
                let release = focusGate.commitTransfer(token: token, processIdentifier: destinationPID)
                stampTrace(changeID) { $0.heldInput = release }
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
        let otherLayouts = otherDisplayLayouts(in: arrangement)
        layoutOtherDisplays(otherLayouts, besides: visibleIDs)
        settleContestedPlaceholders(on: display, placements: placements, heldElsewhere: heldElsewhere,
                                    otherLayouts: otherLayouts)
        overlays.setBorderColor(focusBorderColor)
        if request == .navigation { overlays.showNavigation(state: state, windows: windows) }
        else { overlays.updateNavigation(state: state, windows: windows) }
        return .completed
    }

    /// Records a frame a layout wrote and verified, or accepted as matching.
    func noteAppliedFrame(_ frame: CGRect?, windowID: String) {
        lastAppliedFrames[windowID] = frame
        if let frame { knownFrames[windowID] = frame }
    }

    /// The frame Stagehand last wrote or scanned; a parked window's logical frame.
    /// Reads from the app only for a window it has never placed or scanned.
    func knownFrame(windowID: String) -> CGRect? {
        if windowSystem.isParked(windowID: windowID) { return windowSystem.frame(windowID: windowID) }
        return knownFrames[windowID] ?? windowSystem.frame(windowID: windowID)
    }

    func navigationFrames() -> [String: CGRect] {
        let arrangement = displayArrangement
        guard let display = focusedDisplay(in: arrangement) else { return [:] }
        let members = Set(state.currentSpace.windowIDs)
        let actual = Dictionary(windows.filter { members.contains($0.id) }.compactMap { window in
            knownFrame(windowID: window.id).map { (window.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let placements = restingOffSharedEdges(
            WindowLayout.placements(for: state.currentSpace, availableFrame: display.visibleFrame,
                                    tileGap: gap, paneGap: paneGap,
                                    observedWidths: actual.mapValues(\.width),
                                    observedHeights: actual.mapValues(\.height)),
            displayFrame: display.frame, sharedEdges: arrangement.sharedEdges(of: display.id))
        let shownAsPlaceholders = focusedDisplayPlaceholderFrames
        var frames = Dictionary(placements.map {
            ($0.windowID, $0.isVisible ? shownAsPlaceholders[$0.windowID] ?? actual[$0.windowID] ?? $0.frame : $0.frame)
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

    /// Parks every managed window outside `keeping` and off the other displays, on its parking
    /// display, on the side its layout frame falls. One that turns out minimized or closed leaves the ribbon.
    func parkHiddenWindows(keeping keptIDs: Set<String>,
                                   layoutFrames: [String: CGRect]) async -> HiddenWindowParking {
        let arrangement = displayArrangement
        let focused = focusedDisplay(in: arrangement)
        let keptIDs = keptIDs.union(windowsShownOnOtherDisplays(in: arrangement))
        for window in windows where !keptIDs.contains(window.id) {
            let display = focused.map { parkingDisplay(windowID: window.id, in: arrangement, focused: $0) }
            let parkingSide = display.flatMap { display in
                freeParkingSide(
                    preferred: focused.flatMap { preferredParkingSide(for: layoutFrames[window.id], relativeTo: $0.visibleFrame) },
                    sharedEdges: arrangement.sharedEdges(of: display.id)
                )
            }
            let remnantWidth = parkedRemnantWidth(forBundleIdentifier: window.bundleIdentifier)
            let parking = await parkWindow(
                windowID: window.id,
                park: {
                    windowSystem.park(windowID: $0, bounds: display?.visibleFrame,
                                      preferredSide: parkingSide, remnantWidth: remnantWidth)
                },
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

    /// Windows a space shown on another display has on screen; parking leaves them there.
    func windowsShownOnOtherDisplays(in arrangement: DisplayArrangement) -> Set<String> {
        Set(otherDisplayLayouts(in: arrangement).flatMap { $0.placements.filter(\.isVisible).map(\.windowID) })
    }

    struct DisplayLayout {
        let display: Display
        let spaceIndex: Int
        let placements: [WindowPlacement]
    }

    func otherDisplayLayouts(in arrangement: DisplayArrangement) -> [DisplayLayout] {
        state.displays.ids.compactMap { id in
            guard id != state.focusedDisplay, let display = arrangement.display(id),
                  let index = state.shownSpaceIndex(on: id) else { return nil }
            let placements = WindowLayout.placements(for: state.spaces[index], availableFrame: display.visibleFrame,
                                                     tileGap: gap, paneGap: paneGap,
                                                     preferredHeights: preferredHeights,
                                                     minimumWidths: learnedMinimumWidths,
                                                     minimumHeights: learnedMinimumHeights)
            return DisplayLayout(display: display, spaceIndex: index, placements: restingOffSharedEdges(
                placements, displayFrame: display.frame, sharedEdges: arrangement.sharedEdges(of: id)))
        }
    }

    /// Static frames only: no slide, no focus. A display is written again only when its
    /// layout changed; a size an app refuses is learned and applied by the next layout.
    /// A contested window is written only on its holder.
    func layoutOtherDisplays(_ layouts: [DisplayLayout], besides focusedDisplayWindowIDs: Set<String>) {
        otherDisplayFrames = otherDisplayFrames.filter { id, _ in layouts.contains { $0.display.id == id } }
        for (display, targets) in otherDisplayTargets(layouts, besides: focusedDisplayWindowIDs) {
            guard otherDisplayFrames[display] != targets else { continue }
            for (windowID, target) in targets { writeStaticFrame(target, windowID: windowID) }
            otherDisplayFrames[display] = targets
        }
    }

    func writeStaticFrame(_ target: CGRect, windowID: String) {
        if !windowSystem.isParked(windowID: windowID), let known = knownFrames[windowID],
           framesMatch(observed: known, target: target) { return }
        let written = windowSystem.setFrame(windowID: windowID, frame: target)
        let actual = written ? target : windowSystem.frame(windowID: windowID)
        if let actual { noteLayoutSize(windowID: windowID, requested: target.size, actual: actual.size) }
        noteAppliedFrame(actual, windowID: windowID)
    }

    /// The managed display holding most of `frame`; nil while fewer than two are managed.
    func managedDisplay(holding frame: CGRect, in arrangement: DisplayArrangement) -> DisplayID? {
        guard state.displays.ids.count > 1 else { return nil }
        let managed = arrangement.displays.filter { state.displays.ids.contains($0.id) }
        guard let holder = managed.max(by: { $0.frame.overlapArea(with: frame) < $1.frame.overlapArea(with: frame) }),
              holder.frame.overlapArea(with: frame) > 0 else { return nil }
        return holder.id
    }

    func managedDisplay(holdingWindow windowID: String) -> DisplayID? {
        guard state.displays.ids.count > 1,
              let frame = knownFrames[windowID] ?? windows.first(where: { $0.id == windowID })?.frame else { return nil }
        return managedDisplay(holding: frame, in: displayArrangement)
    }

    func displayOfNewWindows(_ records: [WindowRecord]) -> ((String) -> DisplayID?)? {
        guard state.displays.ids.count > 1 else { return nil }
        let arrangement = displayArrangement
        let displays = Dictionary(records.compactMap { record in
            managedDisplay(holding: record.frame, in: arrangement).map { (record.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return { displays[$0] }
    }

    func parkingDisplay(windowID: String, in arrangement: DisplayArrangement, focused: Display) -> Display {
        guard state.displays.ids.count > 1 else { return focused }
        var candidates: [Display] = []
        for index in state.spaces.indices where state.spaces[index].windowIDs.contains(windowID) {
            guard let display = state.display(ofSpace: index).flatMap(arrangement.display),
                  !candidates.contains(where: { $0.id == display.id }) else { continue }
            candidates.append(display)
        }
        return displayToParkOn(candidates: candidates, displays: arrangement.displays,
                               currentFrame: candidates.count > 1 ? knownFrame(windowID: windowID) : nil) ?? focused
    }

    func applyMotionFrames(_ frames: [String: CGRect]) {
        guard isRunning, !isSuspended, desktopScope.relation == .home else {
            ribbonMotion.cancel()
            if isRunning { nativeDesktopChanged() }
            return
        }
        if gestureBase == nil, pointer.isButtonDown, !pointer.isDragAndDrop {
            // A real pointer interaction takes over from decorative settling. A
            // drag-and-drop moves no window, so a switch made during one keeps sliding.
            if diagnostics.isEnabled {
                // Logged because the slide then ends without ribbon_animation_completed.
                diagnostics.record("ribbon_motion_yielded_to_pointer", details: [
                    "focusedWindowID": state.focusedWindowID ?? "none"
                ].merging(pointerDetails()) { current, _ in current })
            }
            presentationFrames = ribbonMotion.frames
            ribbonMotion.cancel()
            scheduleRefresh()
            return
        }
        writeRibbonPositions(
            frames: movePlaceholders(in: frames),
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
                              operation: String, initialHorizontalVelocity: CGFloat? = nil,
                              snappedBeforeMotion: Set<String> = [],
                              changeID: Int? = nil, gestureID: Int? = nil) async -> Bool {
        var trace: [String: String] = [:]
        if let changeID { trace["changeID"] = String(changeID) }
        if let gestureID { trace["gestureID"] = String(gestureID) }
        let arrangement = displayArrangement
        let display = focusedDisplay(in: arrangement)
        let slide = display.map {
            sharedEdgeSafeSlide(from: from, to: to, displayFrame: $0.frame, sharedEdges: arrangement.sharedEdges(of: $0.id))
        } ?? SharedEdgeSlide(from: from, to: to, snappedWindowIDs: [])
        let snapped = slide.snappedWindowIDs.union(snappedBeforeMotion)
        if !snapped.isEmpty {
            diagnostics.record("shared_edge_motion_snapped", details: [
                "operation": operation,
                "windowCount": String(snapped.count)
            ])
        }
        motionBackingScaleFactor = display?.backingScaleFactor ?? 1
        motionWrittenPositions = slide.from.mapValues {
            RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
        }
        var animationConfiguration = ribbonAnimationConfiguration
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animationConfiguration.duration = 0 }
        // A follow this settle replaces ends inside animate(), after the reset below.
        settleStart = SettleStart(operation: operation, changeID: changeID,
                                  writesBefore: windowSystem.motionWriteSummary(reset: false))
        _ = windowSystem.motionWriteStatistics(reset: true, focusedWindowID: nil)
        diagnostics.record("ribbon_animation_started", details: [
            "curve": animationConfiguration.curve.diagnosticDescription,
            "durationMilliseconds": String(Int((animationConfiguration.duration * 1_000).rounded())),
            "focusedWindowID": state.focusedWindowID ?? "none",
            "initialHorizontalVelocity": initialHorizontalVelocity.map { String(Double($0)) } ?? "none",
            "operation": operation,
            "windowCount": String(to.count)
        ].merging(trace) { current, _ in current })
        let animationStart = ProcessInfo.processInfo.systemUptime
        stampTrace(changeID) { $0.motionScheduled = $0.motionScheduled ?? animationStart }
        let destinationID = state.focusedWindowID
        let completed = await ribbonMotion.animate(
            on: display?.number,
            from: slide.from,
            to: slide.to,
            configuration: animationConfiguration,
            initialHorizontalVelocity: initialHorizontalVelocity,
            update: { [weak self] in self?.applyMotionFrames($0) }
        )
        let motionEnded = ChangeTrace.now
        // Let the last motion writes land so the commit reads settled positions.
        if completed { await windowSystem.finishMotionWrites() }
        let writes = windowSystem.motionWriteSummary(reset: false)
        stampTrace(changeID) { trace in
            trace.motionEnded = motionEnded
            trace.motionWrites = writes
            trace.firstAcknowledgedWrite = destinationID.flatMap { writes.firstAcknowledgedUptime[$0] }
        }
        guard completed else { return false }
        guard isRunning, !isSuspended, !Task.isCancelled, desktopScope.refresh() == .home else { return false }
        let windowTargets = movePlaceholders(in: to)
        let visibleIDs = windowTargets.count == to.count ? visibleIDs : visibleIDs.filter { windowTargets[$0] != nil || to[$0] == nil }
        var visibleFrames = windowTargets.filter { visibleIDs.contains($0.key) }
        var commitFailures = commitRibbonPositions(
            frames: visibleFrames,
            backingScaleFactor: motionBackingScaleFactor,
            setPosition: { windowSystem.setPosition(windowID: $0, position: $1) },
            observedFrame: { windowSystem.observedFrame(windowID: $0) }
        )
        var attempts = 1
        // Only a window that answered with the wrong position is tried again. One that
        // cannot be read (closing, or its app not answering) would cost a main-thread
        // round trip per try; parking defers the same case, and the refresh places it.
        var unreadable = commitFailures.filter { $0.actualFrame == nil }
        commitFailures.removeAll { $0.actualFrame == nil }
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
            attempts += 1
            unreadable += commitFailures.filter { $0.actualFrame == nil }
            commitFailures.removeAll { $0.actualFrame == nil }
        }
        if let failure = commitFailures.first ?? unreadable.first {
            recordWindowGeometry(
                event: "ribbon_position_commit_failed",
                windowID: failure.windowID,
                requestedFrame: failure.requestedFrame,
                actualFrame: failure.actualFrame,
                details: ["attempts": String(attempts), "frameUnreadable": String(failure.actualFrame == nil)]
            )
            // Motion ends here without pausing. Rewrite the ribbon with verified frame
            // writes and parking so no window stays outside its place in the ribbon.
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
            ].merging(trace) { current, _ in current }) { _, new in new })
        }
        switch await parkHiddenWindows(keeping: visibleIDs, layoutFrames: to) {
        case .interrupted: return false
        case .failed(let details):
            stop(reason: "ribbon_parking_failed", automatic: true, details: details)
            return false
        case .completed: break
        }
        // The commit verified each position; sizes were written and verified by the layout pass.
        for id in visibleIDs { noteAppliedFrame(to[id], windowID: id) }
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
        focusBorder.show(windowID: windowID, frame: frame,
                         sheet: windowSystem.sheetFrame(windowID: windowID, over: frame), color: focusBorderColor,
                         refreshShape: refreshShape, raise: raiseBorder)
    }
}
