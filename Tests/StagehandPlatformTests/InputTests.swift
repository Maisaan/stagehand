import Testing
@testable import StagehandPlatform
import StagehandCore
import AppKit
import Carbon

private func contacts(count: Int = 4, dx: Double = 0, dy: Double = 0) -> [GestureContact] {
    (0..<count).map { GestureContact(id: Int32($0), x: 0.3 + Double($0) * 0.08 + dx, y: 0.4 + dy) }
}

@Test func gestureStaggeredLiftUsesTheRemainingFingersFinalMovement() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.1)
    _ = recognizer.update(contacts: contacts(dx: -0.06), timestamp: 0.3)
    guard case .ended(let displacement, _, let action) = recognizer.update(contacts: contacts(count: 3, dx: -0.09), timestamp: 0.34) else {
        Issue.record("A staggered lift must finish the drag")
        return
    }
    #expect(abs(displacement + 0.09) < 0.001)
    #expect(action == .focusNext)
}

@Test func gestureLockedSwipeAllowsModestFingerTravelDifferences() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.1)
    var moved = contacts(dx: -0.12)
    moved[0].x += 0.06
    guard case .changed = recognizer.update(contacts: moved, timestamp: 0.3) else {
        Issue.record("An established swipe must not abort because one finger travels less")
        return
    }
    guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 0.31) else {
        Issue.record("The established swipe must finish")
        return
    }
    #expect(action == .focusNext)
}

@Test func gestureLockedSwipeStillRejectsPinchingRotationAndAStationaryFinger() {
    for invalidation in 0..<3 {
        var recognizer = NavigationGestureRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.1)
        var moved = contacts(dx: -0.12)
        if invalidation == 0 {
            moved[0].x += 0.16
            moved[3].x -= 0.16
        } else if invalidation == 1 {
            moved[0].y += 0.06
            moved[3].y -= 0.06
        } else {
            moved[0].x += 0.10
        }
        #expect(recognizer.update(contacts: moved, timestamp: 0.3) == .cancelled)
        #expect(recognizer.update(contacts: [], timestamp: 0.31) == nil)
    }
}

@Test func gestureStaggeredLiftDoesNotShiftWhenTheSlowerFingerLifts() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.1)
    var moved = contacts(dx: -0.06)
    moved[3].x += 0.02
    _ = recognizer.update(contacts: moved, timestamp: 0.3)
    guard case .ended(let displacement, _, let action) = recognizer.update(contacts: Array(moved.prefix(3)), timestamp: 0.34) else {
        Issue.record("Missing staggered completion")
        return
    }
    #expect(abs(displacement + 0.055) < 0.001)
    #expect(action == nil)
}

@Test func gestureFlickVelocityDoesNotIncludeRestingTimeBeforeMovement() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(), timestamp: 0.7)
    _ = recognizer.update(contacts: contacts(dx: -0.015), timestamp: 0.71)
    _ = recognizer.update(contacts: contacts(dx: -0.025), timestamp: 0.72)
    guard case .ended(_, let velocity, let action) = recognizer.update(contacts: [], timestamp: 0.73) else {
        Issue.record("Missing flick completion")
        return
    }
    #expect(velocity < -0.45)
    #expect(action == .focusNext)
}

