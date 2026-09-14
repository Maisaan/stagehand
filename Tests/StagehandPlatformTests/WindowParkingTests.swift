import CoreGraphics
import Testing
@testable import StagehandPlatform

struct WindowParkingTests {
    private let original = CGRect(x: 100, y: 80, width: 900, height: 700)
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let corner = CGRect(x: 1799, y: 1121, width: 900, height: 700)

    private func makeParkedWindow() -> WindowParking {
        var parking = WindowParking()
        var actual = original
        let success = parking.park(frame: original, bounds: display, displays: [display],
                                   setPosition: { actual.origin = $0; return true }, readFrame: { actual })
        #expect(success)
        return parking
    }

    @Test func clampedParkingKeepsTheWindowAtItsCornerWithoutADockOperation() {
        var parking = WindowParking()
        let original = CGRect(x: 100, y: 80, width: 900, height: 700)
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        var actual = original
        let success = parking.park(frame: original, bounds: display, displays: [display], setPosition: { position in
            // Model the clamp contract. Live app compatibility is validated
            // separately; this callback does not pretend to be an AX server.
            actual.origin = CGPoint(x: min(position.x, 1799), y: min(position.y, 1121))
            return true
        }, readFrame: { actual })
        #expect(success)
        #expect(actual.origin == CGPoint(x: 1799, y: 1121))
        #expect(parking.restoreFrame == original)
        #expect(parking.isParked)
    }

    @Test func refusesLargeRemnantsAndRestoresTheOriginalPosition() {
        var parking = WindowParking()
        var positions: [CGPoint] = []
        var actual = original
        let success = parking.park(frame: original, bounds: display, displays: [display], setPosition: { position in
            positions.append(position)
            actual.origin = position == original.origin ? position : CGPoint(x: 1600, y: 900)
            return true
        }, readFrame: { actual })
        #expect(!success)
        #expect(positions.count == 3)
        #expect(positions.last == original.origin)
        #expect(actual == original)
        #expect(parking.restoreFrame == nil)
        #expect(!parking.isParked)
    }

    @Test func triesTheOtherCornerWhenTheFirstCornerIsRefused() {
        var parking = WindowParking()
        var actual = original
        var positions: [CGPoint] = []
        let success = parking.park(frame: original, bounds: display, displays: [display], setPosition: { position in
            positions.append(position)
            if position.x < 0 { actual.origin = position }
            return true
        }, readFrame: { actual })
        #expect(success)
        #expect(positions.count == 2)
        #expect(actual.minX == 1 - original.width)
        #expect(actual.minY == 1121)
    }

    @Test func choosesTheCornerWithoutSpillingOntoANeighbor() {
        var parking = WindowParking()
        let neighbor = display.offsetBy(dx: display.width, dy: 0)
        var positions: [CGPoint] = []
        var actual = original
        let success = parking.park(frame: original, bounds: display, displays: [display, neighbor], setPosition: { position in
            positions.append(position)
            actual.origin = position
            return true
        }, readFrame: { actual })
        #expect(success)
        #expect(positions == [CGPoint(x: 1 - original.width, y: 1121)])
        #expect(!actual.intersects(neighbor))
    }

    @Test func refusesParkingWhenBothCornerBodiesWouldSpillOntoOtherDisplays() {
        var parking = WindowParking()
        var writes = 0
        let neighbors = [display, display.offsetBy(dx: display.width, dy: 0),
                         display.offsetBy(dx: -display.width, dy: 0)]
        let success = parking.park(frame: original, bounds: display, displays: neighbors,
                                   setPosition: { _ in writes += 1; return true }, readFrame: { original })
        #expect(!success)
        #expect(writes == 0)
        #expect(parking.restoreFrame == nil)
    }

    @Test func failedRollbackRetainsRecoveryGeometryAndDoesNotClaimParkingSucceeded() {
        var parking = WindowParking()
        let first = parking.park(frame: original, bounds: display, displays: [display],
                                 setPosition: { _ in false }, readFrame: { original })
        #expect(!first)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)
        let second = parking.park(frame: corner, bounds: display, displays: [display],
                             setPosition: { _ in Issue.record("Must not overwrite pending recovery"); return true },
                             readFrame: { corner })
        #expect(!second)
        #expect(parking.restoreFrame == original)
    }

    @Test func failedOrUnconfirmedRestoreKeepsTheSavedFrameForRetry() {
        var parking = makeParkedWindow()
        let failed = parking.restore(setFrame: { _ in false }, readFrame: { corner })
        #expect(!failed)
        #expect(parking.restoreFrame == original)
        let unconfirmed = parking.restore(setFrame: { _ in true }, readFrame: { corner })
        #expect(!unconfirmed)
        #expect(parking.restoreFrame == original)
        let restored = parking.restore(setFrame: { _ in true }, readFrame: { original })
        #expect(restored)
        #expect(parking.restoreFrame == nil)
    }

    @Test func directLayoutRestoreWritesOnlyTheNewTargetAndAcceptsApplicationConstraints() {
        var parking = makeParkedWindow()
        let requested = CGRect(x: 1770, y: 60, width: 1000, height: 1000)
        let constrained = CGRect(x: 1760, y: 39, width: 723, height: 1130)
        var writes: [CGRect] = []
        let success = parking.restore(to: requested, setFrame: { writes.append($0); return true }, readFrame: { constrained })
        #expect(success)
        #expect(writes == [requested])
        #expect(parking.restoreFrame == nil)
        #expect(!parking.isParked)
    }

    @Test func layoutRestoreRejectsAStaleCornerEvenWhenTheSetterReportsSuccess() {
        var parking = makeParkedWindow()
        let success = parking.restore(to: original, setFrame: { _ in true }, readFrame: { corner })
        #expect(!success)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)
    }

    @Test func layoutRestoreAcceptsObservedMovementWhenTheSizeWriteWasRefused() {
        var parking = makeParkedWindow()
        let requested = CGRect(x: 1770, y: 60, width: 1000, height: 1000)
        let constrained = CGRect(x: 1760, y: 39, width: 723, height: 1130)
        let success = parking.restore(to: requested, setFrame: { _ in false }, readFrame: { constrained })
        #expect(success)
        #expect(parking.restoreFrame == nil)
    }

    @Test func standaloneRestoreRequiresOriginalPositionButAllowsConstrainedSize() {
        var parking = makeParkedWindow()
        let wrongPosition = original.offsetBy(dx: 30, dy: 0)
        let refused = parking.restore(setFrame: { _ in true }, readFrame: { wrongPosition })
        #expect(!refused)
        let constrained = CGRect(origin: original.origin, size: CGSize(width: 720, height: 750))
        let restored = parking.restore(setFrame: { _ in true }, readFrame: { constrained })
        #expect(restored)
        #expect(parking.restoreFrame == nil)
    }
}
