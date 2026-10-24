import ApplicationServices
import Foundation
import Testing
@testable import StagehandPlatform

@MainActor
private final class FocusDriverFixture: WindowFocusDriving {
    let targetPID: Int32
    var elapsedMilliseconds = 0
    var observationMilliseconds: [Int] = []
    var cancelOnObservation = false
    var targetUnresponsive = false
    private(set) var requestTimes: [Int] = []
    var readings: [WindowFocusReport.Observation]
    private var readingIndex = 0
    private(set) var preparations = 0
    private(set) var requests: [Int] = []

    init(targetPID: Int32 = 123, readings: [WindowFocusReport.Observation]) {
        self.targetPID = targetPID
        self.readings = readings
    }

    func prepare() -> [WindowFocusReport.Operation] {
        preparations += 1
        return [.init("activate", accepted: true)]
    }

    func requestFocus(attempt: Int) -> [WindowFocusReport.Operation] {
        requests.append(attempt)
        requestTimes.append(elapsedMilliseconds)
        return [.init("setFocused", accessibilityStatus: AXError.cannotComplete.rawValue)]
    }

    func observe() -> WindowFocusReport.Observation {
        if cancelOnObservation { withUnsafeCurrentTask { $0?.cancel() } }
        if readingIndex < observationMilliseconds.count {
            elapsedMilliseconds += observationMilliseconds[readingIndex]
        }
        defer { readingIndex += 1 }
        return readings[min(readingIndex, readings.count - 1)]
    }

    func wait(milliseconds: Int) async throws {
        elapsedMilliseconds += milliseconds
    }
}

@Test @MainActor func cancelledFocusDoesNotPrepareOrRequestActivation() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false)])
    let report = await Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await WindowFocusAttempt.run(driver: driver)
    }.value
    #expect(report.outcome == .cancelled)
    #expect(driver.preparations == 0)
    #expect(driver.requests.isEmpty)
}

@Test @MainActor func cancellationDuringInitialObservationDoesNotPrepareActivation() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false)])
    driver.cancelOnObservation = true
    let report = await Task { @MainActor in
        await WindowFocusAttempt.run(driver: driver)
    }.value
    #expect(report.outcome == .cancelled)
    #expect(driver.preparations == 0)
    #expect(driver.requests.isEmpty)
}

private func focusReading(active: Bool, matches: Bool) -> WindowFocusReport.Observation {
    WindowFocusReport.Observation(
        frontmostPID: active ? 123 : 456,
        focusedApplicationPID: active ? 123 : 456,
        focusedApplicationStatus: AXError.success.rawValue,
        focusedWindowStatus: AXError.success.rawValue,
        directFocusedWindowStatus: AXError.success.rawValue,
        directTargetWindowMatches: false,
        targetApplicationActive: active,
        targetWindowMatches: matches
    )
}

private func missingGlobalReading(
    frontmostPID: Int32 = 123,
    active: Bool = true,
    directMatches: Bool = true,
    directStatus: Int32 = AXError.success.rawValue,
    globalStatus: Int32 = AXError.noValue.rawValue
) -> WindowFocusReport.Observation {
    WindowFocusReport.Observation(
        frontmostPID: frontmostPID,
        focusedApplicationPID: nil,
        focusedApplicationStatus: globalStatus,
        focusedWindowStatus: nil,
        directFocusedWindowStatus: directStatus,
        directTargetWindowMatches: directMatches,
        targetApplicationActive: active,
        targetWindowMatches: false
    )
}

/// Slow Electron activations logged 1.5 s confirmations with only two observations:
/// every setter and read to the busy app blocked until AX timed out.
@Test @MainActor func busyTargetGetsNoRequestsUntilActiveAndKeepsTheSlowDeadline() async {
    let inactive = WindowFocusReport.Observation(
        frontmostPID: 456, focusedApplicationPID: nil, focusedApplicationStatus: nil,
        focusedWindowStatus: nil, directFocusedWindowStatus: nil, directTargetWindowMatches: false,
        targetApplicationActive: false, targetWindowMatches: false
    )
    let driver = FocusDriverFixture(readings: Array(repeating: inactive, count: 40) + [
        focusReading(active: true, matches: false),
        focusReading(active: true, matches: false),
        focusReading(active: true, matches: true),
    ])
    driver.targetUnresponsive = true

    let report = await WindowFocusAttempt.run(driver: driver)

    // Activation took longer than the 600 ms deadline for a responsive app.
    #expect(report.outcome == .focused)
    #expect(report.elapsedMilliseconds > 600)
    // Requests resume only after the target became active.
    let activeAt = report.elapsedMilliseconds - 80
    #expect(!driver.requestTimes.isEmpty)
    #expect(driver.requestTimes.allSatisfy { $0 >= activeAt })
}

@Test @MainActor func responsiveTargetThatNeverActivatesStillTimesOutAtTheShortDeadline() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false)])

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .timedOut)
    #expect(report.elapsedMilliseconds < 700)
}