@Test(arguments: [3, 4], [-1.0, 1.0])
func gestureSelectedFingerCountNavigatesSpacesOnFlickAndStaggeredLift(fingerCount: Int, direction: Double) {
    for isFlick in [true, false] {
        var recognizer = NavigationGestureRecognizer(fingerCount: fingerCount)
        _ = recognizer.update(contacts: contacts(count: fingerCount), timestamp: 0)
        guard case .began(axis: .vertical, displacement: _) = recognizer.update(
            contacts: contacts(count: fingerCount, dy: direction * 0.02), timestamp: isFlick ? 0.01 : 0.1) else {
            Issue.record("The selected finger count must begin a vertical space gesture")
            continue
        }
        _ = recognizer.update(contacts: contacts(count: fingerCount, dy: direction * (isFlick ? 0.04 : 0.06)),
                              timestamp: isFlick ? 0.03 : 0.3)
        let remaining = isFlick ? [] : contacts(count: fingerCount - 1, dy: direction * 0.09)
        guard case .ended(_, _, let action) = recognizer.update(contacts: remaining, timestamp: isFlick ? 0.04 : 0.34) else {
            Issue.record("Lifting must finish vertical navigation")
            continue
        }
        #expect(action == (direction > 0 ? .nextSpace : .previousSpace))
        #expect(recognizer.update(contacts: contacts(count: fingerCount, dy: direction * 0.12), timestamp: 0.4) == nil)
    }
}

@Test func gestureThreeFingerSelectionRecognizesTheConfiguredCount() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    #expect(recognizer.update(contacts: contacts(count: 3), timestamp: 0) == nil)
    guard case .began(axis: .horizontal, displacement: let displacement) = recognizer.update(contacts: contacts(count: 3, dx: -0.04), timestamp: 0.1) else {
        Issue.record("Three-finger navigation did not begin before the commit threshold")
        return
    }
    #expect(abs(displacement + 0.04) < 0.001)
    guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 0.11) else {
        Issue.record("Lift did not finish the gesture")
        return
    }
    #expect(action == nil)
}

@Test func gestureDragTracksBeforeCommittingAndFlicksOnLift() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    guard case .began(axis: .horizontal, displacement: _) = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.01) else {
        Issue.record("The ribbon should begin following a small horizontal drag")
        return
    }
    guard case .changed(let displacement, let velocity) = recognizer.update(contacts: contacts(dx: -0.04), timestamp: 0.03) else {
        Issue.record("Dragging must produce a continuous update, not a navigation action")
        return
    }
    #expect(abs(displacement + 0.04) < 0.001)
    #expect(velocity < -0.45)
    guard case .ended(_, _, let action) = recognizer.update(contacts: contacts(count: 3, dx: -0.04), timestamp: 0.04) else {
        Issue.record("First finger lift should complete the drag without waiting for all fingers")
        return
    }
    #expect(action == .focusNext)
    #expect(recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.05) == nil)
}

@Test func gestureSlowShortDragAndStaleFlickReturnWithoutNavigation() {
    for (moveTime, liftTime) in [(0.3, 0.31), (0.03, 0.3)] {
        var recognizer = NavigationGestureRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        _ = recognizer.update(contacts: contacts(dx: -0.04), timestamp: moveTime)
        guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: liftTime) else {
            Issue.record("Missing drag completion")
            continue
        }
        #expect(action == nil)
    }
}

@Test func gestureMixedFingerIdentityAndInvalidTimingCancelPreview() {
    for invalidation in 0..<4 {
        var recognizer = NavigationGestureRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        _ = recognizer.update(contacts: contacts(dx: -0.03), timestamp: 0.1)
        var changed = contacts(dx: -0.1)
        if invalidation == 0 { changed[0].id = 99 }
        if invalidation == 1 { changed = contacts(count: 5, dx: -0.1) }
        if invalidation == 2 { changed[0].x = .nan }
        #expect(recognizer.update(contacts: changed, timestamp: invalidation == 3 ? 0.05 : 0.2) == .cancelled)
        #expect(recognizer.update(contacts: contacts(dx: -0.2), timestamp: 0.3) == nil)
    }
}

@Test func gestureCoalescingPreservesBoundariesAndOnlyLatestDragFrame() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: 0.02))
    for index in 0..<100 {
        pending.append(.changed(displacement: Double(index) / 1_000, velocity: 1))
    }
    pending.append(.ended(displacement: 0.099, velocity: 1, action: .focusPrevious))
    #expect(pending.drain() == [
        .began(axis: .horizontal, displacement: 0.02),
        .changed(displacement: 0.099, velocity: 1),
        .ended(displacement: 0.099, velocity: 1, action: .focusPrevious),
    ])
    #expect(pending.drain().isEmpty)
}

