import CoreGraphics

public enum WindowParkingSide: Equatable, Sendable {
    case left
    case right
}

/// Per-window parking state. Operations are supplied by the AX adapter so the
/// refusal and restoration paths can be tested without controlling user windows.
struct WindowParking {
    private(set) var restoreFrame: CGRect?
    private(set) var isParked = false
    private var parkingBounds: CGRect?
    private var parkedFrame: CGRect?

    mutating func park(frame: CGRect, bounds: CGRect, displays: [CGRect], preferredSide: WindowParkingSide? = nil,
                       setPosition: (CGPoint) -> Bool, readFrame: () -> CGRect?) -> Bool {
        guard Self.valid(frame), Self.valid(bounds), !displays.isEmpty, displays.allSatisfy(Self.valid) else { return false }
        let isReparking = restoreFrame != nil
        if isReparking {
            if let actual = readFrame(), Self.valid(actual),
               Self.acceptablyParked(actual, bounds: bounds, displays: displays) {
                isParked = true
                parkingBounds = bounds
                parkedFrame = actual
                return true
            }
            isParked = false
        } else {
            restoreFrame = frame
        }
        parkingBounds = bounds
        if Self.acceptablyParked(frame, bounds: bounds, displays: displays) {
            isParked = true
            parkedFrame = frame
            return true
        }
        // Preserve Y so an app that presents AX moves asynchronously can only
        // enter or leave along the same horizontal axis as ribbon navigation.
        let right = CGPoint(x: bounds.maxX - 1, y: frame.minY)
        let left = CGPoint(x: bounds.minX + 1 - frame.width, y: frame.minY)
        let destinations = preferredSide == .left ? [left, right] : [right, left]
        let containingDisplay = displays.max {
            Self.overlapArea($0, bounds) < Self.overlapArea($1, bounds)
        }
        var attempted = false
        for destination in destinations {
            let proposed = CGRect(origin: destination, size: frame.size)
            // Never spill the parked body onto a neighboring display.
            guard displays.filter({ $0 != containingDisplay }).allSatisfy({ !$0.intersects(proposed) }) else { continue }
            attempted = true
            _ = setPosition(destination)
            guard let actual = readFrame(), Self.valid(actual),
                  abs(actual.width - frame.width) <= 1, abs(actual.height - frame.height) <= 1,
                  displays.filter({ $0 != containingDisplay }).allSatisfy({ !$0.intersects(actual) }) else { continue }
            if Self.acceptablyParked(actual, bounds: bounds, displays: displays) {
                isParked = true
                parkedFrame = actual
                return true
            }
        }
        if !attempted {
            if !isReparking {
                restoreFrame = nil
                parkingBounds = nil
                parkedFrame = nil
            }
            return false
        }
        // A native Space transition can move a parked window onscreen. If
        // re-parking fails, keep its original frame so pause can still restore it.
        if isReparking { return false }
        // A refusal is not permission to minimize. Roll back, keeping the saved
        // frame when even rollback cannot be confirmed so pause/quit can retry.
        _ = setPosition(frame.origin)
        if let actual = readFrame(), Self.samePosition(actual, frame) {
            restoreFrame = nil
            parkingBounds = nil
            parkedFrame = nil
        }
        return false
    }

    mutating func restore(to destination: CGRect? = nil, setFrame: (CGRect) -> Bool, readFrame: () -> CGRect?) -> Bool {
        guard let savedFrame = restoreFrame else { return true }
        let target = destination ?? savedFrame
        guard Self.valid(target) else { return false }
        isParked = false
        // The aggregate setter may fail on a read-only size even though the
        // position moved. Observed geometry decides whether restoration happened.
        _ = setFrame(target)
        guard let actual = readFrame(), Self.valid(actual) else { return false }
        if destination != nil {
            // An app can clamp X, Y, width and height. Let layout reconcile its
            // observed frame, but never mistake an unchanged parked frame for restoration.
            guard let parkingBounds, actual.intersects(parkingBounds) else { return false }
            if let parkedFrame, Self.samePosition(actual, parkedFrame),
               !Self.samePosition(actual, target) { return false }
        } else {
            guard Self.samePosition(actual, target) else { return false }
        }
        self.restoreFrame = nil
        parkingBounds = nil
        parkedFrame = nil
        return true
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private static func samePosition(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        valid(lhs) && abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
    }

    private static func atSide(_ frame: CGRect, bounds: CGRect) -> Bool {
        frame.minX >= bounds.maxX - 64 || frame.maxX <= bounds.minX + 64
    }

    private static func acceptablyParked(_ frame: CGRect, bounds: CGRect, displays: [CGRect]) -> Bool {
        guard let containingDisplay = displays.max(by: {
            overlapArea($0, bounds) < overlapArea($1, bounds)
        }), atSide(frame, bounds: bounds),
              displays.filter({ $0 != containingDisplay }).allSatisfy({ !$0.intersects(frame) }) else {
            return false
        }
        let remnant = frame.intersection(bounds)
        return remnant.isNull || remnant.width <= 64
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
