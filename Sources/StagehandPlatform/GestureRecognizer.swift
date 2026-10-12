import Foundation
import StagehandCore

struct GestureContact: Equatable, Sendable {
    var id: Int32
    var x: Double
    var y: Double
}

public enum GestureAxis: Equatable, Sendable {
    case horizontal, vertical
}

public enum GestureMode: Equatable, Sendable {
    case plain, shortcut
}

/// Displacement is in normalized trackpad coordinates, velocity in those units per second.
/// Only `ended` may commit navigation. A preview must not change keyboard focus.
public enum GestureNavigationEvent: Equatable, Sendable {
    case began(axis: GestureAxis, displacement: Double, mode: GestureMode)
    case changed(displacement: Double, velocity: Double)
    case ended(displacement: Double, velocity: Double, action: NavigationAction?, mode: GestureMode)
    case cancelled
}

public struct GestureNavigationCompletion: Equatable, Sendable {
    public let axis: GestureAxis
    public let displacement: Double
    public let velocity: Double
    public let recognizerAction: NavigationAction?
    public let mode: GestureMode
}

/// Preserve lifecycle boundaries while dropping obsolete visual frames if the main thread is busy.
struct GestureEventBuffer {
    private var events: [(event: GestureNavigationEvent, axis: GestureAxis?)] = []
    private var activeAxis: GestureAxis?
    /// Releases that `drain()` handed to main-actor delivery and that have not finished
    /// their handoff yet. The keyboard tap must keep treating them as pending: a batch may
    /// hold a `.began` whose preview does AX work before the `.ended` begins its transfer.
    private(set) var completionsInFlight = 0

    mutating func append(_ event: GestureNavigationEvent) {
        if case .began(let axis, _, _) = event { activeAxis = axis }
        let buffered = (event, activeAxis)
        if case .changed = event, case .changed = events.last?.event {
            events[events.count - 1] = buffered
        } else {
            events.append(buffered)
        }
        if case .ended = event { activeAxis = nil }
        if case .cancelled = event { activeAxis = nil }
    }

    /// A release is queued, or was drained for delivery and has not finished its handoff.
    var hasCompletion: Bool {
        completionsInFlight > 0 || events.contains { Self.isCompletion($0) }
    }

    private static func isCompletion(_ buffered: (event: GestureNavigationEvent, axis: GestureAxis?)) -> Bool {
        if case .ended = buffered.event { buffered.axis != nil } else { false }
    }

    /// Hands every queued event to delivery. Each completion stays counted until
    /// `completionDelivered()` is called for it.
    mutating func drain() -> [GestureNavigationEvent] {
        completionsInFlight += events.count { if case .ended = $0.event { true } else { false } }
        let result = events.map(\.event)
        events.removeAll(keepingCapacity: true)
        return result
    }

    /// Call after delivering one `.ended` from `drain()` has returned.
    mutating func completionDelivered() {
        completionsInFlight = max(0, completionsInFlight - 1)
    }

    /// Drops queued events without counting their completions as delivered work.
    mutating func removeAll() {
        events.removeAll(keepingCapacity: true)
    }

    /// A keyboard event can reach the main run loop before queued gesture delivery.
    /// Claim the release and its earlier preview events together so the model can resolve
    /// width-dependent completion before routing the keyboard event.
    mutating func takeCompletion() -> GestureNavigationCompletion? {
        for (index, buffered) in events.enumerated() {
            guard case .ended(let displacement, let velocity, let action, let mode) = buffered.event,
                  let axis = buffered.axis else { continue }
            events.removeFirst(index + 1)
            return GestureNavigationCompletion(
                axis: axis,
                displacement: displacement,
                velocity: velocity,
                recognizerAction: action,
                mode: mode
            )
        }
        return nil
    }

}