@Test func equivalentAccessibilityWindowFallsBackToUniqueGeometry() {
    let targetFrame = CGRect(x: 323, y: 40, width: 1477, height: 1129)

    #expect(uniqueWindowID(
        matchingFrame: targetFrame,
        among: [
            (id: "other", frame: CGRect(x: 0, y: 0, width: 900, height: 700)),
            (id: "15615:6278", frame: targetFrame),
        ]
    ) == "15615:6278")
    #expect(uniqueWindowID(
        matchingFrame: targetFrame,
        among: [
            (id: "first", frame: targetFrame),
            (id: "second", frame: targetFrame),
        ]
    ) == nil)
}

@Test @MainActor func focusRequiresTheExactWindowEvenWhenTheAppIsActive() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: true, matches: false)])
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .timedOut)
    #expect(report.observations.allSatisfy { !$0.targetWindowMatches })
    #expect(report.elapsedMilliseconds <= 1_600)
    #expect(driver.requests.count <= 15)
}

@Test @MainActor func focusConfirmsOnlyAfterObservedAppAndWindowMatch() async {
    let driver = FocusDriverFixture(readings: [
        focusReading(active: false, matches: false),
        focusReading(active: true, matches: true),
    ])
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .focused)
    #expect(report.observations.last?.targetWindowMatches == true)
    #expect(driver.requests == [0])
}

@Test @MainActor func focusRechecksAfterASlowInvalidObservationConsumesTheBudget() async {
    let invalid = WindowFocusReport.Observation(
        frontmostPID: 456,
        focusedApplicationPID: nil,
        focusedApplicationStatus: AXError.invalidUIElement.rawValue,
        focusedWindowStatus: nil,
        directFocusedWindowStatus: AXError.invalidUIElement.rawValue,
        directTargetWindowMatches: false,
        targetApplicationActive: false,
        targetWindowMatches: false
    )
    let driver = FocusDriverFixture(readings: [
        focusReading(active: false, matches: false),
        invalid,
        focusReading(active: true, matches: true),
    ])
    driver.observationMilliseconds = [0, 511, 0]
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .focused)
    #expect(report.observations.last?.targetWindowMatches == true)
    #expect(driver.requests.count <= 2)
}

@Test @MainActor func focusRetriesAfterSlowAccessibilityFailureDuringAppSwitch() async {
    let switching = missingGlobalReading(frontmostPID: 456, active: false)
    let unavailable = missingGlobalReading(
        directMatches: false,
        directStatus: AXError.invalidUIElement.rawValue,
        globalStatus: AXError.invalidUIElement.rawValue
    )
    let recovered = missingGlobalReading()
    let driver = FocusDriverFixture(readings: [switching, unavailable, unavailable, recovered])
    driver.observationMilliseconds = [0, 508, 0, 0]

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .focused)
    #expect(report.observations.last?.directTargetWindowMatches == true)
    #expect(report.observations.dropLast().allSatisfy { !$0.confirmsFocus(targetPID: driver.targetPID) })
}

@Test @MainActor func focusWaitsForRecoveryAfterConsecutiveSlowAccessibilityFailures() async {
    let unavailable = missingGlobalReading(
        directMatches: false,
        directStatus: AXError.cannotComplete.rawValue,
        globalStatus: AXError.cannotComplete.rawValue
    )
    let driver = FocusDriverFixture(readings: [
        missingGlobalReading(frontmostPID: 456, active: false),
        unavailable,
        unavailable,
        unavailable,
        missingGlobalReading(),
    ])
    driver.observationMilliseconds = [0, 500, 500, 0, 0]

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .focused)
    #expect(report.observations.last?.directTargetWindowMatches == true)
}

@Test @MainActor func focusWaitsForExactWindowAfterApplicationActivates() async {
    let driver = FocusDriverFixture(readings: [
        focusReading(active: false, matches: false),
        focusReading(active: false, matches: false),
        focusReading(active: true, matches: false),
        focusReading(active: true, matches: false),
        focusReading(active: true, matches: false),
        focusReading(active: true, matches: true),
    ])
    driver.observationMilliseconds = [0, 400, 0, 100, 0, 0]

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .focused)
    #expect(report.observations.last?.targetWindowMatches == true)
}

@Test @MainActor func directFallbackAcceptsExactFocusAfterGlobalTimeout() async {
    let reading = missingGlobalReading(globalStatus: AXError.cannotComplete.rawValue)
    let report = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [reading])
    )
    #expect(report.outcome == .focused)
}

