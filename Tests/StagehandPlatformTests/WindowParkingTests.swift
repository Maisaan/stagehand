import AppKit
import CoreGraphics
import Testing
@testable import StagehandPlatform

struct WindowParkingTests {
    private let original = CGRect(x: 100, y: 80, width: 900, height: 700)
    private let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let parkedAtRight = CGRect(x: 1799, y: 80, width: 900, height: 700)

    private func makeParkedWindow() -> WindowParking {
        var parking = WindowParking()
        var actual = original
        let success = parking.park(frame: original, bounds: display, displays: [display],
                                   setPosition: { actual.origin = $0; return true }, readFrame: { actual })
        #expect(success)
        return parking
    }

    @Test func clampedParkingPreservesVerticalPosition() {
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
        #expect(actual.origin == CGPoint(x: 1799, y: original.minY))
        #expect(parking.restoreFrame == original)
        #expect(parking.isParked)
    }

    /// Models an app that keeps 200 points of every window on screen. The default
    /// limit refuses it and rolls back; a wider allowance parks it where it stops.
    @Test func aWiderRemnantAllowanceAcceptsAClampThatTheDefaultRefuses() {
        var actual = original
        // Keeps 200 points of the window on the display at either side.
        let clampedSetter: (CGPoint) -> Bool = { position in
            actual.origin = CGPoint(x: min(max(position.x, 200 - actual.width), 1600), y: position.y)
            return true
        }
        var refused = WindowParking()
        let defaultResult = refused.park(frame: original, bounds: display, displays: [display], preferredSide: .right,
                                         setPosition: clampedSetter, readFrame: { actual })
        #expect(!defaultResult)
        #expect(!refused.isParked)
        #expect(refused.restoreFrame == nil)
        #expect(actual.origin == original.origin)

        var allowed = WindowParking()
        actual = original
        let allowedResult = allowed.park(frame: original, bounds: display, displays: [display], preferredSide: .right,
                                         remnantWidth: 240, setPosition: clampedSetter, readFrame: { actual })
        #expect(allowedResult)
        #expect(allowed.isParked)
        #expect(actual.origin == CGPoint(x: 1600, y: original.minY))
        #expect(allowed.restoreFrame == original)

        // Re-parking judges the window by the same allowance, without another write.
        var writes = 0
        let reparked = allowed.park(frame: actual, bounds: display, displays: [display], preferredSide: .right,
                                    remnantWidth: 240, setPosition: { _ in writes += 1; return true }, readFrame: { actual })
        #expect(reparked)
        #expect(writes == 0)

        let restored = allowed.restore(setFrame: { actual = $0; return true }, readFrame: { actual })
        #expect(restored)
        #expect(actual == original)
        #expect(allowed.restoreFrame == nil)
    }

    @Test func theRemnantAllowanceIsCappedSoAMostlyVisibleWindowIsNeverParked() {
        #expect(WindowParking.clampedRemnantWidth(10) == WindowTuning.parkedRemnantWidth)
        #expect(WindowParking.clampedRemnantWidth(.nan) == WindowTuning.parkedRemnantWidth)
        #expect(WindowParking.clampedRemnantWidth(10_000) == WindowTuning.maximumParkedRemnantWidth)
        var parking = WindowParking()
        var actual = original
        let result = parking.park(frame: original, bounds: display, displays: [display], preferredSide: .right,
                                  remnantWidth: 10_000, setPosition: { position in
            // Keeps 800 points visible at either side, more than any allowance.
            actual.origin = CGPoint(x: min(max(position.x, -100), 1000), y: position.y)
            return true
        }, readFrame: { actual })
        #expect(!result)
        #expect(!parking.isParked)
    }

    @Test func acceptsAWindowAlreadyClampedAtTheDisplayEdge() {
        var parking = WindowParking()
        let clamped = CGRect(x: 1760, y: 39, width: 723, height: 1130)
        var writes = 0

        let success = parking.park(
            frame: clamped,
            bounds: display,
            displays: [display],
            preferredSide: .right,
            setPosition: { _ in
                writes += 1
                return false
            },
            readFrame: { clamped }
        )

        #expect(success)
        #expect(writes == 0)
        #expect(parking.isParked)
    }

