import AppKit
import QuartzCore
import StagehandCore

struct RibbonAnimationCurve: Equatable {
    /// Strong ease-in-out for objects that remain onscreen and move to a new position.
    static let smoother = Self(x1: 0.65, y1: 0, x2: 0.35, y2: 1)
    /// Fast initial response for elements entering or leaving the interface.
    static let easeOut = Self(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    /// Gentle curve for color, opacity and pressed-state feedback.
    static let ease = Self(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let linear = Self(x1: 0, y1: 0, x2: 1, y2: 1)

    let x1: Double
    let y1: Double
    let x2: Double
    let y2: Double

    init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = Self.unitValue(x1)
        self.y1 = Self.easingValue(y1)
        self.x2 = Self.unitValue(x2)
        self.y2 = Self.easingValue(y2)
    }

    var controlPoints: [Double] { [x1, y1, x2, y2] }

    var diagnosticDescription: String {
        controlPoints.map {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
        }.joined(separator: ",")
    }

    func progress(at progress: Double) -> Double {
        let progress = Self.unitValue(progress)
        guard progress > 0, progress < 1 else { return progress }
        if self == .linear { return progress }
        var lower = 0.0
        var upper = 1.0
        for _ in 0 ..< 22 {
            let parameter = (lower + upper) / 2
            let sampledProgress = coordinate(at: parameter, firstControl: x1, secondControl: x2)
            if abs(sampledProgress - progress) < 0.000_000_1 {
                lower = parameter
                upper = parameter
                break
            } else if sampledProgress < progress {
                lower = parameter
            } else {
                upper = parameter
            }
        }
        return coordinate(at: (lower + upper) / 2, firstControl: y1, secondControl: y2)
    }

    private func coordinate(at parameter: Double, firstControl: Double,
                            secondControl: Double) -> Double {
        let inverse = 1 - parameter
        return 3 * inverse * inverse * parameter * firstControl
            + 3 * inverse * parameter * parameter * secondControl
            + parameter * parameter * parameter
    }

    private static func unitValue(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func easingValue(_ value: Double) -> Double {
        value.isFinite ? min(1.5, max(-0.5, value)) : 0
    }
}

extension RibbonAnimationCurve {
    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(x1), Float(y1), Float(x2), Float(y2)
        )
    }
}

struct RibbonAnimationConfiguration: Equatable {
    static let `default` = Self(
        duration: 0.24,
        curve: .easeOut,
        tracking: 5,
        commitProgress: 0.4,
        flickDistance: 0.02,
        flickVelocity: 0.45,
        edgeResistance: 60
    )

    var duration: Double
    let curve: RibbonAnimationCurve
    let tracking: Double
    let commitProgress: Double
    let flickDistance: Double
    let flickVelocity: Double
    let edgeResistance: Double

    init(
        duration: Double,
        curve: RibbonAnimationCurve,
        tracking: Double = 5,
        commitProgress: Double = 0.4,
        flickDistance: Double = 0.02,
        flickVelocity: Double = 0.45,
        edgeResistance: Double = 60
    ) {
        self.duration = duration
        self.curve = curve
        self.tracking = tracking
        self.commitProgress = commitProgress
        self.flickDistance = flickDistance
        self.flickVelocity = flickVelocity
        self.edgeResistance = edgeResistance
    }
}

@MainActor
protocol RibbonFrameDriving: AnyObject {
    func start(onFrame: @escaping (TimeInterval) -> Void) -> Bool
    func stop()
}

func preferredRibbonFrameRate(maximum: Int) -> Float {
    Float(min(60, max(1, maximum)))
}

@MainActor
private final class SystemRibbonFrameDriver: NSObject, RibbonFrameDriving {
    private var displayLink: CADisplayLink?
    private var onFrame: ((TimeInterval) -> Void)?

    func start(onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        stop()
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) ?? NSScreen.main else {
            return false
        }
        let displayLink = screen.displayLink(target: self, selector: #selector(displayFrame(_:)))
        self.onFrame = onFrame
        self.displayLink = displayLink
        // AX window moves are synchronous cross-process messages, not cheap layer
        // updates. On a 120 Hz display, driving several visible ribbon windows at
        // the panel maximum can exhaust the main-run-loop frame budget. A stable
        // 60 Hz cadence is smoother than intermittently missing 120 Hz deadlines.
        let preferred = preferredRibbonFrameRate(maximum: screen.maximumFramesPerSecond)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: preferred,
            maximum: preferred,
            preferred: preferred
        )
        displayLink.add(to: .main, forMode: .common)
        return true
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
    }

    @objc private func displayFrame(_ displayLink: CADisplayLink) {
        onFrame?(displayLink.targetTimestamp)
    }
}

