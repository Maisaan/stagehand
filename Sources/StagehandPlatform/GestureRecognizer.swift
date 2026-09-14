import Foundation
import StagehandCore

struct GestureContact: Equatable, Sendable {
    var id: Int32
    var x: Double
    var y: Double
}

/// One action per four-finger contact sequence. Positions use normalized trackpad coordinates.
struct FourFingerRecognizer: Sendable {
    private var origin: [GestureContact] = []
    private var startTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var finished = false
    private(set) var hasFourFingerSequence = false

    mutating func reset() { self = Self() }

    mutating func update(contacts: [GestureContact], timestamp: TimeInterval) -> NavigationAction? {
        guard timestamp.isFinite else { reset(); return nil }
        if contacts.isEmpty { reset(); return nil }
        guard timestamp >= lastTime else { finished = true; return nil }
        lastTime = timestamp
        guard !finished else { return nil }
        guard contacts.count <= 4 else { finished = true; return nil }
        guard contacts.count == 4 else {
            if !origin.isEmpty { finished = true }
            return nil
        }
        guard contacts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0.015...0.985).contains($0.x) && (0.015...0.985).contains($0.y) }),
              Set(contacts.map(\.id)).count == 4 else {
            finished = true
            return nil
        }
        let ordered = contacts.sorted { $0.id < $1.id }
        if origin.isEmpty {
            origin = ordered
            startTime = timestamp
            hasFourFingerSequence = true
            return nil
        }
        guard ordered.map(\.id) == origin.map(\.id), timestamp - startTime <= 1.2 else {
            finished = true
            return nil
        }
        let deltas = zip(ordered, origin).map { (x: $0.x - $1.x, y: $0.y - $1.y) }
        let dx = deltas.reduce(0) { $0 + $1.x } / 4
        let dy = deltas.reduce(0) { $0 + $1.y } / 4
        // Reject pinches, rotation, and a stationary thumb with three moving fingers.
        guard deltas.allSatisfy({ abs($0.x - dx) < 0.035 && abs($0.y - dy) < 0.035 }) else {
            finished = true
            return nil
        }
        let x = abs(dx), y = abs(dy)
        guard max(x, y) >= 0.075 else { return nil }
        if x >= y * 1.35 {
            finished = true
            return dx < 0 ? .focusNext : .focusPrevious
        }
        if y >= x * 1.35 {
            finished = true
            return dy > 0 ? .nextSpace : .previousSpace
        }
        // A long diagonal is ambiguous. Wait for lift instead of unexpectedly choosing an axis.
        if max(x, y) >= 0.12 { finished = true }
        return nil
    }
}
