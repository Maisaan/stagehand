import ApplicationServices
import Foundation
import CoreGraphics
import Testing
import StagehandCore
@testable import StagehandPlatform

@MainActor
struct WindowFrameTests {
    @Test func aDialogFollowsItsOwnerWithoutMovingTwiceWhenAppKitAlreadyMovedIt() {
        let ownerBefore = CGPoint(x: 100, y: 100)
        let ownerAfter = CGPoint(x: 500, y: 150)
        let dialogBefore = CGPoint(x: 180, y: 130)

        #expect(WindowSystem.ownedWindowPosition(
            ownerBefore: ownerBefore, ownerAfter: ownerAfter,
            childBefore: dialogBefore, childAfter: dialogBefore
        ) == CGPoint(x: 580, y: 180))
        #expect(WindowSystem.ownedWindowPosition(
            ownerBefore: ownerBefore, ownerAfter: ownerAfter,
            childBefore: dialogBefore, childAfter: CGPoint(x: 580, y: 180)
        ) == nil)
        #expect(WindowSystem.ownedWindowPosition(
            ownerBefore: ownerBefore, ownerAfter: ownerBefore,
            childBefore: dialogBefore, childAfter: CGPoint(x: 200, y: 150)
        ) == nil)
    }

    @Test(arguments: [NavigationAction.focusPrevious, .goToSpace(index: 1)], [CGFloat(0), 1])
    func returningToAParkedSharedWindowDoesNotResizeIt(action: NavigationAction, extraWidth: CGFloat) throws {
        let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["shared", "other"], focusedWindowID: "shared")
        ])
        #expect(state.apply(.shareToSpace(index: 1)) == true)
        let original = try #require(WindowLayout.placements(for: state, availableFrame: viewport)
            .first { $0.windowID == "shared" }).frame
        var actual = original
        actual.size.width += extraWidth
        var parking = WindowParking()
        #expect(parking.park(frame: actual, bounds: viewport, displays: [viewport],
                             setPosition: { actual.origin = $0; return true }, readFrame: { actual }) == true)
        #expect(actual.minY == original.minY)

        #expect(state.apply(.focusNext) == true)
        #expect(state.apply(action) == true)
        let destination = try #require(WindowLayout.placements(for: state, availableFrame: viewport)
            .first { $0.windowID == "shared" && $0.isFocused && $0.isVisible }).frame
        var sizeWrites: [CGSize] = []
        var positionWrites: [CGPoint] = []
        let restored = parking.restore(to: destination, setFrame: { frame in
            WindowSystem.writeFrame(frame: frame, resizeFirst: false, readFrame: { actual }, setSize: { size in
                sizeWrites.append(size)
                actual.size = size
                return true
            }, setPosition: { position in
                positionWrites.append(position)
                actual.origin = position
                return true
            })
        }, readFrame: { actual })

        #expect(restored)
        #expect(actual.origin == destination.origin)
        #expect(actual.width == destination.width + extraWidth)
        #expect(actual.height == destination.height)
        #expect(sizeWrites.isEmpty)
        #expect(positionWrites == [destination.origin])
        #expect(parking.restoreFrame == nil)
    }

    @Test func anUnchangedVisibleSharedWindowNeedsNoFrameWrites() throws {
        let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
        var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["shared"])])
        #expect(state.apply(.shareToSpace(index: 1)) == true)
        let original = try #require(WindowLayout.placements(for: state, availableFrame: viewport).first).frame
        #expect(state.apply(.goToSpace(index: 1)) == true)
        let destination = try #require(WindowLayout.placements(for: state, availableFrame: viewport).first).frame
        #expect(destination == original)
        var writes = 0

        #expect(WindowSystem.writeFrame(frame: destination, readFrame: { original },
                                        setSize: { _ in writes += 1; return true },
                                        setPosition: { _ in writes += 1; return true }))
        #expect(writes == 0)
    }

    @Test func resizingRetriesTheRequestedSizeAfterMoving() {
        var actual = CGRect(x: 0, y: 40, width: 600, height: 400)
        let destination = CGRect(x: 1000, y: 40, width: 1000, height: 700)
        let success = WindowSystem.writeFrame(frame: destination, readFrame: { actual }, setSize: { size in
            // The original display constrains the first size request.
            actual.size = CGSize(width: actual.minX == 0 ? min(size.width, 600) : size.width,
                                 height: size.height)
            return true
        }, setPosition: { position in
            actual.origin = position
            return true
        })

        #expect(success)
        #expect(actual == destination)
    }

    @Test func restoringADifferentSharedWidthMovesBeforeResizing() throws {
        let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["shared"], widthFractions: ["shared": 0.9]),
            SpaceState(windowIDs: ["shared"], widthFractions: ["shared": 0.5])
        ])
        var actual = try #require(WindowLayout.placements(for: state, availableFrame: viewport).first).frame
        var parking = WindowParking()
        #expect(parking.park(frame: actual, bounds: viewport, displays: [viewport],
                             setPosition: { actual.origin = $0; return true }, readFrame: { actual }) == true)
        #expect(state.apply(.goToSpace(index: 1)) == true)
        let destination = try #require(WindowLayout.placements(for: state, availableFrame: viewport).first).frame
        var resizePositions: [CGPoint] = []
        let restored = parking.restore(to: destination, setFrame: { frame in
            WindowSystem.writeFrame(frame: frame, resizeFirst: false, readFrame: { actual }, setSize: { size in
                resizePositions.append(actual.origin)
                actual.size = size
                return true
            }, setPosition: { position in
                actual.origin = position
                return true
            })
        }, readFrame: { actual })

        #expect(restored)
        #expect(actual == destination)
        #expect(resizePositions == [destination.origin])
        #expect(parking.restoreFrame == nil)
    }

    @Test func aFailedPositionWriteIsNotReportedAsSuccess() {
        let original = CGRect(x: 1000, y: 692, width: 900, height: 700)
        let destination = CGRect(x: 0, y: 40, width: 900, height: 700)
        let success = WindowSystem.writeFrame(frame: destination, readFrame: { original },
                                              setSize: { _ in true }, setPosition: { _ in false })
        #expect(!success)
    }

    @Test func aSuccessfulSetterWithoutObservedMovementIsNotSuccess() {
        let original = CGRect(x: 1000, y: 692, width: 900, height: 700)
        let destination = CGRect(x: 0, y: 40, width: 900, height: 700)
        let success = WindowSystem.writeFrame(
            frame: destination,
            readFrame: { original },
            setSize: { _ in true },
            setPosition: { _ in true }
        )

        #expect(!success)
    }

    @Test func observedMovementWinsWhenTheSetterReportsFailure() {
        var actual = CGRect(x: 1000, y: 692, width: 900, height: 700)
        let destination = CGRect(x: 0, y: 40, width: 900, height: 700)
        let success = WindowSystem.writeFrame(
            frame: destination,
            readFrame: { actual },
            setSize: { _ in true },
            setPosition: { position in
                actual.origin = position
                return false
            }
        )

        #expect(success)
    }

    @Test func aFailedRestorePositionDoesNotResizeAtTheParkingSide() {
        let original = CGRect(x: 1000, y: 692, width: 600, height: 700)
        let destination = CGRect(x: 0, y: 40, width: 900, height: 700)
        var sizeWrites = 0
        let success = WindowSystem.writeFrame(frame: destination, resizeFirst: false, readFrame: { original },
                                              setSize: { _ in sizeWrites += 1; return true },
                                              setPosition: { _ in false })
        #expect(!success)
        #expect(sizeWrites == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func aRefusedSizeWriteUsesObservedSize(sizeChanged: Bool, resizeFirst: Bool) {
        var actual = CGRect(x: 1000, y: 692, width: 600, height: 700)
        let destination = CGRect(x: 0, y: 40, width: 900, height: 700)
        let success = WindowSystem.writeFrame(frame: destination, resizeFirst: resizeFirst, readFrame: { actual }, setSize: { size in
            if sizeChanged { actual.size = size }
            return false
        }, setPosition: { position in
            actual.origin = position
            return true
        })

        #expect(actual.origin == destination.origin)
        #expect(success == sizeChanged)
    }
}

