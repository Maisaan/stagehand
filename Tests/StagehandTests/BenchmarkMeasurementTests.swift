import Foundation
import Testing
@testable import Stagehand

@MainActor
@Suite(.serialized)
struct BenchmarkMeasurementTests {
    /// The busy-quiet benchmark turns logging off; before 2026-11-12 it then saw no
    /// motion or focus at all and reported n=0 for both.
    @Test func motionAndFocusAreObservedWithLoggingOff() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.diagnostics.isEnabled = false
        var observed: [String] = []
        harness.model.diagnostics.eventObserver = { observed.append($0) }
        defer { harness.model.diagnostics.eventObserver = nil }

        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(observed.contains("ribbon_animation_started"))
        #expect(observed.filter { $0.hasPrefix("navigation_focus_") } == ["navigation_focus_succeeded"])
    }

    /// The benchmark counted the logged navigation_focus_confirmed event as success
    /// even when its focusConfirmed detail was false.
    @Test func aRefusedFocusIsObservedAsRejected() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.refusesFocus = ["b"]
        var observed: [String] = []
        harness.model.diagnostics.eventObserver = { observed.append($0) }
        defer { harness.model.diagnostics.eventObserver = nil }

        harness.model.navigate(.focusNext)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !observed.contains(where: { $0.hasPrefix("navigation_focus_") }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(observed.filter { $0.hasPrefix("navigation_focus_") }.first == "navigation_focus_rejected")
        #expect(!observed.contains("navigation_focus_succeeded"))
    }

    @Test func switchFailuresNameTimeoutsRejectionsAndMissingFocus() {
        var phase = BenchmarkRecord.SwitchPhase()
        phase.switches = [
            .init(focusMs: 20, settledMs: 40),
            .init(focusMs: 30, settledMs: 8_000, timedOut: true),
            .init(focusRejected: true, settledMs: 50),
            .init(settledMs: 10)
        ]
        phase.finalFocusMatches = false

        #expect(BenchmarkRecord.switchFailures(phase, name: "sequential") == [
            "sequential: idle wait timed out after switch 2",
            "sequential: focus rejected on switch 3",
            "sequential: no focus attempt on switch 4",
            "sequential: final focus does not match the ribbon"
        ])
    }

    @Test func rawSamplesKeepMissingValuesAsNullAndLeaveOutPhasesThatDidNotRun() throws {
        var record = BenchmarkRecord()
        record.phases.sequential = .init(switches: [.init(focusMs: 12, settledMs: 30)])
        record.failures = ["spaces: setup failed"]

        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        let phases = json?["phases"] as? [String: Any]
        let first = ((phases?["sequential"] as? [String: Any])?["switches"] as? [[String: Any]])?.first

        #expect(json?["schema"] as? Int == 1)
        #expect(json?["result"] as? String == "fail")
        #expect(phases?.keys.sorted() == ["sequential"])
        #expect(first?["slid"] as? Bool == false)
        #expect(first?["motionScheduledMs"] is NSNull)
        #expect(first?["focusMs"] as? Double == 12)
        #expect(record.resultLine == "Result: FAIL: spaces: setup failed")
    }
}
