import CoreGraphics
import Testing
@testable import Stagehand
@testable import StagehandPlatform

private let builtInVisible = CGRect(x: 0, y: 38, width: 1512, height: 944)
private let externalVisible = CGRect(x: 1512, y: 25, width: 1920, height: 1055)

@MainActor @Test func parkedWindowMayShowOnlyItsSideStrip() {
    let atRightEdge = CGRect(x: 1511, y: 200, width: 640, height: 420)
    let wideStrip = CGRect(x: 1448, y: 200, width: 640, height: 420)
    let atLeftEdge = CGRect(x: -639, y: 200, width: 640, height: 420)
    for frame in [atRightEdge, wideStrip, atLeftEdge] {
        #expect(StagehandModel.parkedFrameShowsOnlyRemnant(frame, visibleFrames: [builtInVisible], remnantWidth: 64))
    }
}

@MainActor @Test func parkedWindowLeftInsideAGrownScreenFails() {
    let parkedForTheOldWidth = CGRect(x: 1351, y: 200, width: 640, height: 420)
    #expect(!StagehandModel.parkedFrameShowsOnlyRemnant(parkedForTheOldWidth, visibleFrames: [builtInVisible],
                                                        remnantWidth: 64))
}

@MainActor @Test func parkedWindowOnAnotherDisplayFails() {
    let spilled = CGRect(x: 1700, y: 200, width: 640, height: 420)
    #expect(!StagehandModel.parkedFrameShowsOnlyRemnant(spilled, visibleFrames: [builtInVisible, externalVisible],
                                                        remnantWidth: 64))
}

@MainActor @Test func parkedWindowTouchingOnlyAnEdgeShowsNothing() {
    let pastTheEdge = CGRect(x: 1512, y: 200, width: 640, height: 420)
    #expect(StagehandModel.parkedFrameShowsOnlyRemnant(pastTheEdge, visibleFrames: [builtInVisible], remnantWidth: 64))
}

@MainActor @Test func acceptanceWaitEndsOnTheEventThatMakesItsConditionHold() async {
    let events = AcceptanceEvents()
    var ready = false
    Task { @MainActor in
        events.note("unrelated")
        ready = true
        events.note("ready")
    }
    let held = await events.wait(for: .seconds(5)) { ready }
    #expect(held)
    #expect(events.count("ready") == 1)
}

@MainActor @Test func acceptanceWaitFailsAtItsDeadline() async {
    let events = AcceptanceEvents()
    let started = ContinuousClock.now
    let held = await events.wait(for: .milliseconds(50)) { false }
    #expect(!held)
    #expect(ContinuousClock.now - started >= .milliseconds(50))
}

@MainActor @Test func acceptanceReportsAnUntouchedRunAsNoneAndKeepsItsVerdict() {
    let untouched = OwnerInputReading.observed(OwnerInputTally())
    #expect(StagehandModel.ownerInputLine(untouched) == "Owner input during run: none")
    #expect(StagehandModel.acceptanceVerdict(failures: 0, ownerInput: untouched) == "PASS")
    #expect(StagehandModel.acceptanceVerdict(failures: 2, ownerInput: untouched) == "FAIL")
}

@MainActor @Test func acceptanceMarksATouchedRunInvalidWhateverItsFailures() {
    var tally = OwnerInputTally()
    tally.record(.keyboard, secondsSinceStart: 4.2)
    tally.record(.keyboard, secondsSinceStart: 4.3)
    tally.record(.mouse, secondsSinceStart: 6)
    let touched = OwnerInputReading.observed(tally)
    #expect(StagehandModel.ownerInputLine(touched)
        == "Owner input during run: 3 (keyboard 2, mouse 1), first at 4.2 s; result INVALID")
    #expect(StagehandModel.acceptanceVerdict(failures: 0, ownerInput: touched) == "INVALID (owner input)")
    #expect(StagehandModel.acceptanceVerdict(failures: 3, ownerInput: touched) == "INVALID (owner input)")
}

@MainActor @Test func acceptanceShowsUnknownOwnerInputInTheVerdict() {
    let unknown = OwnerInputReading.unknown(reason: "the input tap could not be created")
    #expect(StagehandModel.ownerInputLine(unknown)
        == "Owner input during run: unknown (the input tap could not be created)")
    #expect(StagehandModel.acceptanceVerdict(failures: 0, ownerInput: unknown) == "PASS (owner input unknown)")
    #expect(StagehandModel.acceptanceVerdict(failures: 1, ownerInput: unknown) == "FAIL (owner input unknown)")
}