/// Short-lived horizontal animation. No resize calls, snapshots or idle timer.
@MainActor
final class RibbonMotion {
    private struct Timeline {
        let duration: TimeInterval
        let curve: RibbonAnimationCurve
    }

    private struct Animation {
        let from: [String: CGRect]
        let to: [String: CGRect]
        let start: TimeInterval
        let timeline: Timeline
        let update: ([String: CGRect]) -> Void
        let cancellation: () -> Void
        let completion: () -> Void
    }

    private let frameDriver: RibbonFrameDriving
    private let currentTime: () -> TimeInterval
    private var animation: Animation?
    private var followingFrames: (() -> [String: CGRect])?
    private var followingUpdate: (([String: CGRect]) -> Void)?
    private var generation: UInt64 = 0
    private var watchdog: Task<Void, Never>?
    private(set) var frames: [String: CGRect] = [:]
    var isRunning: Bool { animation != nil || followingUpdate != nil }
    var isAnimating: Bool { animation != nil }
    /// A display link stops ticking while the display sleeps. An animation
    /// that has not finished this long after its duration is cancelled so the
    /// awaiting layout worker is released.
    var watchdogGrace: Duration = .seconds(1)
    /// Called before a stalled animation is cancelled.
    var onStall: (() -> Void)?
    /// Benchmark hook: each display tick's timestamp and main-thread seconds spent in it.
    var onFrameTiming: ((_ timestamp: TimeInterval, _ work: TimeInterval) -> Void)?

    init(frameDriver: RibbonFrameDriving = SystemRibbonFrameDriver(),
         currentTime: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.frameDriver = frameDriver
        self.currentTime = currentTime
    }

    static func dragFrames(state: WorkspaceState, from: [String: CGRect], availableFrame: CGRect,
                           gap: CGFloat, displacement: Double,
                           configuration: RibbonAnimationConfiguration = .default) -> [String: CGRect] {
        guard displacement.isFinite, displacement != 0 else { return from }
        guard let transition = horizontalTransition(state: state, from: from, availableFrame: availableFrame,
                                                    gap: gap, displacement: displacement) else {
            let travel = CGFloat(displacement) * availableFrame.width * configuration.tracking
            let resistance = travel / (1 + abs(travel) / configuration.edgeResistance)
            return from.mapValues { $0.offsetBy(dx: resistance, dy: 0) }
        }
        let progress = transitionProgress(displacement: displacement, distance: transition.distance,
                                          availableWidth: availableFrame.width,
                                          tracking: configuration.tracking)
        var frames = from
        for (id, target) in transition.frames {
            guard let start = from[id] else { continue }
            frames[id] = start.offsetBy(dx: (target.minX - start.minX) * progress, dy: 0)
        }
        return frames
    }

    static func horizontalCompletionAction(state: WorkspaceState, from: [String: CGRect], availableFrame: CGRect,
                                           gap: CGFloat, displacement: Double,
                                           velocity: Double,
                                           configuration: RibbonAnimationConfiguration = .default) -> NavigationAction? {
        guard displacement.isFinite, velocity.isFinite,
              let transition = horizontalTransition(state: state, from: from, availableFrame: availableFrame,
                                                    gap: gap, displacement: displacement) else { return nil }
        let progress = transitionProgress(displacement: displacement, distance: transition.distance,
                                          availableWidth: availableFrame.width,
                                          tracking: configuration.tracking)
        let flick = abs(displacement) >= configuration.flickDistance
            && abs(velocity) >= configuration.flickVelocity
            && displacement * velocity > 0
        return progress >= configuration.commitProgress || flick ? transition.action : nil
    }