@Test func gestureDirectionReversalTracksTheFingerAndDoesNotCommitAnOldFlick() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
    _ = recognizer.update(contacts: contacts(dx: -0.06), timestamp: 0.2)
    _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.22)
    guard case .ended(let displacement, let velocity, let action) = recognizer.update(contacts: [], timestamp: 0.23) else {
        Issue.record("Missing reversed drag completion")
        return
    }
    #expect(abs(displacement + 0.02) < 0.001)
    #expect(velocity > 0)
    #expect(action == nil)
}

@Test func gestureLongContinuousDragDoesNotTimeOutAndWrongCountDoesNotStart() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    #expect(recognizer.update(contacts: contacts(count: 3, dx: -0.1), timestamp: 0.1) == nil)
    _ = recognizer.update(contacts: [], timestamp: 0.2)
    _ = recognizer.update(contacts: contacts(count: 3), timestamp: 0.3)
    _ = recognizer.update(contacts: contacts(count: 3, dx: -0.03), timestamp: 0.4)
    guard case .changed = recognizer.update(contacts: contacts(count: 3, dx: -0.1), timestamp: 2) else {
        Issue.record("A deliberate continuous drag must not expire like resting fingers")
        return
    }
    guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 2.1) else {
        Issue.record("Missing long drag completion")
        return
    }
    #expect(action == .focusNext)
}

@Test func gestureStationaryContactFramesDoNotScheduleRedundantPreviews() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.04), timestamp: 0.03)
    #expect(recognizer.update(contacts: contacts(dx: -0.04), timestamp: 0.2) == nil)
    guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 0.21) else {
        Issue.record("Missing stationary drag completion")
        return
    }
    #expect(action == nil)
}

@Test func gestureMalformedPartialLiftCancelsRatherThanCommitting() {
    for invalidation in 0..<2 {
        var recognizer = NavigationGestureRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
        var remaining = contacts(count: 3, dx: -0.1)
        if invalidation == 0 { remaining[0].x = .nan }
        else { remaining[0].id = remaining[1].id }
        #expect(recognizer.update(contacts: remaining, timestamp: 0.11) == .cancelled)
    }
}

@Test func gestureCoalescingDoesNotMergeSeparateGestures() {
    var pending = GestureEventBuffer()
    let events: [GestureNavigationEvent] = [
        .began(axis: .horizontal, displacement: 0.02),
        .changed(displacement: 0.03, velocity: 0.1),
        .cancelled,
        .began(axis: .vertical, displacement: -0.02),
        .changed(displacement: -0.03, velocity: -0.1),
        .ended(displacement: -0.03, velocity: -0.1, action: nil),
    ]
    for event in events { pending.append(event) }
    #expect(pending.drain() == events)
}

@Test func gestureReleaseCanBeClaimedBeforeMainDeliveryExactlyOnce() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: -0.02))
    pending.append(.changed(displacement: -0.08, velocity: -0.8))
    pending.append(.ended(displacement: -0.08, velocity: -0.8, action: .focusNext))
    #expect(pending.takeCommittedAction() == .focusNext)
    #expect(pending.takeCommittedAction() == nil)
    #expect(pending.drain().isEmpty)
}

@Test func gestureNormalDeliveryCannotBeClaimedAgainByKeyboard() {
    var pending = GestureEventBuffer()
    pending.append(.ended(displacement: -0.08, velocity: -0.8, action: .focusNext))
    #expect(pending.drain().count == 1)
    #expect(pending.takeCommittedAction() == nil)
}

