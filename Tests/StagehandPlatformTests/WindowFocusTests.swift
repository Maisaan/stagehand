import ApplicationServices
import Foundation
import Testing
@testable import StagehandPlatform

@MainActor
private final class FocusDriverFixture: WindowFocusDriving {
    let targetPID: Int32
    var elapsedMilliseconds = 0
    var observationMilliseconds: [Int] = []
    var readings: [WindowFocusReport.Observation]
    private var readingIndex = 0
    private(set) var requests: [Int] = []

    init(targetPID: Int32 = 123, readings: [WindowFocusReport.Observation]) {
        self.targetPID = targetPID
        self.readings = readings
    }

    func prepare() -> [WindowFocusReport.Operation] {
        [.init("activate", accepted: true)]
    }

    func requestFocus(attempt: Int) -> [WindowFocusReport.Operation] {
        requests.append(attempt)
        return [.init("setFocused", accessibilityStatus: AXError.cannotComplete.rawValue)]
    }

    func observe() -> WindowFocusReport.Observation {
        if readingIndex < observationMilliseconds.count {
            elapsedMilliseconds += observationMilliseconds[readingIndex]
        }
        defer { readingIndex += 1 }
        return readings[min(readingIndex, readings.count - 1)]
    }

    func wait() async throws {
        elapsedMilliseconds += 8
    }
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
    let report = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [focusReading(active: true, matches: false)])
    )
    #expect(report.outcome == .timedOut)
    #expect(report.observations.allSatisfy { !$0.targetWindowMatches })
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
    #expect(driver.requests == [0])
}

@Test @MainActor func directFallbackAcceptsExactFocusAfterGlobalTimeout() async {
    let reading = missingGlobalReading(globalStatus: AXError.cannotComplete.rawValue)
    let report = await WindowFocusAttempt.run(
        driver: FocusDriverFixture(readings: [reading])
    )
    #expect(report.outcome == .focused)
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