    private static func horizontalTransition(state: WorkspaceState, from: [String: CGRect],
                                             availableFrame: CGRect, gap: CGFloat,
                                             displacement: Double) -> (action: NavigationAction, frames: [String: CGRect], distance: CGFloat)? {
        let action: NavigationAction = displacement < 0 ? .focusNext : .focusPrevious
        var destination = state
        guard destination.apply(action) else { return nil }
        var observedWidths: [String: CGFloat] = [:]
        var observedHeights: [String: CGFloat] = [:]
        observedWidths.reserveCapacity(from.count)
        observedHeights.reserveCapacity(from.count)
        for (id, frame) in from {
            observedWidths[id] = frame.width
            observedHeights[id] = frame.height
        }
        let placements = WindowLayout.placements(
            for: destination,
            availableFrame: availableFrame,
            gap: gap,
            observedWidths: observedWidths,
            observedHeights: observedHeights
        )
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(placements.count)
        var distance: CGFloat = 0
        for placement in placements {
            frames[placement.windowID] = placement.frame
            if let start = from[placement.windowID] {
                distance = max(distance, abs(placement.frame.minX - start.minX))
            }
        }
        return (action, frames, distance)
    }

    private static func transitionProgress(displacement: Double, distance: CGFloat,
                                           availableWidth: CGFloat, tracking: Double) -> CGFloat {
        if abs(displacement) >= 0.25 { return 1 }
        guard distance > 0, availableWidth.isFinite, availableWidth > 0 else {
            return min(1, CGFloat(abs(displacement) / 0.25))
        }
        let travel = CGFloat(abs(displacement)) * availableWidth * tracking
        return min(1, travel / distance)
    }

    func cancel() {
        let cancellation = animation?.cancellation
        generation &+= 1
        watchdog?.cancel()
        watchdog = nil
        frameDriver.stop()
        animation = nil
        followingFrames = nil
        followingUpdate = nil
        cancellation?()
    }

    /// Trackpad callbacks can arrive between display refreshes. Keep only the newest
    /// geometry and write it once on the next refresh instead of queueing stale positions.
    func follow(frames: @escaping () -> [String: CGRect],
                update: @escaping ([String: CGRect]) -> Void) {
        if animation != nil { cancel() }
        let wasFollowing = followingUpdate != nil
        followingFrames = frames
        followingUpdate = update
        guard !wasFollowing else { return }
        guard startFrameDriver() else {
            let frames = frames()
            self.frames = frames
            followingFrames = nil
            followingUpdate = nil
            update(frames)
            return
        }
    }

    func animate(from: [String: CGRect], to: [String: CGRect],
                 configuration: RibbonAnimationConfiguration = .default,
                 initialHorizontalVelocity: CGFloat? = nil,
                 update: @escaping ([String: CGRect]) -> Void,
                 cancellation: @escaping () -> Void = {},
                 completion: @escaping () -> Void) {
        cancel()
        let currentGeneration = generation
        frames = from
        guard configuration.duration > 0, from != to else {
            finishImmediately(to: to, generation: currentGeneration, update: update,
                              cancellation: cancellation, completion: completion)
            return
        }
        animation = Animation(
            from: from,
            to: to,
            start: currentTime(),
            timeline: Self.timeline(
                from: from,
                to: to,
                duration: configuration.duration,
                curve: configuration.curve,
                initialHorizontalVelocity: initialHorizontalVelocity
            ),
            update: update,
            cancellation: cancellation,
            completion: completion
        )
        guard startFrameDriver() else {
            animation = nil
            finishImmediately(to: to, generation: currentGeneration, update: update,
                              cancellation: cancellation, completion: completion)
            return
        }
        startWatchdog(generation: currentGeneration,
                      after: .seconds(animation?.timeline.duration ?? configuration.duration) + watchdogGrace)
    }