/// One drag per contact sequence. Wait for all fingers to lift before accepting another.
struct NavigationGestureRecognizer: Sendable {
    /// Contacts must land inside this normalized band; edge touches are usually a palm.
    static let landingCoordinateBounds = 0.015...0.985
    /// Normalized range accepted once a sequence has an origin.
    static let trackedCoordinateBounds = 0.0...1.0
    /// Maximum per-finger deviation from the mean movement before fingers are treated as incoherent.
    static let coherenceTolerance = 0.035
    /// Mean movement needed before an axis is chosen.
    static let axisLockDistance = 0.012
    /// One axis must dominate the other by this ratio to lock.
    static let axisLockRatio = 1.35
    /// A diagonal beyond this distance without a dominant axis is cancelled.
    static let ambiguousDiagonalDistance = 0.12
    /// Release velocity uses samples newer than this window, keeping one older sample.
    static let velocitySampleWindow: TimeInterval = 0.08
    static let maximumVelocitySamples = 12
    /// Velocity is zero when the last sample is older than this at release.
    static let velocityStaleInterval: TimeInterval = 0.1
    /// A flick commits with this displacement and velocity in the same direction.
    static let flickDisplacement = 0.02
    static let flickVelocity = 0.45
    /// A slow drag commits at this displacement.
    static let commitDisplacement = 0.075

    let fingerCount: Int
    private var origin: [GestureContact] = []
    private var lastContacts: [GestureContact] = []
    private var lastTime: TimeInterval = 0
    private var samples: [(time: TimeInterval, displacement: Double)] = []
    private var axis: GestureAxis?
    private var finished = false
    private(set) var cancellationReason: String?
    private(set) var hasContactSequence = false
    var isDragging: Bool { axis != nil && !finished }

    init(fingerCount: Int = 4) {
        self.fingerCount = fingerCount == 3 ? 3 : 4
    }

    mutating func cancelUntilLift() {
        if hasContactSequence { finished = true }
    }

    mutating func update(contacts: [GestureContact], timestamp: TimeInterval) -> GestureNavigationEvent? {
        guard timestamp.isFinite, timestamp >= lastTime else { return cancel(reason: "timestamp") }
        if contacts.isEmpty {
            let event = finish(timestamp: timestamp)
            self = Self(fingerCount: fingerCount)
            return event
        }
        let previousTimestamp = lastTime
        lastTime = timestamp
        guard !finished else { return nil }
        if contacts.count > fingerCount {
            // Landing fingers are noisy and may briefly include a thumb or palm edge.
            // Do not disable the intended gesture before its selected contacts establish
            // an origin. An added contact after recognition starts still cancels it.
            return origin.isEmpty ? nil : cancel(reason: "extra-contact")
        }
        let coordinateBounds = origin.isEmpty ? Self.landingCoordinateBounds : Self.trackedCoordinateBounds
        for (index, contact) in contacts.enumerated() {
            guard contact.x.isFinite, contact.y.isFinite,
                  coordinateBounds.contains(contact.x), coordinateBounds.contains(contact.y),
                  !contacts[..<index].contains(where: { $0.id == contact.id }) else {
                return cancel(reason: "invalid-contact")
            }
        }
        guard contacts.count == fingerCount else {
            guard !origin.isEmpty else { return nil }
            // A normal staggered lift ends immediately. A replacement finger cancels.
            guard contacts.allSatisfy({ contact in origin.contains(where: { $0.id == contact.id }) }) else { return cancel(reason: "replacement-on-lift") }
            if let axis, let previousDisplacement = samples.last?.displacement {
                // The lift callback still contains movement from fingers touching the pad.
                // Measure it against those same fingers in the preceding frame, not a new
                // subset centroid, which would jump when fingers have travelled differently.
                let deltas = contacts.compactMap { contact -> (x: Double, y: Double)? in
                    guard let previous = lastContacts.first(where: { $0.id == contact.id }) else { return nil }
                    return (contact.x - previous.x, contact.y - previous.y)
                }
                guard deltas.count == contacts.count else { return cancel(reason: "missing-lift-history") }
                let dx = deltas.reduce(0) { $0 + $1.x } / Double(deltas.count)
                let dy = deltas.reduce(0) { $0 + $1.y } / Double(deltas.count)
                guard deltas.allSatisfy({ abs($0.x - dx) < Self.coherenceTolerance && abs($0.y - dy) < Self.coherenceTolerance }) else { return cancel(reason: "incoherent-lift") }
                record(displacement: previousDisplacement + (axis == .horizontal ? dx : dy), timestamp: timestamp)
            }
            return finish(timestamp: timestamp)
        }
        let ordered = contacts.sorted { $0.id < $1.id }
        if origin.isEmpty {
            origin = ordered
            lastContacts = ordered
            hasContactSequence = true
            return nil
        }
        // Intent comes from coherent movement, not a deadline after fingers land.
        // Slow starts and resting before moving must remain eligible until lift.
        guard zip(ordered, origin).allSatisfy({ $0.0.id == $0.1.id }) else {
            return cancel(reason: "replacement-contact")
        }
        let (xTotal, yTotal) = zip(ordered, origin).reduce(into: (x: 0.0, y: 0.0)) { total, pair in
            total.x += pair.0.x - pair.1.x
            total.y += pair.0.y - pair.1.y
        }
        let dx = xTotal / Double(fingerCount)
        let dy = yTotal / Double(fingerCount)
        // Require coherent intent before choosing an axis. After the pan is established,
        // follow its centroid like a native pan recognizer. Finger spacing naturally changes
        // during a long swipe and must not cancel an already-visible interaction.
        if axis == nil,
           !zip(ordered, origin).allSatisfy({
               abs(($0.0.x - $0.1.x) - dx) < Self.coherenceTolerance
                   && abs(($0.0.y - $0.1.y) - dy) < Self.coherenceTolerance
           }) {
            return cancel(reason: "incoherent-movement")
        }
        defer { lastContacts = ordered }
        let x = abs(dx), y = abs(dy)
        if let axis {
            let displacement = axis == .horizontal ? dx : dy
            let previousDisplacement = samples.last?.displacement
            record(displacement: displacement, timestamp: timestamp)
            guard displacement != previousDisplacement else { return nil }
            return .changed(displacement: displacement, velocity: velocity(at: timestamp))
        }
        guard max(x, y) >= Self.axisLockDistance else { return nil }
        let lockedAxis: GestureAxis
        if x >= y * Self.axisLockRatio { lockedAxis = .horizontal }
        else if y >= x * Self.axisLockRatio { lockedAxis = .vertical }
        else {
            // A long diagonal is ambiguous. Do not unexpectedly choose an axis.
            return max(x, y) >= Self.ambiguousDiagonalDistance ? cancel(reason: "ambiguous-diagonal") : nil
        }
        axis = lockedAxis
        let displacement = lockedAxis == .horizontal ? dx : dy
        let previousDisplacement = zip(lastContacts, origin).reduce(0.0) { sum, pair in
            sum + (lockedAxis == .horizontal ? pair.0.x - pair.1.x : pair.0.y - pair.1.y)
        } / Double(fingerCount)
        // Resting before the swipe must not dilute its release velocity.
        samples = [(previousTimestamp, previousDisplacement)]
        record(displacement: displacement, timestamp: timestamp)
        return .began(axis: lockedAxis, displacement: displacement, mode: .plain)
    }

