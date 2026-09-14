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

/// Displacement is in normalized trackpad coordinates, velocity in those units per second.
/// Only `ended` may commit navigation. A preview must not change keyboard focus.
public enum GestureNavigationEvent: Equatable, Sendable {
    case began(axis: GestureAxis, displacement: Double)
    case changed(displacement: Double, velocity: Double)
    case ended(displacement: Double, velocity: Double, action: NavigationAction?)
    case cancelled
}

/// Preserve lifecycle boundaries while dropping obsolete visual frames if the main thread is busy.
struct GestureEventBuffer {
    private var events: [GestureNavigationEvent] = []

    mutating func append(_ event: GestureNavigationEvent) {
        if case .changed = event, case .changed = events.last {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
    }

    mutating func drain() -> [GestureNavigationEvent] {
        let result = events
        events.removeAll(keepingCapacity: true)
        return result
    }

    /// A keyboard event can reach the main run loop before its queued gesture delivery.
    /// Claim the release and its earlier preview events together, so later delivery cannot
    /// navigate twice or restore the preview over the committed window transition.
    mutating func takeCommittedAction() -> NavigationAction? {
        for (index, event) in events.enumerated() {
            if case .ended(_, _, let action?) = event {
                events.removeFirst(index + 1)
                return action
            }
        }
        return nil
    }
}

/// One drag per contact sequence. Wait for all fingers to lift before accepting another.
struct NavigationGestureRecognizer: Sendable {
    let fingerCount: Int
    private var origin: [GestureContact] = []
    private var lastContacts: [GestureContact] = []
    private var lastTime: TimeInterval = 0
    private var samples: [(time: TimeInterval, displacement: Double)] = []
    private var axis: GestureAxis?
    private var finished = false
    private(set) var hasContactSequence = false
    var isDragging: Bool { axis != nil && !finished }

    init(fingerCount: Int = 4) {
        self.fingerCount = fingerCount == 3 ? 3 : 4
    }

    mutating func cancelUntilLift() {
        if hasContactSequence { finished = true }
    }

    mutating func update(contacts: [GestureContact], timestamp: TimeInterval) -> GestureNavigationEvent? {
        guard timestamp.isFinite, timestamp >= lastTime else { return cancel() }
        if contacts.isEmpty {
            let event = finish(timestamp: timestamp)
            self = Self(fingerCount: fingerCount)
            return event
        }
        let previousTimestamp = lastTime
        lastTime = timestamp
        guard !finished else { return nil }
        guard contacts.count <= fingerCount else { return cancel() }
        let coordinateBounds = origin.isEmpty ? 0.015...0.985 : 0.0...1.0
        guard contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && coordinateBounds.contains($0.x) && coordinateBounds.contains($0.y) }),
              Set(contacts.map(\.id)).count == contacts.count else {
            return cancel()
        }
        guard contacts.count == fingerCount else {
            guard !origin.isEmpty else { return nil }
            // A normal staggered lift ends immediately. A replacement finger cancels.
            guard contacts.allSatisfy({ contact in origin.contains(where: { $0.id == contact.id }) }) else { return cancel() }
            if let axis, let previousDisplacement = samples.last?.displacement {
                // The lift callback still contains movement from fingers touching the pad.
                // Measure it against those same fingers in the preceding frame, not a new
                // subset centroid, which would jump when fingers have travelled differently.
                let deltas = contacts.compactMap { contact -> (x: Double, y: Double)? in
                    guard let previous = lastContacts.first(where: { $0.id == contact.id }) else { return nil }
                    return (contact.x - previous.x, contact.y - previous.y)
                }
                guard deltas.count == contacts.count else { return cancel() }
                let dx = deltas.reduce(0) { $0 + $1.x } / Double(deltas.count)
                let dy = deltas.reduce(0) { $0 + $1.y } / Double(deltas.count)
                guard deltas.allSatisfy({ abs($0.x - dx) < 0.035 && abs($0.y - dy) < 0.035 }) else { return cancel() }
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
        guard ordered.map(\.id) == origin.map(\.id) else {
            return cancel()
        }
        let deltas = zip(ordered, origin).map { (x: $0.x - $1.x, y: $0.y - $1.y) }
        let dx = deltas.reduce(0) { $0 + $1.x } / Double(fingerCount)
        let dy = deltas.reduce(0) { $0 + $1.y } / Double(fingerCount)
        // Be strict before choosing a swipe. Once locked, allow modest differences in
        // along-axis travel as fingers extend, while keeping perpendicular drift bounded.
        // Pinches, rotation and a stationary thumb still exceed these bounds.
        let xTolerance = 0.035 + (axis == .horizontal ? abs(dx) * 0.25 : 0)
        let yTolerance = 0.035 + (axis == .vertical ? abs(dy) * 0.25 : 0)
        guard deltas.allSatisfy({ abs($0.x - dx) < xTolerance && abs($0.y - dy) < yTolerance }) else {
            return cancel()
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
        guard max(x, y) >= 0.012 else { return nil }
        let lockedAxis: GestureAxis
        if x >= y * 1.35 { lockedAxis = .horizontal }
        else if y >= x * 1.35 { lockedAxis = .vertical }
        else {
            // A long diagonal is ambiguous. Do not unexpectedly choose an axis.
            return max(x, y) >= 0.12 ? cancel() : nil
        }
        axis = lockedAxis
        let displacement = lockedAxis == .horizontal ? dx : dy
        let previousDisplacement = zip(lastContacts, origin).reduce(0.0) { sum, pair in
            sum + (lockedAxis == .horizontal ? pair.0.x - pair.1.x : pair.0.y - pair.1.y)
        } / Double(fingerCount)
        // Resting before the swipe must not dilute its release velocity.
        samples = [(previousTimestamp, previousDisplacement)]
        record(displacement: displacement, timestamp: timestamp)
        return .began(axis: lockedAxis, displacement: displacement)
    }

    private mutating func record(displacement: Double, timestamp: TimeInterval) {
        // Keep at most 12 recent samples and one preceding sample for a stable release velocity.
        samples.append((timestamp, displacement))
        while samples.count > 2 && (samples[1].time < timestamp - 0.08 || samples.count > 12) {
            samples.removeFirst()
        }
    }

    private func velocity(at timestamp: TimeInterval) -> Double {
        guard let first = samples.first, let last = samples.last,
              timestamp - last.time <= 0.1, last.time > first.time else { return 0 }
        return (last.displacement - first.displacement) / (last.time - first.time)
    }

    private mutating func finish(timestamp: TimeInterval) -> GestureNavigationEvent? {
        guard !finished else { return nil }
        finished = true
        guard let axis, let displacement = samples.last?.displacement else { return nil }
        let velocity = velocity(at: timestamp)
        let flick = abs(displacement) >= 0.02 && abs(velocity) >= 0.45 && displacement * velocity > 0
        let committed = abs(displacement) >= 0.075 || flick
        let action: NavigationAction?
        if !committed { action = nil }
        else if axis == .horizontal { action = displacement < 0 ? .focusNext : .focusPrevious }
        else { action = displacement > 0 ? .nextSpace : .previousSpace }
        return .ended(displacement: displacement, velocity: velocity, action: action)
    }

    private mutating func cancel() -> GestureNavigationEvent? {
        let wasDragging = isDragging
        finished = true
        return wasDragging ? .cancelled : nil
    }
}
