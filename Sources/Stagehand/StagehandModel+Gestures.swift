import AppKit
import StagehandCore
import StagehandPlatform

/// Live trackpad preview and its handoff to navigation.
extension StagehandModel {
    /// Forgets the live gesture. Callers decide separately whether to cancel ribbon
    /// motion, clear presentation frames, or cancel the recognizer's sequence.
    func resetGestureTracking() {
        gestureBase = nil
        gestureAxis = nil
        gesturePrepared.removeAll()
    }

    func handleGesture(_ event: GestureNavigationEvent) {
        if traceGestures {
            switch event {
            case .changed: break
            default:
                NSLog("[DEBUG-gesture] delivered %@ running=%d suspended=%d worker=%d axis=%@", String(describing: event),
                      isRunning, isSuspended, changes.isProcessing, String(describing: gestureAxis))
            }
        }
        guard isRunning, !isSuspended else { return }
        switch event {
        case .began(let axis, let displacement, let mode):
            guard desktopScope.refresh() == .home else { return }
            gestureAxis = axis
            if mode == .plain, !changes.isProcessing, axis == .horizontal,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let frames = navigationFrames()
                ribbonMotion.cancel()
                gestureBase = frames
                presentationFrames = frames.filter { $0.value.intersects(availableFrame ?? .zero) }
                gesturePrepared = Set(presentationFrames?.keys.map { $0 } ?? [])
                motionBackingScaleFactor = builtInScreen?.backingScaleFactor ?? 1
                motionWrittenPositions = presentationFrames?.mapValues {
                    RibbonMotion.pixelAligned($0.origin, backingScaleFactor: motionBackingScaleFactor)
                } ?? [:]
                if diagnostics.isEnabled {
                    diagnostics.record("gesture_motion_started", details: [
                        "focusedWindowID": state.focusedWindowID ?? "none",
                        "observedFocusedWindowID": windowSystem.focusedWindowID() ?? "none",
                        "preparedWindowCount": String(gesturePrepared.count),
                        "trackedWindowCount": String(frames.count)
                    ])
                }
                overlays.updateBorder(frame: .zero, visible: false)
                previewGesture(displacement: displacement)
            }
        case .changed(let displacement, _):
            previewGesture(displacement: displacement)
        case .ended(let displacement, let velocity, let action, let mode):
            guard let gestureAxis else { return }
            finishGesture(axis: gestureAxis, displacement: displacement,
                          velocity: velocity, recognizerAction: action, mode: mode)
        case .cancelled:
            gestureAxis = nil
            restoreGesturePreview()
        }
    }

    func finishGesture(axis: GestureAxis, displacement: Double, velocity: Double,
                               recognizerAction: NavigationAction?, mode: GestureMode) {
        let resolvedAction: NavigationAction?
        if mode == .plain, axis == .horizontal, let gestureBase, let availableFrame {
            resolvedAction = RibbonMotion.horizontalCompletionAction(
                state: state,
                from: gestureBase,
                availableFrame: availableFrame,
                gap: gap,
                displacement: displacement,
                velocity: velocity,
                configuration: ribbonAnimationConfiguration
            )
        } else {
            resolvedAction = recognizerAction
        }
        if diagnostics.isEnabled {
            // This runs on the path that routes a keyboard event after a trackpad release.
            // Reading the observed focus is an Accessibility call, so record it afterwards
            // rather than making the key wait on it.
            let logicalFocus = state.focusedWindowID ?? "none"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.diagnostics.record("gesture_motion_resolved", details: [
                    "displacement": String(displacement),
                    "focusedWindowID": logicalFocus,
                    "observedFocusedWindowID": self.windowSystem.focusedWindowID() ?? "none",
                    "resolvedAction": resolvedAction.map { String(describing: $0) } ?? "none",
                    "velocity": String(velocity)
                ])
            }
        }
        gestureAxis = nil
        if mode == .shortcut {
            if let resolvedAction { navigate(resolvedAction) }
            return
        }
        let initialHorizontalVelocity = axis == .horizontal && velocity.isFinite
            ? availableFrame.map {
                CGFloat(velocity * Double($0.width) * ribbonAnimationConfiguration.tracking)
            }
            : nil
        if let resolvedAction {
            var destination = state
            guard destination.apply(resolvedAction) else {
                restoreGesturePreview(initialHorizontalVelocity: initialHorizontalVelocity)
                return
            }
            gestureBase = nil
            gesturePrepared.removeAll()
            navigate(resolvedAction, initialHorizontalVelocity: initialHorizontalVelocity)
        } else {
            restoreGesturePreview(initialHorizontalVelocity: initialHorizontalVelocity)
        }
    }

    func previewGesture(displacement: Double) {
        guard let base = gestureBase, let availableFrame, gestureAxis == .horizontal,
              !changes.isProcessing, displacement.isFinite else { return }
        ribbonMotion.follow(frames: { [weak self] in
            guard let self, self.gestureBase != nil, self.desktopScope.relation == .home else { return [:] }
            return self.gesturePreviewFrames(
                from: base,
                availableFrame: availableFrame,
                displacement: displacement
            )
        }, update: { [weak self] in self?.applyMotionFrames($0) })
    }

    func gesturePreviewFrames(from base: [String: CGRect], availableFrame: CGRect,
                                      displacement: Double) -> [String: CGRect] {
        if let cache = gesturePreviewCache, cache.displacement == displacement {
            presentationFrames = cache.frames
            return cache.frames
        }
        var complete = true
        let preview = RibbonMotion.dragFrames(state: state, from: base, availableFrame: availableFrame,
                                              gap: gap, displacement: displacement,
                                              configuration: ribbonAnimationConfiguration)
        var frames: [String: CGRect] = [:]
        for (id, shifted) in preview {
            guard shifted.intersects(availableFrame) || gesturePrepared.contains(id) else { continue }
            if !gesturePrepared.contains(id) {
                let beforeFrame = diagnostics.isEnabled ? windowSystem.observedFrame(windowID: id) : nil
                let parkedBefore = diagnostics.isEnabled ? windowSystem.isParked(windowID: id) : false
                let frameWritten = windowSystem.setFrame(windowID: id, frame: shifted)
                if diagnostics.isEnabled {
                    recordWindowGeometry(
                        event: "gesture_window_frame_applied",
                        windowID: id,
                        requestedFrame: shifted,
                        beforeFrame: beforeFrame,
                        actualFrame: windowSystem.observedFrame(windowID: id),
                        details: [
                            "displacement": String(displacement),
                            "frameWriteAccepted": String(frameWritten),
                            "isLogicalFocused": String(state.focusedWindowID == id),
                            "membershipCount": String(state.spaces.count { $0.windowIDs.contains(id) }),
                            "parkedAfter": String(windowSystem.isParked(windowID: id)),
                            "parkedBefore": String(parkedBefore)
                        ]
                    )
                }
                guard frameWritten else {
                    // Retry this window's first move on the next tick.
                    complete = false
                    continue
                }
                gesturePrepared.insert(id)
                let acceptedPosition = windowSystem.observedFrame(windowID: id)?.origin ?? shifted.origin
                motionWrittenPositions[id] = RibbonMotion.pixelAligned(
                    acceptedPosition,
                    backingScaleFactor: motionBackingScaleFactor
                )
            }
            frames[id] = shifted
        }
        presentationFrames = frames
        gesturePreviewCache = complete ? (displacement, frames) : nil
        return frames
    }

    func restoreGesturePreview(initialHorizontalVelocity: CGFloat? = nil) {
        guard let base = gestureBase, let availableFrame else { return }
        let starts = presentationFrames ?? [:]
        let targets = base.filter { gesturePrepared.contains($0.key) }
        gestureBase = nil
        presentationFrames = nil
        gesturePrepared.removeAll()
        let visibleIDs = Set(base.filter { $0.value.intersects(availableFrame) }.keys)
        Task { [weak self] in
            guard let self else { return }
            let completed = await self.settleRibbon(
                from: starts,
                to: targets,
                visibleIDs: visibleIDs,
                operation: "gesture.preview.restore",
                initialHorizontalVelocity: initialHorizontalVelocity
            )
            guard completed else { return }
            if let focused = self.state.focusedWindowID,
               let frame = self.windowSystem.frame(windowID: focused) {
                self.updateFocusBorder(windowID: focused, frame: frame)
            }
            self.scheduleRefresh()
        }
    }
}