/// Batched Accessibility reads replace three round trips per frame. Each attribute
/// keeps its own result, and a busy app must not trigger slower individual reads.
@Test func batchedAttributeReadsKeepPerAttributeErrorsAndNeverRetryABusyApp() throws {
    var point = CGPoint(x: 12, y: 34)
    var error = AXError.noValue
    let position = try #require(AXValueCreate(.cgPoint, &point))
    let missing = try #require(AXValueCreate(.axError, &error))

    let decoded = try #require(WindowSystem.batchedAttributes(
        status: .success, values: [position, missing, NSNull()], count: 3
    ))
    #expect(WindowSystem.point(decoded[0].value) == point)
    #expect(decoded[0].error == .success)
    #expect(decoded[1].value == nil && decoded[1].error == .noValue)
    #expect(decoded[2].value == nil && decoded[2].error == .noValue)

    let busy = try #require(WindowSystem.batchedAttributes(status: .cannotComplete, values: nil, count: 2))
    #expect(busy.allSatisfy { $0.value == nil && $0.error == .cannotComplete })
    // Only an app that rejects batching falls back to individual reads.
    #expect(WindowSystem.batchedAttributes(status: .attributeUnsupported, values: nil, count: 2) == nil)
    #expect(WindowSystem.batchedAttributes(status: .success, values: [position], count: 2) == nil)
}
