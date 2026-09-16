import AppKit
import QuartzCore
import StagehandCore

struct RibbonAnimationCurve: Equatable {
    static let smoother = Self(x1: 0.45, y1: 0, x2: 0.55, y2: 1)
    static let easeInOut = Self(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    static let easeOut = Self(x1: 0.22, y1: 1, x2: 0.36, y2: 1)
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

enum RibbonAnimationPreset: String, CaseIterable, Identifiable {
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

    var curve: RibbonAnimationCurve {
        switch self {
        case .smoother: .smoother
        case .easeInOut: .easeInOut
        case .easeOut: .easeOut
        case .linear: .linear
        }
    }

    static func matching(_ curve: RibbonAnimationCurve) -> Self? {
        allCases.first { $0.curve == curve }
    }
}

struct RibbonAnimationConfiguration: Equatable {
    static let durationRange = 0.06 ... 1.2
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
