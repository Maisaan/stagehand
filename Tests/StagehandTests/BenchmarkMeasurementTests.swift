import Foundation
import Testing
@testable import Stagehand
@testable import StagehandPlatform

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

    /// Real typing during a run skews its timing; such a run must not count as a result.
    @Test func ownerInputDuringARunFailsItAndIsRecorded() throws {
        var touched = BenchmarkRecord()
        var tally = OwnerInputTally()
        tally.record(.keyboard, secondsSinceStart: 2)
        touched.noteOwnerInput(.observed(tally))
        var untouched = BenchmarkRecord()
        untouched.noteOwnerInput(.observed(OwnerInputTally()))

        #expect(!touched.passed)
        #expect(touched.failures.first?.hasPrefix("owner input during run:") == true)
        #expect(untouched.passed)
        #expect(untouched.ownerInput == "none")
        let json = try JSONSerialization.jsonObject(with: untouched.jsonData()) as? [String: Any]
        #expect(json?["ownerInput"] as? String == "none")
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
        #expect(json?["build"] == nil)
    }

    private func endedTrace(id: Int, queued: TimeInterval, outcome: String = "completed",
                            _ fill: (inout ChangeTrace) -> Void = { _ in }) -> EndedChangeTrace {
        var trace = ChangeTrace(input: nil, queued: queued)
        fill(&trace)
        return EndedChangeTrace(changeID: id, operation: "action.focusNext", outcome: outcome, trace: trace)
    }

    /// busy-quiet logs nothing, so a switch's queue wait, first acknowledged write and
    /// stall steps come from the change trace, which is filled either way.
    @Test func aSwitchTakesItsFeltDelaysFromItsOwnChangesTrace() throws {
        let recorder = BenchmarkSwitchRecorder()
        recorder.begin(at: 10)
        recorder.expectChange(2)
        recorder.observe(endedTrace(id: 1, queued: 9.0) { $0.started = 9.5; $0.ended = 9.9 })
        var writes = MotionWriteSummary()
        writes.acknowledged = 14
        writes.unacknowledged = 1
        recorder.observe(endedTrace(id: 2, queued: 10.0) { trace in
            trace.started = 10.002
            trace.motionScheduled = 10.004
            trace.firstAcknowledgedWrite = 10.020
            trace.motionEnded = 10.250
            trace.motionWrites = writes
            trace.focusRequested = 10.251
            trace.focusConfirmed = 10.400
            trace.ended = 10.420
        })

        let timing = recorder.finish()
        #expect(timing.changeOutcome == "completed")
        #expect(abs((timing.queueWaitMs ?? 0) - 2) < 1e-6)
        #expect(abs((timing.firstAcknowledgedWriteMs ?? 0) - 20) < 1e-6)
        #expect(abs((timing.motionEndedMs ?? 0) - 250) < 1e-6)
        #expect(timing.motionWritesAcknowledged == 14)
        #expect(timing.motionWritesUnacknowledged == 1)
        #expect(timing.motionWritesFailed == 0)
        #expect(recorder.changeStep(at: 9.6) == "started")
        #expect(recorder.changeStep(at: 10.1) == "motionScheduled")
        #expect(recorder.changeStep(at: 10.3) == "focusRequested")
        #expect(recorder.changeStep(at: 9.95) == nil)
    }

    @Test func aSwitchWithoutMotionKeepsItsTraceKeysAsNull() throws {
        var record = BenchmarkRecord()
        var timing = BenchmarkRecord.Switch(focusMs: 12, settledMs: 30)
        timing.note(endedTrace(id: 1, queued: 1) { $0.started = 1.001; $0.focusConfirmed = 1.2 })
        record.phases.spaces = .init(switches: [timing], stalls: [.init(waitedMs: 80, label: "unlabeled",
                                                                        phase: "before", changeStep: nil)])

        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        let spaces = (json?["phases"] as? [String: Any])?["spaces"] as? [String: Any]
        let first = try #require((spaces?["switches"] as? [[String: Any]])?.first)
        #expect(first["changeOutcome"] as? String == "completed")
        #expect(first["queueWaitMs"] as? Double != nil)
        for key in ["firstAcknowledgedWriteMs", "motionEndedMs", "motionWritesAcknowledged",
                    "motionWritesUnacknowledged", "motionWritesFailed"] {
            #expect(first[key] is NSNull, "\(key)")
        }
        #expect((spaces?["stalls"] as? [[String: Any]])?.first?["changeStep"] is NSNull)
    }

    private func usage(cpuMilliseconds: UInt64, idleWakeups: UInt64, interruptWakeups: UInt64) -> ResourceSampler.Usage {
        ResourceSampler.Usage(footprintBytes: 1, cpuNanoseconds: cpuMilliseconds * 1_000_000, idleWakeups: idleWakeups,
                              interruptWakeups: interruptWakeups, threads: 4, uptime: 0)
    }

    @Test func aPhaseCostsTheCPUAndWakeupsBetweenItsMarks() throws {
        let start = BenchmarkRecord.ResourceMark(uptime: 100,
                                                 usage: usage(cpuMilliseconds: 1_000, idleWakeups: 50, interruptWakeups: 400))
        let end = BenchmarkRecord.ResourceMark(uptime: 102,
                                               usage: usage(cpuMilliseconds: 1_150, idleWakeups: 90, interruptWakeups: 700))
        let cost = BenchmarkRecord.ResourceCost(from: start, to: end)

        #expect(cost.durationMs == 2_000)
        #expect(cost.cpuMs == 150)
        #expect(cost.cpuPercent == 7.5)
        #expect(cost.idleWakeupsPerSecond == 20)
        #expect(cost.interruptWakeupsPerSecond == 150)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cost)) as? [String: Any]
        #expect(json?["available"] as? Bool == true)
        #expect(json?["interruptWakeups"] as? Int == 300)
    }

    /// A failed kernel read is unavailable, never a zero cost.
    @Test func aPhaseWhoseUsageCouldNotBeReadIsUnavailableNotFree() throws {
        let start = BenchmarkRecord.ResourceMark(uptime: 100, usage: nil)
        let end = BenchmarkRecord.ResourceMark(uptime: 110,
                                               usage: usage(cpuMilliseconds: 1, idleWakeups: 1, interruptWakeups: 1))
        var record = BenchmarkRecord()
        record.phases.idle = .init(seconds: 10, resourceCost: .init(from: start, to: end))

        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        let idle = try #require((json?["phases"] as? [String: Any])?["idle"] as? [String: Any])
        let cost = try #require(idle["resourceCost"] as? [String: Any])
        #expect(idle["latencyMonitorStopped"] as? Bool == true)
        #expect(cost["available"] as? Bool == false)
        #expect(cost["durationMs"] as? Double == 10_000)
        for key in ["cpuMs", "cpuPercent", "idleWakeups", "idleWakeupsPerSecond", "interruptWakeups",
                    "interruptWakeupsPerSecond"] {
            #expect(cost[key] is NSNull, "\(key)")
        }
        #expect(StagehandModel.costSummary(record.phases.idle!.resourceCost).hasPrefix("unavailable"))
    }

    /// The runner's checkout can differ from the binary that ran, so raw samples name the binary.
    @Test func rawSamplesNameTheBuildThatRan() throws {
        var record = BenchmarkRecord()
        record.build = BuildIdentity(version: "ae0cfcd-dirty", buildNumber: "812",
                                     executableModified: "2026-11-13T01:00:00Z")

        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        let build = json?["build"] as? [String: String]

        #expect(build == ["version": "ae0cfcd-dirty", "buildNumber": "812",
                          "executableModified": "2026-11-13T01:00:00Z"])
        #expect(json?["schema"] as? Int == 1)
    }
}