@Test func gestureReleaseClaimsPreserveLaterSequencesAndNeverActivateCancellation() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: -0.02))
    pending.append(.cancelled)
    pending.append(.began(axis: .horizontal, displacement: 0.02))
    pending.append(.ended(displacement: 0.03, velocity: 0.1, action: nil))
    #expect(pending.takeCommittedAction() == nil)
    pending.append(.began(axis: .horizontal, displacement: -0.02))
    pending.append(.ended(displacement: -0.08, velocity: -0.8, action: .focusNext))
    pending.append(.began(axis: .vertical, displacement: 0.02))
    pending.append(.ended(displacement: 0.08, velocity: 0.8, action: .nextSpace))
    pending.append(.began(axis: .horizontal, displacement: 0.02))
    #expect(pending.takeCommittedAction() == .focusNext)
    #expect(pending.takeCommittedAction() == .nextSpace)
    #expect(pending.takeCommittedAction() == nil)
    #expect(pending.drain() == [.began(axis: .horizontal, displacement: 0.02)])
}

@Test func gestureManualInterruptionWaitsForAllFingersToLift() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.04), timestamp: 0.1)
    recognizer.cancelUntilLift()
    #expect(!recognizer.isDragging)
    #expect(recognizer.hasContactSequence)
    #expect(recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.2) == nil)
    #expect(recognizer.update(contacts: contacts(count: 3), timestamp: 0.3) == nil)
    #expect(recognizer.update(contacts: contacts(), timestamp: 0.4) == nil)
    #expect(recognizer.update(contacts: [], timestamp: 0.5) == nil)
    #expect(!recognizer.hasContactSequence)
    _ = recognizer.update(contacts: contacts(), timestamp: 0.6)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.7)
    guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 0.8) else {
        Issue.record("A fresh gesture should work after the interrupted contacts all lift")
        return
    }
    #expect(action == .focusNext)
}

@Test func gestureInterruptionAfterLiftDoesNotConsumeTheNextGesture() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
    _ = recognizer.update(contacts: [], timestamp: 0.2)
    recognizer.cancelUntilLift()
    _ = recognizer.update(contacts: contacts(), timestamp: 0.3)
    guard case .began = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.4) else {
        Issue.record("An already-lifted interruption must not swallow a fresh gesture")
        return
    }
}

@MainActor @Test func gestureCountDefaultsToFourAndRejectsUnsupportedValues() {
    let input = InputController()
    #expect(input.gestureFingerCount == 4)
    input.gestureFingerCount = 3
    #expect(input.gestureFingerCount == 3)
    input.gestureFingerCount = 5
    #expect(input.gestureFingerCount == 4)
}

@Test func threeFingersNeverNavigate() {
    var recognizer = NavigationGestureRecognizer()
    #expect(recognizer.update(contacts: contacts(count: 3), timestamp: 0) == nil)
    #expect(recognizer.update(contacts: contacts(count: 3, dx: 0.2), timestamp: 0.2) == nil)
    #expect(!recognizer.hasContactSequence)
}

@Test func fourFingersFireOnceUntilAllLift() {
    var recognizer = NavigationGestureRecognizer()
    #expect(recognizer.update(contacts: contacts(), timestamp: 0) == nil)
    #expect(recognizer.hasContactSequence)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
    _ = recognizer.update(contacts: contacts(dx: -0.2), timestamp: 0.2)
    guard case .ended(_, _, let action) = recognizer.update(contacts: contacts(count: 2, dx: -0.2), timestamp: 0.3) else {
        Issue.record("Missing gesture completion")
        return
    }
    #expect(action == .focusNext)
    #expect(recognizer.update(contacts: contacts(), timestamp: 0.4) == nil)
    #expect(recognizer.update(contacts: [], timestamp: 0.5) == nil)
    #expect(!recognizer.hasContactSequence)
    #expect(recognizer.update(contacts: contacts(), timestamp: 0.6) == nil)
    _ = recognizer.update(contacts: contacts(dx: 0.1), timestamp: 0.7)
    guard case .ended(_, _, let secondAction) = recognizer.update(contacts: [], timestamp: 0.8) else {
        Issue.record("Missing second gesture completion")
        return
    }
    #expect(secondAction == .focusPrevious)
}