    private func startWatchdog(generation watched: UInt64, after delay: Duration) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.generation == watched, self.animation != nil else { return }
            self.onStall?()
            self.cancel()
        }
    }

    /// Cancels only the animation started under `watched`; a later one is left alone.
    private func cancel(ifCurrent watched: UInt64) {
        guard generation == watched, animation != nil else { return }
        cancel()
    }

    /// Without a running animation, `cancel()` has no callback to report. If the
    /// update cancels this motion, report that here so every caller is resumed.
    private func finishImmediately(to: [String: CGRect], generation currentGeneration: UInt64,
                                   update: ([String: CGRect]) -> Void,
                                   cancellation: () -> Void, completion: () -> Void) {
        frames = to
        update(to)
        if generation == currentGeneration { completion() } else { cancellation() }
    }

    /// Resumes false when the motion is cancelled, when the awaiting task is
    /// cancelled, or when the display link stalls past the watchdog.
    func animate(from: [String: CGRect], to: [String: CGRect],
                 configuration: RibbonAnimationConfiguration = .default,
                 initialHorizontalVelocity: CGFloat? = nil,
                 update: @escaping ([String: CGRect]) -> Void) async -> Bool {
        let started = StartedAnimation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                animate(
                    from: from,
                    to: to,
                    configuration: configuration,
                    initialHorizontalVelocity: initialHorizontalVelocity,
                    update: update,
                    cancellation: { continuation.resume(returning: false) },
                    completion: { continuation.resume(returning: true) }
                )
                started.generation = generation
            }
        } onCancel: {
            // Runs on the cancelling thread; hop to the main actor for the state.
            Task { @MainActor in
                guard let generation = started.generation else { return }
                self.cancel(ifCurrent: generation)
            }
        }
    }

    /// The generation of the animation an async call started, for its cancellation handler.
    @MainActor
    private final class StartedAnimation {
        var generation: UInt64?
    }

    private func startFrameDriver() -> Bool {
        frameDriver.start { [weak self] timestamp in
            guard let self else { return }
            guard let onFrameTiming = self.onFrameTiming else { return self.advance(to: timestamp) }
            let began = CACurrentMediaTime()
            self.advance(to: timestamp)
            onFrameTiming(began, CACurrentMediaTime() - began)
        }
    }

    private func advance(to timestamp: TimeInterval) {
        if let followingFrames, let followingUpdate {
            frames = followingFrames()
            followingUpdate(frames)
            return
        }
        guard let animation else { return }
        let currentGeneration = generation
        let progress = min(1, max(0, (timestamp - animation.start) / animation.timeline.duration))
        frames = Self.interpolate(
            from: animation.from,
            to: animation.to,
            progress: progress,
            curve: animation.timeline.curve
        )
        animation.update(frames)
        guard generation == currentGeneration else { return }
        if progress >= 1 {
            self.animation = nil
            watchdog?.cancel()
            watchdog = nil
            frameDriver.stop()
            animation.completion()
        }
    }

    static func interpolate(from: [String: CGRect], to: [String: CGRect], progress: Double,
                            curve: RibbonAnimationCurve = .smoother) -> [String: CGRect] {
        let eased = curve.progress(at: min(1, max(0, progress)))
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(to.count)
        for (id, target) in to {
            let start = from[id] ?? target
            // Layout owns vertical alignment; a restored app may still report its parking Y.
            frames[id] = CGRect(x: start.minX + (target.minX - start.minX) * eased,
                                y: target.minY, width: target.width, height: target.height)
        }
        return frames
    }

    private static func timeline(
        from: [String: CGRect],
        to: [String: CGRect],
        duration: TimeInterval,
        curve: RibbonAnimationCurve,
        initialHorizontalVelocity: CGFloat?
    ) -> Timeline {
        let configured = Timeline(duration: duration.isFinite && duration > 0 ? duration : 1, curve: curve)
        guard duration.isFinite, duration > 0,
              let initialHorizontalVelocity, initialHorizontalVelocity.isFinite,
              initialHorizontalVelocity != 0 else { return configured }
        let deltas = to.compactMap { id, target -> CGFloat? in
            guard let start = from[id] else { return nil }
            let delta = target.minX - start.minX
            return delta.isFinite && delta != 0 ? delta : nil
        }
        guard !deltas.isEmpty else { return configured }
        let aligned = deltas.filter { $0 * initialHorizontalVelocity > 0 }
        // At either end of the ribbon the release velocity points away from every
        // target. Continuing that velocity adds a second edge translation before
        // returning. Use the configured curve for the monotonic return instead.
        guard let referenceDelta = aligned.max(by: { abs($0) < abs($1) }) else { return configured }
        let progressVelocity = Double(initialHorizontalVelocity / referenceDelta)
        guard progressVelocity.isFinite, progressVelocity > 0 else { return configured }
        // Use one velocity-matched timeline for the whole ribbon. A shared progress
        // keeps clamped offscreen neighbors and the focused window visually connected.
        let x1 = max(0.01, curve.x1)
        let matchedDuration = min(duration, 1 / (x1 * progressVelocity))
        let y1 = min(1, x1 * progressVelocity * matchedDuration)
        return Timeline(
            duration: matchedDuration,
            curve: RibbonAnimationCurve(x1: x1, y1: y1, x2: curve.x2, y2: 1)
        )
    }

    static func pixelAligned(_ position: CGPoint, backingScaleFactor: CGFloat) -> CGPoint {
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGPoint(
            x: (position.x * scale).rounded() / scale,
            y: (position.y * scale).rounded() / scale
        )
    }
}
