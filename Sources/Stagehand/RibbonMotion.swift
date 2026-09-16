import AppKit
import QuartzCore
import StagehandCore

enum RibbonAnimationCurve: String, CaseIterable, Identifiable {
    case smoother
    case easeInOut
    case easeOut
    case linear

    var id: Self { self }

    var title: String {
        switch self {
        case .smoother: "Smoother"
        case .easeInOut: "Ease in/out"
        case .easeOut: "Ease out"
        case .linear: "Linear"
        }
    }

    func progress(at progress: Double) -> Double {
        let progress = min(1, max(0, progress))
        switch self {
        case .smoother:
            return progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        case .easeInOut:
            return progress == 0 ? 0 : progress == 1 ? 1 : (1 - cos(.pi * progress)) / 2
        case .easeOut:
            return 1 - pow(1 - progress, 3)
        case .linear:
            return progress
        }
    }
}

struct RibbonAnimationConfiguration: Equatable {
    static let durationRange = 0.08 ... 0.6
    static let `default` = Self(duration: 0.22, curve: .smoother)

    let duration: Double
    let curve: RibbonAnimationCurve
}

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
        let maximum = Float(max(1, screen.maximumFramesPerSecond))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: maximum,
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

/// Short-lived horizontal animation. No resize calls, snapshots or idle timer.
@MainActor
final class RibbonMotion {
    private struct Animation {
        let from: [String: CGRect]
        let to: [String: CGRect]
        let start: TimeInterval
        let configuration: RibbonAnimationConfiguration
        let update: ([String: CGRect]) -> Void
        let completion: () -> Void
    }

    private static let screenWidthsPerTrackpadWidth = 4.0
    private static let completionProgress = 0.3
    private let frameDriver: RibbonFrameDriving
    private var animation: Animation?
    private var followingFrames: (() -> [String: CGRect])?
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
        followingFrames = nil
        followingUpdate = nil
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
                 update: @escaping ([String: CGRect]) -> Void, completion: @escaping () -> Void) {
        cancel()
        let currentGeneration = generation
        frames = from
        guard configuration.duration > 0, from != to else {
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
            configuration: configuration,
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
        if let followingFrames, let followingUpdate {
            frames = followingFrames()
            followingUpdate(frames)
            return
        }
        guard let animation else { return }
        let currentGeneration = generation
        let progress = min(1, max(0, (timestamp - animation.start) / animation.configuration.duration))
        frames = Self.interpolate(
            from: animation.from,
            to: animation.to,
            progress: progress,
            curve: animation.configuration.curve
        )
        animation.update(frames)
        guard generation == currentGeneration else { return }
        if progress >= 1 {
            self.animation = nil
            frameDriver.stop()
            animation.completion()
        }
    }

    static func interpolate(from: [String: CGRect], to: [String: CGRect], progress: Double,
                            curve: RibbonAnimationCurve = .smoother) -> [String: CGRect] {
        let progress = min(1, max(0, progress))
        let eased = curve.progress(at: progress)
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

    static func pixelAligned(_ position: CGPoint, backingScaleFactor: CGFloat) -> CGPoint {
        let scale = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGPoint(
            x: (position.x * scale).rounded() / scale,
            y: (position.y * scale).rounded() / scale
        )
    }
}