@Test func verticalAndHorizontalDirectionsAreDistinct() {
    for (dx, dy, expected) in [(0.0, 0.1, NavigationAction.nextSpace), (0, -0.1, .previousSpace), (-0.1, 0.02, .focusNext)] {
        var recognizer = NavigationGestureRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        _ = recognizer.update(contacts: contacts(dx: dx, dy: dy), timestamp: 0.1)
        guard case .ended(_, _, let action) = recognizer.update(contacts: [], timestamp: 0.2) else {
            Issue.record("Missing direction completion")
            continue
        }
        #expect(action == expected)
    }
}

@Test func ambiguousDiagonalCancelsUntilLift() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    #expect(recognizer.update(contacts: contacts(dx: 0.13, dy: 0.13), timestamp: 0.1) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.25), timestamp: 0.2) == nil)
}

@Test func invalidContactsAndStationaryThumbCancel() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    var moved = contacts(dx: 0.12)
    moved[0].x -= 0.12
    #expect(recognizer.update(contacts: moved, timestamp: 0.1) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.2), timestamp: 0.2) == nil)
    _ = recognizer.update(contacts: [], timestamp: 0.3)
    var invalid = contacts()
    invalid[0].x = .nan
    #expect(recognizer.update(contacts: invalid, timestamp: 0.4) == nil)
    #expect(!recognizer.hasContactSequence)
}

@Test func restingAndChangedContactIdentityDoNotFire() {
    var recognizer = NavigationGestureRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    #expect(recognizer.update(contacts: contacts(dx: 0.01), timestamp: 0.1) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.1), timestamp: 1.3) == nil)
    _ = recognizer.update(contacts: [], timestamp: 1.4)
    _ = recognizer.update(contacts: contacts(), timestamp: 1.5)
    var replaced = contacts(dx: 0.1)
    replaced[0].id = 10
    #expect(recognizer.update(contacts: replaced, timestamp: 1.6) == nil)
}

@Test func fiveFingersAndOutOfBoundsAreRejected() {
    var recognizer = NavigationGestureRecognizer()
    #expect(recognizer.update(contacts: contacts(count: 5), timestamp: 0) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.1), timestamp: 0.1) == nil)
    _ = recognizer.update(contacts: [], timestamp: 0.2)
    var edge = contacts()
    edge[0].x = 0
    #expect(recognizer.update(contacts: edge, timestamp: 0.3) == nil)
    #expect(!recognizer.hasContactSequence)
}

@Test func focusTransferTokensKeepTheirOwnEvents() {
    var buffer = InputTransferBuffer<String>()
    let first = buffer.begin()
    #expect(buffer.append("first down", token: first) == true)
    let second = buffer.begin()
    #expect(buffer.append("second down", token: second) == true)
    #expect(buffer.append("first up", token: first) == true)
    #expect(buffer.latestToken == second)
    #expect(buffer.take(token: first) == ["first down", "first up"])
    #expect(buffer.eventCount == 1)
    #expect(buffer.latestToken == second)
    #expect(buffer.take(token: second) == ["second down"])
    #expect(buffer.latestToken == nil)
    #expect(buffer.append("late", token: first) == false)
}

@Test func cancelledTransferCannotLeakIntoAnother() {
    var buffer = InputTransferBuffer<String>()
    let first = buffer.begin()
    #expect(buffer.append("discard", token: first) == true)
    let second = buffer.begin()
    #expect(buffer.append("keep", token: second) == true)
    #expect(buffer.take(token: first) == ["discard"])
    #expect(buffer.take(token: first).isEmpty)
    #expect(buffer.take(token: second) == ["keep"])
    let third = buffer.begin()
    #expect(buffer.append("discard all", token: third) == true)
    #expect(buffer.removeAll() == 1)
    #expect(buffer.latestToken == nil)
}

@Test func keyboardShortcutsHaveUniqueChords() {
    let bindings = ShortcutBinding.defaults
    let keys = bindings.map { "\($0.key):\($0.modifiers)" }
    #expect(Set(keys).count == bindings.count)
}