    @Test func observedParkingWinsWhenTheSetterReportsFailure() {
        var parking = WindowParking()
        var actual = original

        let success = parking.park(
            frame: original,
            bounds: display,
            displays: [display],
            preferredSide: .right,
            setPosition: { position in
                actual.origin = CGPoint(x: position.x - 39, y: position.y)
                return false
            },
            readFrame: { actual }
        )

        #expect(success)
        #expect(actual.minX == 1760)
        #expect(parking.isParked)
        #expect(parking.restoreFrame == original)
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

    @Test func triesTheOtherSideWhenTheFirstSideIsRefused() {
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
        #expect(actual.minY == original.minY)
    }

    @Test func preferredSideIsTriedFirst() {
        var parking = WindowParking()
        var actual = original
        var positions: [CGPoint] = []
        let success = parking.park(
            frame: original,
            bounds: display,
            displays: [display],
            preferredSide: .left,
            setPosition: { position in
                positions.append(position)
                actual.origin = position
                return true
            },
            readFrame: { actual }
        )

        #expect(success)
        #expect(positions == [CGPoint(x: 1 - original.width, y: original.minY)])
    }

    @Test func choosesTheSideWithoutSpillingOntoANeighbor() {
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
        #expect(positions == [CGPoint(x: 1 - original.width, y: original.minY)])
        #expect(!actual.intersects(neighbor))
    }

    @Test func refusesParkingWhenBothSideBodiesWouldSpillOntoOtherDisplays() {
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
        var actual = original
        let first = parking.park(frame: original, bounds: display, displays: [display],
                                 setPosition: { position in
            if position != original.origin { actual.origin = CGPoint(x: 1600, y: 900) }
            return false
        }, readFrame: { actual })
        #expect(!first)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)
    }

    /// Display arrangement or scaling changes move the parking bounds. Confirming an
    /// existing park must adopt them, or restoring onto the new display looks failed.
    @Test func reparkingAnAlreadyParkedWindowAdoptsTheNewBounds() {
        var parking = makeParkedWindow()
        let moved = CGRect(x: 2000, y: 0, width: 1800, height: 1169)
        var actual = CGRect(x: moved.maxX - 1, y: original.minY, width: original.width, height: original.height)
        let reparked = parking.park(frame: actual, bounds: moved, displays: [moved],
                                    setPosition: { actual.origin = $0; return true }, readFrame: { actual })
        #expect(reparked)

        let destination = CGRect(x: 2100, y: 100, width: 900, height: 700)
        let restored = parking.restore(to: destination, setFrame: { actual = $0; return true }, readFrame: { actual })

        #expect(restored)
        #expect(parking.restoreFrame == nil)
    }

    @Test func pendingRecoveryCanBeParkedAgain() {
        var parking = WindowParking()
        var actual = original
        var allowParking = false
        let first = parking.park(
            frame: original,
            bounds: display,
            displays: [display],
            setPosition: { position in
                if allowParking {
                    actual.origin = position
                } else if position != original.origin {
                    actual.origin = CGPoint(x: 1600, y: 900)
                }
                return false
            },
            readFrame: { actual }
        )
        #expect(!first)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)

        allowParking = true
        let retry = parking.park(
            frame: actual,
            bounds: display,
            displays: [display],
            setPosition: { position in
                actual.origin = position
                return false
            },
            readFrame: { actual }
        )

        #expect(retry)
        #expect(parking.isParked)
        #expect(parking.restoreFrame == original)
    }

    @Test func reparksAWindowMovedOnscreenByANativeSpaceTransition() {
        var parking = WindowParking()
        var actual = original
        let first = parking.park(frame: actual, bounds: display, displays: [display],
                                 setPosition: { actual.origin = $0; return true }, readFrame: { actual })
        #expect(first)

        actual.origin = CGPoint(x: 450, y: 220)

        let second = parking.park(frame: actual, bounds: display, displays: [display],
                                  setPosition: { actual.origin = $0; return true }, readFrame: { actual })
        #expect(second)
        #expect(actual.origin == CGPoint(x: parkedAtRight.minX, y: 220))
        #expect(parking.restoreFrame == original)
    }

    @Test func failedOrUnconfirmedRestoreKeepsTheSavedFrameForRetry() {
        var parking = makeParkedWindow()
        let failed = parking.restore(setFrame: { _ in false }, readFrame: { parkedAtRight })
        #expect(!failed)
        #expect(parking.restoreFrame == original)
        let unconfirmed = parking.restore(setFrame: { _ in true }, readFrame: { parkedAtRight })
        #expect(!unconfirmed)
        #expect(parking.restoreFrame == original)
        let restored = parking.restore(setFrame: { _ in true }, readFrame: { original })
        #expect(restored)
        #expect(parking.restoreFrame == nil)
    }

    @Test func directLayoutRestoreWritesOnlyTheNewTargetAndAcceptsApplicationConstraints() {
        var parking = makeParkedWindow()
        let requested = CGRect(x: 1100, y: 60, width: 1000, height: 1000)
        let constrained = CGRect(x: 1077, y: 39, width: 723, height: 1130)
        var writes: [CGRect] = []
        let success = parking.restore(to: requested, setFrame: { writes.append($0); return true }, readFrame: { constrained })
        #expect(success)
        #expect(writes == [requested])
        #expect(parking.restoreFrame == nil)
        #expect(!parking.isParked)
    }

    /// 2026-10-12T02:53:42Z: a gesture preview asked Finder for a frame near the right
    /// edge; Finder kept 40 points visible (x=1760). Restoration cleared the saved frame,
    /// the next parking pass adopted x=1760 as the frame to return to, and at
    /// 02:58:24Z "Parking restore" succeeded without moving the window.
    @Test func layoutRestoreThatLeavesTheWindowAtTheParkingSideKeepsTheSavedFrame() {
        var parking = makeParkedWindow()
        let requested = CGRect(x: 1770, y: 80, width: 900, height: 700)
        let clamped = CGRect(x: 1760, y: 80, width: 900, height: 700)
        var actual = parkedAtRight
        let moved = parking.restore(to: requested, setFrame: { _ in actual = clamped; return true }, readFrame: { actual })
        #expect(moved)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)

        var writes = 0
        let reparked = parking.park(frame: actual, bounds: display, displays: [display],
                                    setPosition: { _ in writes += 1; return true }, readFrame: { actual })
        #expect(reparked)
        #expect(writes == 0)
        #expect(parking.restoreFrame == original)

        let restored = parking.restore(setFrame: { actual = $0; return true }, readFrame: { actual })
        #expect(restored)
        #expect(actual.origin == original.origin)
        #expect(parking.restoreFrame == nil)
    }

    @Test func parkingAWindowFoundAtTheSideReturnsItOnscreenRatherThanToTheSide() {
        var parking = WindowParking()
        var actual = CGRect(x: 1760, y: 39, width: 920, height: 1130)
        var writes = 0
        let parked = parking.park(frame: actual, bounds: display, displays: [display], preferredSide: .right,
                                  setPosition: { _ in writes += 1; return true }, readFrame: { actual })
        #expect(parked)
        #expect(writes == 0)
        #expect(parking.isParked)
        #expect(parking.restoreFrame == CGRect(x: 880, y: 39, width: 920, height: 1130))

        let restored = parking.restore(setFrame: { actual = $0; return true }, readFrame: { actual })
        #expect(restored)
        #expect(actual.minX == 880)
        #expect(parking.restoreFrame == nil)
    }

    @Test func aScreenWideWindowFoundAtTheSideReturnsToTheLeadingEdge() {
        var parking = WindowParking()
        let actual = CGRect(x: 1760, y: 39, width: 1800, height: 1130)
        let parked = parking.park(frame: actual, bounds: display, displays: [display],
                                  setPosition: { _ in true }, readFrame: { actual })
        #expect(parked)
        #expect(parking.restoreFrame == CGRect(x: 0, y: 39, width: 1800, height: 1130))
    }

    @Test func layoutRestoreRejectsAStaleParkingPositionEvenWhenTheSetterReportsSuccess() {
        var parking = makeParkedWindow()
        let success = parking.restore(to: original, setFrame: { _ in true }, readFrame: { parkedAtRight })
        #expect(!success)
        #expect(parking.restoreFrame == original)
        #expect(!parking.isParked)
    }

    @Test func layoutRestoreAcceptsObservedMovementWhenTheSizeWriteWasRefused() {
        var parking = makeParkedWindow()
        let requested = CGRect(x: 1100, y: 60, width: 1000, height: 1000)
        let constrained = CGRect(x: 1077, y: 39, width: 723, height: 1130)
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

/// 2026-10-01T14:25:21Z: Settings, parked on another space, was hidden but kept an
/// on-screen frame. Every refresh reported it as reappeared and laid out again
/// about five times a second, flickering the focus border until restart.
@MainActor
@Test func parkedNativeWindowHasNoObservedFrameAndIsHiddenAgainIfShown() {
    let system = WindowSystem()
    let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.orderFront(nil)
    let id = system.registerOwnWindow(window: window)

    #expect(system.park(windowID: id, preferredSide: nil))
    #expect(!window.isVisible)
    #expect(system.observedFrame(windowID: id) == nil)

    // Something shows the window again while Stagehand still considers it parked.
    window.orderFront(nil)
    #expect(system.observedFrame(windowID: id) != nil)
    #expect(system.park(windowID: id, preferredSide: nil))
    #expect(!window.isVisible)
}
