import AppKit
import Carbon
import StagehandCore
import Testing
@testable import StagehandPlatform

/// The input half of a change's felt-delay trace: when input arrived, what typing a
/// transfer held, and how apps answered motion writes. Times and counts only.
@MainActor @Test func aNavigationChordCarriesItsArrivalToTheHandlerAndNowhereElse() throws {
    let gate = FocusInputGate(postEvent: { _, _ in })
    var seen: [InputArrival?] = []
    gate.onNavigationAction = { _ in seen.append(InputArrival.beingDelivered) }
    let chord = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true))
    chord.flags = [.maskControl, .maskAlternate]
    let before = ProcessInfo.processInfo.systemUptime

    #expect(gate.processKeyboardEvent(type: .keyDown, event: chord))

    let arrival = try #require(seen.first ?? nil)
    #expect(arrival.source == .keyboardTap)
    #expect(arrival.receivedUptime >= before)
    let delivered = try #require(arrival.deliveredUptime)
    #expect(delivered >= arrival.receivedUptime)
    if let eventUptime = arrival.eventUptime { #expect(eventUptime <= arrival.receivedUptime) }
    #expect(InputArrival.beingDelivered == nil)
}

@MainActor @Test func committingATransferReportsHowMuchTypingItHeldAndForHowLong() throws {
    let gate = FocusInputGate(postEvent: { _, _ in })
    let token = gate.beginTransfer()
    for key: CGKeyCode in [0, 11] {
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    }
    let committed = ProcessInfo.processInfo.systemUptime

    let release = try #require(gate.commitTransfer(token: token, processIdentifier: 100))

    #expect(release.heldEvents == 2)
    #expect(release.transferAge >= 0)
    if let age = release.oldestHeldEventAge { #expect(age >= 0) }
    #expect(release.postedUptime >= committed)
    // A transfer that already ended releases nothing.
    #expect(gate.commitTransfer(token: token, processIdentifier: 100) == nil)
    #expect(gate.commitTransfer(token: gate.beginTransfer(), processIdentifier: 0) == nil)
}

@MainActor @Test func anEmptyTransferStillReportsItsAge() throws {
    let gate = FocusInputGate(postEvent: { _, _ in })
    let release = try #require(gate.commitTransfer(token: gate.beginTransfer(), processIdentifier: 100))
    #expect(release.heldEvents == 0)
    #expect(release.oldestHeldEventAge == nil)
    #expect(release.transferAge >= 0)
}

@Test func theGestureBufferKeepsTheFrameEachDeliveredEventCameFrom() {
    func arrival(_ uptime: TimeInterval) -> InputArrival {
        InputArrival(source: .trackpad, eventUptime: uptime, receivedUptime: uptime + 0.001, touchesLandedUptime: 1)
    }
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: 0.02, mode: .plain), arrival: arrival(2))
    pending.append(.changed(displacement: 0.03, velocity: 1), arrival: arrival(3))
    pending.append(.changed(displacement: 0.04, velocity: 1), arrival: arrival(4))
    pending.append(.ended(displacement: 0.05, velocity: 1, action: .focusPrevious, mode: .plain), arrival: arrival(5))

    #expect(pending.drainWithArrivals().map { $0.arrival?.eventUptime } == [2, 4, 5])

    pending.append(.began(axis: .horizontal, displacement: 0.02, mode: .plain), arrival: arrival(6))
    pending.append(.ended(displacement: 0.05, velocity: 1, action: .focusPrevious, mode: .plain), arrival: arrival(7))
    #expect(pending.takeCompletion()?.arrival?.eventUptime == 7)
}

@Test func aTouchFrameTimeIsTrustedOnlyNearUptime() {
    #expect(touchFrameUptime(99.99, now: 100) == 99.99)
    #expect(touchFrameUptime(10, now: 100) == nil)
    #expect(touchFrameUptime(.nan, now: 100) == nil)
}

@Test func aTimedOutMotionWriteIsUnacknowledgedNotFailed() {
    var summary = MotionWriteSummary()
    summary.record(.cannotComplete, windowID: "a", finished: 1)
    summary.record(.success, windowID: "a", finished: 2)
    summary.record(.success, windowID: "a", finished: 3)
    summary.record(.invalidUIElement, windowID: "b", finished: 4)

    #expect(summary.acknowledged == 2)
    #expect(summary.unacknowledged == 1)
    #expect(summary.failed == 1)
    #expect(summary.firstAcknowledgedUptime == ["a": 2])
}
