import AppKit
import QuartzCore
import StagehandCore

@MainActor
protocol RibbonFrameDriving: AnyObject {
    func start(onFrame: @escaping (TimeInterval) -> Void) -> Bool
    func stop()
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
        let maximum = Float(max(60, screen.maximumFramesPerSecond))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximum),
            maximum: maximum,
            preferred: maximum
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

/// Short-lived position-only animation. No resize calls, snapshots or idle timer.
@MainActor
final class RibbonMotion {
    private struct Animation {
        let from: [String: CGRect]
        let to: [String: CGRect]
        let start: TimeInterval
        let duration: Double
        let update: ([String: CGRect]) -> Void
        let completion: () -> Void
    }

    private static let screenWidthsPerTrackpadWidth = 4.0
    private static let completionProgress = 0.3
    private let frameDriver: RibbonFrameDriving
    private var animation: Animation?
    private var followingUpdate: (([String: CGRect]) -> Void)?
    private var generation: UInt64 = 0
    private(set) var frames: [String: CGRect] = [:]
    var isRunning: Bool { animation != nil || followingUpdate != nil }

    init(frameDriver: RibbonFrameDriving = SystemRibbonFrameDriver()) {
        self.frameDriver = frameDriver
    }

    static func dragFrames(state: WorkspaceState, from: [String: CGRect], availableFrame: CGRect,
                           gap: CGFloat, displacement: Double) -> [String: CGRect] {
        guard displacement.isFinite, displacement != 0 else { return from }
        guard let transition = horizontalTransition(state: state, from: from, availableFrame: availableFrame,
                                                    gap: gap, displacement: displacement) else {
            let travel = CGFloat(displacement) * availableFrame.width * screenWidthsPerTrackpadWidth
            let resistance = travel / (1 + abs(travel) / 60)
            return from.mapValues { $0.offsetBy(dx: resistance, dy: 0) }
        }
        let progress = transitionProgress(displacement: displacement, distance: transition.distance,
                                          availableWidth: availableFrame.width)
        var frames = from
        for (id, target) in transition.frames {
            guard let start = from[id] else { continue }
            frames[id] = start.offsetBy(dx: (target.minX - start.minX) * progress, dy: 0)
        }
        return frames
    }

    static func horizontalCompletionAction(state: WorkspaceState, from: [String: CGRect], availableFrame: CGRect,
                                           gap: CGFloat, displacement: Double,
                                           velocity: Double) -> NavigationAction? {
        guard displacement.isFinite, velocity.isFinite,
              let transition = horizontalTransition(state: state, from: from, availableFrame: availableFrame,
                                                    gap: gap, displacement: displacement) else { return nil }
        let progress = transitionProgress(displacement: displacement, distance: transition.distance,
                                          availableWidth: availableFrame.width)
        let flick = abs(displacement) >= 0.02 && abs(velocity) >= 0.45 && displacement * velocity > 0
        return progress >= completionProgress || flick ? transition.action : nil
    }

    private static func horizontalTransition(state: WorkspaceState, from: [String: CGRect],
                                             availableFrame: CGRect, gap: CGFloat,
                                             displacement: Double) -> (action: NavigationAction, frames: [String: CGRect], distance: CGFloat)? {
        let action: NavigationAction = displacement < 0 ? .focusNext : .focusPrevious
        var destination = state
        guard destination.apply(action) else { return nil }
        let frames = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
            for: destination,
            availableFrame: availableFrame,
            gap: gap,
            observedWidths: from.mapValues(\.width),
            observedHeights: from.mapValues(\.height)
        ).map { ($0.windowID, $0.frame) })
        let distance = frames.reduce(CGFloat.zero) { distance, item in
            guard let start = from[item.key] else { return distance }
            return max(distance, abs(item.value.minX - start.minX))
        }
        return (action, frames, distance)
    }

    private static func transitionProgress(displacement: Double, distance: CGFloat,
                                           availableWidth: CGFloat) -> CGFloat {
        if abs(displacement) >= 0.25 { return 1 }
        guard distance > 0, availableWidth.isFinite, availableWidth > 0 else {
            return min(1, CGFloat(abs(displacement) / 0.25))
        }
        let travel = CGFloat(abs(displacement)) * availableWidth * screenWidthsPerTrackpadWidth
        return min(1, travel / distance)
    }

    func cancel() {
        generation &+= 1
        frameDriver.stop()
        animation = nil
        followingUpdate = nil
    }

    /// Trackpad callbacks can arrive between display refreshes. Keep only the newest
    /// geometry and write it once on the next refresh instead of queueing stale positions.
    func follow(_ frames: [String: CGRect], update: @escaping ([String: CGRect]) -> Void) {
        if animation != nil { cancel() }
        self.frames = frames
        let wasFollowing = followingUpdate != nil
        followingUpdate = update
        guard !wasFollowing else { return }
        guard startFrameDriver() else {
            followingUpdate = nil
            update(frames)
            return
        }
    }

    func animate(from: [String: CGRect], to: [String: CGRect], duration: Double = 0.2,
                 update: @escaping ([String: CGRect]) -> Void, completion: @escaping () -> Void) {
        cancel()
        let currentGeneration = generation
        frames = from
        guard duration > 0, from != to else {
            frames = to
            update(to)
            guard generation == currentGeneration else { return }
            completion()
            return
        }
        animation = Animation(
            from: from,
            to: to,
            start: CACurrentMediaTime(),
            duration: duration,
            update: update,
            completion: completion
        )
        guard startFrameDriver() else {
            animation = nil
            frames = to
            update(to)
            guard generation == currentGeneration else { return }
            completion()
            return
        }
    }

    private func startFrameDriver() -> Bool {
        frameDriver.start { [weak self] timestamp in
            self?.advance(to: timestamp)
        }
    }

    private func advance(to timestamp: TimeInterval) {
        if let followingUpdate {
            followingUpdate(frames)
            return
        }
        guard let animation else { return }
        let currentGeneration = generation
        let progress = min(1, max(0, (timestamp - animation.start) / animation.duration))
        frames = Self.interpolate(from: animation.from, to: animation.to, progress: progress)
        animation.update(frames)
        guard generation == currentGeneration else { return }
        if progress >= 1 {
            self.animation = nil
            frameDriver.stop()
            animation.completion()
        }
    }

    static func interpolate(from: [String: CGRect], to: [String: CGRect], progress: Double) -> [String: CGRect] {
        let progress = min(1, max(0, progress))
        // Solve Emil's existing ease-out curve (0.23, 1, 0.32, 1).
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2
            let x = 3 * (1 - t) * (1 - t) * t * 0.23 + 3 * (1 - t) * t * t * 0.32 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2
        let eased = progress == 0 ? 0 : progress == 1 ? 1 : 1 - pow(1 - t, 3)
        return to.reduce(into: [:]) { result, item in
            let start = from[item.key] ?? item.value
            result[item.key] = CGRect(x: start.minX + (item.value.minX - start.minX) * eased,
                                      y: start.minY + (item.value.minY - start.minY) * eased,
                                      width: item.value.width, height: item.value.height)
        }
    }
}