@MainActor @Test func gateReplaysEachKeyPairToItsOwnTransferAndDoesNotRecapture() throws {
    var posted: [(event: CGEvent, pid: Int32)] = []
    let gate = FocusInputGate(postEvent: { posted.append(($0, $1)) })
    let first = gate.beginTransfer()
    let aDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    aDown.flags = [.maskShift]
    #expect(gate.processKeyboardEvent(type: .keyDown, event: aDown))
    let second = gate.beginTransfer()
    let bDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: bDown))
    let aUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: aUp))
    gate.commitTransfer(token: first, processIdentifier: 100)
    #expect(posted.map(\.pid) == [100, 100])
    #expect(posted.map { $0.event.type } == [.keyDown, .keyUp])
    #expect(posted[0].event.flags.contains(.maskShift))
    #expect(!gate.processKeyboardEvent(type: .keyDown, event: posted[0].event))
    gate.commitTransfer(token: second, processIdentifier: 200)
    let bUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: bUp))
    #expect(posted.map(\.pid) == [100, 100, 200, 200])
    #expect(posted.map { $0.event.type } == [.keyDown, .keyUp, .keyDown, .keyUp])
}

@MainActor @Test func navigationStartsBufferingInsideKeyboardTapAndSkipsCarbon() throws {
    var posted: [CGEvent] = []
    let gate = FocusInputGate(postEvent: { event, _ in posted.append(event) })
    var token: UInt64?
    var actions: [NavigationAction] = []
    gate.onNavigationAction = { action in
        actions.append(action)
        token = gate.beginTransfer()
    }
    let navigationDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true))
    navigationDown.flags = [.maskControl, .maskAlternate]
    #expect(gate.processKeyboardEvent(type: .keyDown, event: navigationDown))
    #expect(actions == [.focusNext])
    let typing = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    typing.flags = []
    #expect(gate.processKeyboardEvent(type: .keyDown, event: typing))
    let navigationUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: false))
    navigationUp.flags = []
    #expect(gate.processKeyboardEvent(type: .keyUp, event: navigationUp))
    gate.commitTransfer(token: try #require(token), processIdentifier: 100)
    #expect(posted.count == 1)
    #expect(posted[0].getIntegerValueField(.keyboardEventKeycode) == 0)
    for code in [kVK_Escape, kVK_ANSI_Comma] {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
        event.flags = [.maskControl, .maskAlternate]
        #expect(!gate.processKeyboardEvent(type: .keyDown, event: event))
    }
    #expect(actions == [.focusNext])
}

@MainActor @Test func cancelledAndOverflowedInputNeverReplaysToUnverifiedProcess() throws {
    var posted = 0
    var discarded = 0
    var expired: [UInt64] = []
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    gate.onInputDiscarded = { discarded += $0 }
    gate.onTransferExpired = { expired.append($0) }
    let token = gate.beginTransfer()
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    event.flags = []
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    for _ in 0..<129 { #expect(gate.processKeyboardEvent(type: .keyDown, event: event)) }
    #expect(discarded == 129)
    #expect(expired == [token])
    gate.commitTransfer(token: token, processIdentifier: 100)
    #expect(posted == 0)
    let release = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: release))
    // New input after the cancelled transfer passes through normally.
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    #expect(!gate.processKeyboardEvent(type: .keyDown, event: event))
}

@MainActor @Test func newPhysicalPressCannotUseStaleDeliveredKeyDestination() throws {
    var destinations: [Int32] = []
    let gate = FocusInputGate(postEvent: { _, pid in destinations.append(pid) })
    let first = gate.beginTransfer()
    let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    down.flags = []
    down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    gate.commitTransfer(token: first, processIdentifier: 100)
    let second = gate.beginTransfer()
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    gate.commitTransfer(token: second, processIdentifier: 200)
    #expect(destinations == [100, 200])
}
