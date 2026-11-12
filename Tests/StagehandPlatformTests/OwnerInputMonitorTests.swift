import AppKit
import Testing
@testable import StagehandPlatform

private let stagehandPID: Int64 = 4_242
private let hardwarePID: Int64 = 0

private func recorder(startedAt: TimeInterval = 100) -> OwnerInputRecorder {
    OwnerInputRecorder(syntheticSourcePIDs: [stagehandPID], startedAt: startedAt)
}

@Test func eventsCreatedByOurProcessesAreIgnoredAndEveryOtherSourceCounts() {
    var input = recorder()
    input.receive(eventType: CGEventType.keyDown.rawValue, sourcePID: stagehandPID, at: 101)
    input.receive(eventType: CGEventType.keyDown.rawValue, sourcePID: hardwarePID, at: 102)
    input.receive(eventType: CGEventType.leftMouseDown.rawValue, sourcePID: 777, at: 103)
    #expect(input.reading.touched)
    #expect(input.tally.counts == [.keyboard: 1, .mouse: 1])
    #expect(input.tally.secondsToFirstEvent == 2)
}

@Test func syntheticTypingFromHIDSystemStateCarriesItsCreatorsPIDNotAHardwareMarker() throws {
    let source = CGEventSource(stateID: .hidSystemState)
    let event = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
    let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
    #expect(event.getIntegerValueField(.eventSourceUnixProcessID) == ownPID)
    #expect(event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue))
    var input = OwnerInputRecorder(syntheticSourcePIDs: [ownPID], startedAt: 0)
    input.receive(eventType: event.type.rawValue, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID), at: 1)
    #expect(input.reading == .observed(OwnerInputTally()))
}

@Test func inputKindsCoverKeysPointerScrollAndTrackpadGestures() {
    #expect(OwnerInputKind(eventType: CGEventType.flagsChanged.rawValue) == .keyboard)
    #expect(OwnerInputKind(eventType: CGEventType.mouseMoved.rawValue) == .mouse)
    #expect(OwnerInputKind(eventType: CGEventType.otherMouseDragged.rawValue) == .mouse)
    #expect(OwnerInputKind(eventType: CGEventType.scrollWheel.rawValue) == .scroll)
    #expect(OwnerInputKind(eventType: UInt32(NSEvent.EventType.gesture.rawValue)) == .gesture)
    #expect(OwnerInputKind(eventType: UInt32(NSEvent.EventType.magnify.rawValue)) == .gesture)
    #expect(OwnerInputKind(eventType: CGEventType.tapDisabledByTimeout.rawValue) == nil)
    #expect(OwnerInputKind(eventType: CGEventType.null.rawValue) == nil)
}

@Test func untouchedRunReadsNone() {
    #expect(recorder().reading.summary == "none")
    #expect(!recorder().reading.touched)
}

@Test func touchedRunListsEachKindInOrderAndTheFirstEventTime() {
    var input = recorder(startedAt: 10)
    input.receive(eventType: CGEventType.leftMouseDown.rawValue, sourcePID: hardwarePID, at: 16)
    input.receive(eventType: CGEventType.keyDown.rawValue, sourcePID: hardwarePID, at: 14.2)
    input.receive(eventType: CGEventType.keyUp.rawValue, sourcePID: hardwarePID, at: 14.3)
    #expect(input.reading.summary == "3 (keyboard 2, mouse 1), first at 4.2 s")
}

@Test func aBlindSpotMakesAnUntouchedRunUnknownButNeverHidesSeenInput() {
    var untouched = recorder()
    untouched.noteBlindSpot("the input tap was paused by macOS during the run")
    #expect(untouched.reading == .unknown(reason: "the input tap was paused by macOS during the run"))
    #expect(untouched.reading.summary == "unknown (the input tap was paused by macOS during the run)")

    var touched = recorder()
    touched.noteBlindSpot("the input tap was paused by macOS during the run")
    touched.receive(eventType: CGEventType.scrollWheel.rawValue, sourcePID: hardwarePID, at: 101)
    #expect(touched.reading.touched)
}

@Test func monitorReportsUnknownWhenTheTapCannotBeCreated() {
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: .init(
        inputHiddenReason: { nil }, createTap: { _, _, _ in nil }))
    monitor.start()
    #expect(monitor.stop() == .unknown(reason: "the input tap could not be created"))
}

@Test func monitorReportsUnknownWhenKeysAreHiddenFromTheTap() {
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: .init(
        inputHiddenReason: { "Secure Keyboard Entry is on, so keys are hidden from the tap" },
        createTap: { _, _, _ in nil }))
    monitor.start()
    #expect(monitor.stop() == .unknown(reason: "Secure Keyboard Entry is on, so keys are hidden from the tap"))
}

@Test func monitorThatWasNeverStartedIsUnknown() {
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: .init(
        inputHiddenReason: { nil }, createTap: { _, _, _ in nil }))
    #expect(!monitor.stop().touched)
    #expect(monitor.stop() == .unknown(reason: "the monitor was not started"))
}

/// Delivers tapDisabledByUserInput when the tap is disabled, as macOS does.
private final class FakeTap: @unchecked Sendable {
    private var callback: CGEventTapCallBack?
    private var context: UnsafeMutableRawPointer?
    private(set) var enableCalls: [Bool] = []

    var environment: OwnerInputMonitor.Environment {
        .init(
            inputHiddenReason: { nil },
            createTap: { [self] _, callback, context in
                self.callback = callback
                self.context = context
                return CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
            },
            setTapEnabled: { [self] _, enabled in
                enableCalls.append(enabled)
                if !enabled { deliver(.tapDisabledByUserInput) }
            })
    }

    func deliver(_ type: CGEventType, sourcePID: Int64 = hardwarePID) {
        guard let callback, let event = CGEvent(source: nil),
              let proxy = OpaquePointer(bitPattern: 1) else { return }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: sourcePID)
        _ = callback(proxy, type, event, context)
    }
}

@Test func disablingTheTapToStopIsNotABlindSpot() {
    let tap = FakeTap()
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: tap.environment)
    monitor.start()
    #expect(monitor.stop() == .observed(OwnerInputTally()))
    #expect(tap.enableCalls == [true, false])
}

@Test(arguments: [
    (CGEventType.tapDisabledByTimeout, "the input tap timed out and macOS paused it during the run"),
    (CGEventType.tapDisabledByUserInput, "macOS disabled the input tap for user input during the run"),
])
func aDisableDuringTheRunIsABlindSpotNamedByItsTypeAndReenablesTheTap(type: CGEventType, reason: String) {
    let tap = FakeTap()
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: tap.environment)
    monitor.start()
    tap.deliver(type)
    #expect(monitor.stop() == .unknown(reason: reason))
    #expect(tap.enableCalls == [true, true, false])
}

@Test func inputDuringTheRunCountsAndInputAfterStopDoesNot() {
    let tap = FakeTap()
    let monitor = OwnerInputMonitor(syntheticSourcePIDs: [], environment: tap.environment)
    monitor.start()
    tap.deliver(.keyDown)
    let reading = monitor.stop()
    tap.deliver(.leftMouseDown)
    #expect(reading.touched)
    #expect(monitor.stop() == reading)
    guard case .observed(let tally) = reading else { return }
    #expect(tally.counts == [.keyboard: 1])
}
