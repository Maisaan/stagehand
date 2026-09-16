import Foundation
import ApplicationServices
import Testing
@testable import StagehandPlatform

@MainActor
private final class FocusDriverFixture: WindowFocusDriving {
    let targetPID: Int32
    var elapsedMilliseconds = 0
    var preparationMilliseconds = 0
    var observationMilliseconds: [Int] = []
    var cancelWait = false
    var readings: [WindowFocusReport.Observation]
    private var readingIndex = 0
    private(set) var requests: [Int] = []

    init(targetPID: Int32 = 123, readings: [WindowFocusReport.Observation]) {
        self.targetPID = targetPID
        self.readings = readings
    }

    func prepare() -> [WindowFocusReport.Operation] {
        elapsedMilliseconds += preparationMilliseconds
        return [.init("activate", accepted: true)]
    }

    func requestFocus(attempt: Int) -> [WindowFocusReport.Operation] {
        requests.append(attempt)
        return [.init("setFocused", accessibilityStatus: -25205)]
    }

    func observe() -> WindowFocusReport.Observation {
        if readingIndex < observationMilliseconds.count {
            elapsedMilliseconds += observationMilliseconds[readingIndex]
        }
        defer { readingIndex += 1 }
        return readings[min(readingIndex, readings.count - 1)]
    }

    func wait() async throws {
        if cancelWait { throw CancellationError() }
        elapsedMilliseconds += 8
    }
}

@Test @MainActor func focusAttemptRechecksAfterASlowInvalidObservationConsumesTheRetryBudget() async {
    // Minimized from an App Store navigation trace. Its first post-activation
    // AX read returned invalidUIElement after blocking past the retry deadline,
    // but the target window owned focus immediately afterward.
    let driver = FocusDriverFixture(readings: [
        focusReading(active: false, matches: false, directMatches: true),
        WindowFocusReport.Observation(
            frontmostPID: 456,
            focusedApplicationPID: nil,
            focusedApplicationStatus: AXError.invalidUIElement.rawValue,
            focusedWindowStatus: nil,
            directFocusedWindowStatus: AXError.invalidUIElement.rawValue,
            directTargetWindowMatches: false,
            targetApplicationActive: false,
            targetWindowMatches: false
        ),
        focusReading(active: true, matches: true)
    ])
    driver.observationMilliseconds = [0, 511, 0]

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .focused)
    #expect(report.observations.last?.targetWindowMatches == true)
    #expect(driver.requests == [0])
}

private func focusReading(active: Bool, matches: Bool, directMatches: Bool = false) -> WindowFocusReport.Observation {
    WindowFocusReport.Observation(frontmostPID: active ? 123 : 456,
                                  focusedApplicationPID: active ? 123 : 456,
                                  focusedApplicationStatus: 0, focusedWindowStatus: 0,
                                  directFocusedWindowStatus: 0, directTargetWindowMatches: directMatches,
                                  targetApplicationActive: active, targetWindowMatches: matches)
}

@Test @MainActor func focusAttemptRequiresTheExactWindowEvenWhenTheAppIsActive() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: true, matches: false)])
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .timedOut)
    #expect(report.elapsedMilliseconds == 184)
    #expect(report.observations.allSatisfy { !$0.targetWindowMatches })
}

@Test @MainActor func focusAttemptDoesNotAcceptAnInactiveAppsRememberedWindow() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false, directMatches: true)])
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .timedOut)
    #expect(report.initialObservation?.directTargetWindowMatches == true)
}

@Test @MainActor func focusAttemptConfirmsOnlyAfterActualFocusObservation() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false),
                                              focusReading(active: true, matches: true)])
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .focused)
    #expect(report.initialObservation?.targetApplicationActive == false)
    #expect(report.observations.last?.targetWindowMatches == true)
    #expect(report.operations.contains { $0.accessibilityStatus == -25205 })
}

@Test @MainActor func focusAttemptReportsCancelledWaitWithoutFurtherWrites() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false)])
    driver.cancelWait = true
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .cancelled)
    #expect(driver.requests == [0])
}

@Test @MainActor func focusAttemptKeepsPreparationTimeVisibleOutsideRetryBudget() async {
    let driver = FocusDriverFixture(readings: [focusReading(active: false, matches: false)])
    driver.preparationMilliseconds = 120
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .timedOut)
    #expect(report.elapsedMilliseconds == 304)
    #expect(report.summary.contains("targetWindowMatches"))
    #expect(!report.summary.contains("title"))
}

