import Testing
@testable import StagehandPlatform
import StagehandCore
import AppKit
import Carbon

private func contacts(count: Int = 4, dx: Double = 0, dy: Double = 0) -> [GestureContact] {
    (0..<count).map { GestureContact(id: Int32($0), x: 0.3 + Double($0) * 0.08 + dx, y: 0.4 + dy) }
}

@Test func threeFingersNeverNavigate() {
    var recognizer = FourFingerRecognizer()
    #expect(recognizer.update(contacts: contacts(count: 3), timestamp: 0) == nil)
    #expect(recognizer.update(contacts: contacts(count: 3, dx: 0.2), timestamp: 0.2) == nil)
    #expect(!recognizer.hasFourFingerSequence)
}

@Test func fourFingersFireOnceUntilAllLift() {
    var recognizer = FourFingerRecognizer()
    #expect(recognizer.update(contacts: contacts(), timestamp: 0) == nil)
    #expect(recognizer.hasFourFingerSequence)
    #expect(recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1) == .focusNext)
    #expect(recognizer.update(contacts: contacts(dx: -0.2), timestamp: 0.2) == nil)
    #expect(recognizer.update(contacts: contacts(count: 2), timestamp: 0.3) == nil)
    #expect(recognizer.update(contacts: contacts(), timestamp: 0.4) == nil)
    #expect(recognizer.update(contacts: [], timestamp: 0.5) == nil)
    #expect(!recognizer.hasFourFingerSequence)
    #expect(recognizer.update(contacts: contacts(), timestamp: 0.6) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.1), timestamp: 0.7) == .focusPrevious)
}

@Test func verticalAndHorizontalDirectionsAreDistinct() {
    for (dx, dy, expected) in [(0.0, 0.1, NavigationAction.nextSpace), (0, -0.1, .previousSpace), (-0.1, 0.02, .focusNext)] {
        var recognizer = FourFingerRecognizer()
        _ = recognizer.update(contacts: contacts(), timestamp: 0)
        #expect(recognizer.update(contacts: contacts(dx: dx, dy: dy), timestamp: 0.1) == expected)
    }
}

@Test func ambiguousDiagonalCancelsUntilLift() {
    var recognizer = FourFingerRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    #expect(recognizer.update(contacts: contacts(dx: 0.13, dy: 0.13), timestamp: 0.1) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.25), timestamp: 0.2) == nil)
}

@Test func invalidContactsAndStationaryThumbCancel() {
    var recognizer = FourFingerRecognizer()
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    var moved = contacts(dx: 0.12)
    moved[0].x -= 0.12
    #expect(recognizer.update(contacts: moved, timestamp: 0.1) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.2), timestamp: 0.2) == nil)
    _ = recognizer.update(contacts: [], timestamp: 0.3)
    var invalid = contacts()
    invalid[0].x = .nan
    #expect(recognizer.update(contacts: invalid, timestamp: 0.4) == nil)
    #expect(!recognizer.hasFourFingerSequence)
}

@Test func restingAndChangedContactIdentityDoNotFire() {
    var recognizer = FourFingerRecognizer()
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
    var recognizer = FourFingerRecognizer()
    #expect(recognizer.update(contacts: contacts(count: 5), timestamp: 0) == nil)
    #expect(recognizer.update(contacts: contacts(dx: 0.1), timestamp: 0.1) == nil)
    _ = recognizer.update(contacts: [], timestamp: 0.2)
    var edge = contacts()
    edge[0].x = 0
    #expect(recognizer.update(contacts: edge, timestamp: 0.3) == nil)
    #expect(!recognizer.hasFourFingerSequence)
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