@Test @MainActor func startupAcceptsExactTargetFocusWhileGlobalAXStillReportsStagehand() async {
    let reading = WindowFocusReport.Observation(
        frontmostPID: 123,
        focusedApplicationPID: ProcessInfo.processInfo.processIdentifier,
        focusedApplicationStatus: AXError.success.rawValue,
        focusedWindowStatus: nil,
        directFocusedWindowStatus: AXError.success.rawValue,
        directTargetWindowMatches: true,
        targetApplicationActive: true,
        targetWindowMatches: false
    )
    let report = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [reading])
    )
    #expect(report.outcome == .focused)
}

/// Raycast's panel kept the global AX focus while Terminal stayed frontmost, so
/// a swipe to another Terminal window timed out and paused Stagehand.
@Test @MainActor func nonActivatingPanelFromAnotherAppDoesNotBlockExactTargetFocus() async {
    func reading(frontmostPID: Int32, directMatches: Bool) -> WindowFocusReport.Observation {
        WindowFocusReport.Observation(
            frontmostPID: frontmostPID,
            focusedApplicationPID: 999,
            focusedApplicationStatus: AXError.success.rawValue,
            focusedWindowStatus: AXError.success.rawValue,
            directFocusedWindowStatus: AXError.success.rawValue,
            directTargetWindowMatches: directMatches,
            targetApplicationActive: true,
            targetWindowMatches: false
        )
    }
    let focused = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [reading(frontmostPID: 123, directMatches: true)])
    )
    #expect(focused.outcome == .focused)
    let busyTarget = WindowFocusReport.Observation(
        frontmostPID: 123, focusedApplicationPID: 999, focusedApplicationStatus: AXError.success.rawValue,
        focusedWindowStatus: AXError.success.rawValue, directFocusedWindowStatus: AXError.cannotComplete.rawValue,
        directTargetWindowMatches: true, targetApplicationActive: true, targetWindowMatches: false
    )
    for unsafe in [reading(frontmostPID: 123, directMatches: false), reading(frontmostPID: 999, directMatches: true),
                   busyTarget] {
        let report = await WindowFocusAttempt.run(driver: FocusDriverFixture(readings: [unsafe]))
        #expect(report.outcome == .timedOut)
    }
}

/// After the panel closed, global AX named the target app with another of its
/// windows focused. That successful read is never overridden by the direct read.
@Test @MainActor func targetAppFocusingAnotherWindowIsNotConfirmedAfterAPanelCloses() async {
    let panel = WindowFocusReport.Observation(
        frontmostPID: 123, focusedApplicationPID: 999, focusedApplicationStatus: AXError.success.rawValue,
        focusedWindowStatus: AXError.success.rawValue, directFocusedWindowStatus: AXError.success.rawValue,
        directTargetWindowMatches: false, targetApplicationActive: true, targetWindowMatches: false
    )
    let otherWindow = WindowFocusReport.Observation(
        frontmostPID: 123, focusedApplicationPID: 123, focusedApplicationStatus: AXError.success.rawValue,
        focusedWindowStatus: AXError.success.rawValue, directFocusedWindowStatus: AXError.success.rawValue,
        directTargetWindowMatches: true, targetApplicationActive: true, targetWindowMatches: false
    )
    let report = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [panel, panel, otherWindow])
    )
    #expect(report.outcome == .timedOut)
    #expect(report.elapsedMilliseconds <= WindowTuning.focusRecoveryDeadlineMilliseconds + 100)
}

@Test @MainActor func directFallbackRejectsIncompleteOrContradictoryEvidence() async {
    let unsafeReadings = [
        missingGlobalReading(frontmostPID: 456),
        missingGlobalReading(active: false),
        missingGlobalReading(directMatches: false),
        missingGlobalReading(directStatus: AXError.noValue.rawValue),
        missingGlobalReading(globalStatus: AXError.success.rawValue),
    ]
    for reading in unsafeReadings {
        let report = await WindowFocusAttempt.run(
            driver: FocusDriverFixture(readings: [reading])
        )
        #expect(report.outcome == .timedOut)
    }
}

@Test func failedMinimizedReadIsUnknownNotMinimized() {
    // A busy app (Chrome right after closing a sibling window) answers with
    // cannotComplete. Treating that as minimized paused Stagehand on 2026-10-12.
    #expect(WindowSystem.availability(minimizedStatus: .success, minimized: false) == .available)
    #expect(WindowSystem.availability(minimizedStatus: .success, minimized: nil) == .available)
    #expect(WindowSystem.availability(minimizedStatus: .success, minimized: true) == .minimized)
    #expect(WindowSystem.availability(minimizedStatus: .invalidUIElement, minimized: nil) == .closed)
    #expect(WindowSystem.availability(minimizedStatus: .cannotComplete, minimized: nil) == .unknown)
    #expect(WindowSystem.availability(minimizedStatus: .noValue, minimized: nil) == .unknown)
    #expect(WindowSystem.availability(minimizedStatus: .attributeUnsupported, minimized: nil) == .unknown)
    #expect(WindowSystem.availability(minimizedStatus: .apiDisabled, minimized: nil) == .unknown)
}