@Test @MainActor func focusAttemptAcceptsCapturedCursorFocusDespiteMissingGlobalAXApplication() async throws {
    // Minimized from the trusted installed-app --diagnose-focus trace on 2026-09-14.
    // The global AX query returned noValue after activation. Cursor's direct AX
    // focused window matched, and AppKit subsequently confirmed Cursor frontmost.
    let readings = try JSONDecoder().decode([WindowFocusReport.Observation].self, from: Data(#"""
    [
      {
        "directFocusedWindowStatus": 0, "directTargetWindowMatches": false,
        "focusedApplicationPID": 90325, "focusedApplicationStatus": 0,
        "focusedWindowStatus": 0, "frontmostPID": 90325,
        "targetApplicationActive": false, "targetWindowMatches": false
      },
      {
        "directFocusedWindowStatus": 0, "directTargetWindowMatches": true,
        "focusedApplicationStatus": -25212, "frontmostPID": 90325,
        "targetApplicationActive": false, "targetWindowMatches": false
      },
      {
        "directFocusedWindowStatus": 0, "directTargetWindowMatches": true,
        "focusedApplicationStatus": -25212, "frontmostPID": 44360,
        "targetApplicationActive": true, "targetWindowMatches": false
      }
    ]
    """#.utf8))
    let driver = FocusDriverFixture(targetPID: 44360, readings: readings)
    let report = await WindowFocusAttempt.run(driver: driver)
    #expect(report.outcome == .focused)
    #expect(report.elapsedMilliseconds == 8)
}

@Test @MainActor func focusAttemptAcceptsCapturedSystemSettingsFocusAfterGlobalAXTimeout() async throws {
    // Minimized from a navigation failure after repeated focus changes. AppKit
    // confirmed System Settings was frontmost and its direct focused window was
    // the target, while the system-wide focused-application query timed out.
    let readings = try JSONDecoder().decode([WindowFocusReport.Observation].self, from: Data(#"""
    [
      {
        "directFocusedWindowStatus": 0, "directTargetWindowMatches": true,
        "focusedApplicationStatus": -25204, "frontmostPID": 26830,
        "targetApplicationActive": true, "targetWindowMatches": false
      }
    ]
    """#.utf8))
    let driver = FocusDriverFixture(targetPID: 26830, readings: readings)

    let report = await WindowFocusAttempt.run(driver: driver)

    #expect(report.outcome == .focused)
    #expect(report.elapsedMilliseconds == 0)
    #expect(driver.requests == [0])
}

@Test @MainActor func focusAttemptRejectsIncompleteOrContradictoryDirectFallbackEvidence() async {
    let unsafeReadings = [
        // Another app is still frontmost, despite the target's stale isActive flag.
        missingGlobalReading(frontmostPID: 456),
        missingGlobalReading(active: false),
        // Same app, wrong window. This must not release typing to its sibling.
        missingGlobalReading(directMatches: false),
        missingGlobalReading(directStatus: -25212),
        // The fallback must not override a successful global read reporting a
        // different window.
        missingGlobalReading(globalStatus: 0)
    ]
    for reading in unsafeReadings {
        let report = await WindowFocusAttempt.run(driver: FocusDriverFixture(readings: [reading]))
        #expect(report.outcome == .timedOut)
    }
}

private func missingGlobalReading(frontmostPID: Int32 = 123, active: Bool = true,
                                  directMatches: Bool = true, directStatus: Int32 = 0,
                                  globalStatus: Int32 = -25212) -> WindowFocusReport.Observation {
    WindowFocusReport.Observation(frontmostPID: frontmostPID, focusedApplicationPID: nil,
                                  focusedApplicationStatus: globalStatus, focusedWindowStatus: nil,
                                  directFocusedWindowStatus: directStatus, directTargetWindowMatches: directMatches,
                                  targetApplicationActive: active, targetWindowMatches: false)
}

@Test @MainActor func focusAttemptCanConfirmWithoutCollectingDiagnosticHistory() async {
    let driver = FocusDriverFixture(readings: [missingGlobalReading()])
    let report = await WindowFocusAttempt.run(driver: driver, recordDiagnostics: false)
    #expect(report.outcome == .focused)
    #expect(report.initialObservation == nil)
    #expect(report.operations.isEmpty)
    #expect(report.observations.isEmpty)
}