    private mutating func record(displacement: Double, timestamp: TimeInterval) {
        // Keep the recent sample window and one preceding sample for a stable release velocity.
        samples.append((timestamp, displacement))
        while samples.count > 2
            && (samples[1].time < timestamp - Self.velocitySampleWindow || samples.count > Self.maximumVelocitySamples) {
            samples.removeFirst()
        }
    }

    private func velocity(at timestamp: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last,
              timestamp - last.time <= Self.velocityStaleInterval, last.time > first.time else { return 0 }
        return (last.displacement - first.displacement) / (last.time - first.time)
    }

    private mutating func finish(timestamp: TimeInterval) -> GestureNavigationEvent? {
        guard !finished else { return nil }
        finished = true
        guard let axis, let displacement = samples.last?.displacement else { return nil }
        let velocity = velocity(at: timestamp)
        let flick = abs(displacement) >= Self.flickDisplacement && abs(velocity) >= Self.flickVelocity
            && displacement * velocity > 0
        let committed = abs(displacement) >= Self.commitDisplacement || flick
        let action: NavigationAction?
        if !committed { action = nil }
        else if axis == .horizontal { action = displacement < 0 ? .focusNext : .focusPrevious }
        else { action = displacement > 0 ? .nextSpace : .previousSpace }
        return .ended(displacement: displacement, velocity: velocity, action: action, mode: .plain)
    }

    private mutating func cancel(reason: String) -> GestureNavigationEvent? {
        let wasDragging = isDragging
        cancellationReason = reason
        finished = true
        return wasDragging ? .cancelled : nil
    }
}
