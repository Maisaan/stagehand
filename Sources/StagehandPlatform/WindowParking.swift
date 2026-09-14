import CoreGraphics

/// Per-window parking state. Operations are supplied by the AX adapter so the
/// refusal and restoration paths can be tested without controlling user windows.
struct WindowParking {
    private(set) var restoreFrame: CGRect?
    private(set) var isParked = false
    private var parkingBounds: CGRect?

    mutating func park(frame: CGRect, bounds: CGRect, displays: [CGRect],
                       setPosition: (CGPoint) -> Bool, readFrame: () -> CGRect?) -> Bool {
        if restoreFrame != nil { return isParked }
        guard Self.valid(frame), Self.valid(bounds), !displays.isEmpty, displays.allSatisfy(Self.valid) else { return false }
        restoreFrame = frame
        parkingBounds = bounds
        // Two-edge overhang allows a much smaller horizontal remnant than a
        // side-only move. Leave the title bar reachable rather than using the Dock.
        let destinations = [CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 48),
                            CGPoint(x: bounds.minX + 1 - frame.width, y: bounds.maxY - 48)]
        let containingDisplay = displays.max {
            Self.overlapArea($0, bounds) < Self.overlapArea($1, bounds)
        }
        var attempted = false
        for destination in destinations {
            let proposed = CGRect(origin: destination, size: frame.size)
            // Never spill the parked body onto a neighboring display.
            guard displays.filter({ $0 != containingDisplay }).allSatisfy({ !$0.intersects(proposed) }) else { continue }
            attempted = true
            guard setPosition(destination), let actual = readFrame(), Self.valid(actual),
                  abs(actual.width - frame.width) <= 1, abs(actual.height - frame.height) <= 1,
                  displays.filter({ $0 != containingDisplay }).allSatisfy({ !$0.intersects(actual) }) else { continue }
            let remnant = actual.intersection(bounds)
            if remnant.isNull || (Self.atCorner(actual, bounds: bounds) && remnant.width <= 64 && remnant.height <= 96) {
                isParked = true
                return true
            }
        }
        if !attempted {
            restoreFrame = nil
            parkingBounds = nil
            return false
        }
        // A refusal is not permission to minimize. Roll back, keeping the saved
        // frame when even rollback cannot be confirmed so pause/quit can retry.
        if setPosition(frame.origin), let actual = readFrame(), Self.samePosition(actual, frame) {
            restoreFrame = nil
            parkingBounds = nil
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
            // observed frame, but never mistake an unchanged corner for restoration.
            guard let parkingBounds, actual.intersects(parkingBounds),
                  !Self.atCorner(actual, bounds: parkingBounds) else { return false }
        } else {
            guard Self.samePosition(actual, target) else { return false }
        }
        self.restoreFrame = nil
        parkingBounds = nil
        return true
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private static func samePosition(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        valid(lhs) && abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1
    }

    private static func atCorner(_ frame: CGRect, bounds: CGRect) -> Bool {
        frame.minY >= bounds.maxY - 96 &&
            (frame.minX >= bounds.maxX - 64 || frame.maxX <= bounds.minX + 64)
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = lhs.intersection(rhs)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }
}
