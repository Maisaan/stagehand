import AppKit
import Foundation
import QuartzCore
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

    /// The same split analyze-log.py makes of logged stalls (its StallKindTests use these numbers).
    @Test func stallsSplitByTheMainThreadsOwnCPUAndTheLoad() {
        let thresholds = BenchmarkRecord.StallKind.Thresholds(starvedAtLoad: 10)
        func kind(_ cpu: Double?, _ load: Double?) -> BenchmarkRecord.StallKind? {
            BenchmarkRecord.StallKind.classify(waitedMs: 200, mainThreadCPUMs: cpu, loadAverage: load, thresholds: thresholds)
        }
        #expect(kind(150, 3) == .computing)
        #expect(kind(5, 167) == .starved)
        #expect(kind(5, 2) == .waiting)
        #expect(kind(60, 167) == .waiting)
        #expect(kind(5, nil) == .waiting)
        #expect(kind(nil, 167) == nil)
    }

    @Test func aStallIsSavedWithItsCPULoadAndKindAndTheThresholds() throws {
        let recorder = BenchmarkSwitchRecorder()
        recorder.observe("ribbon_animation_started")
        let posted = CACurrentMediaTime()
        var unknown = MainThreadLatencyMonitor.Wait(postedUptime: posted, milliseconds: 90, label: "unlabeled")
        unknown.loadAverage = 4
        let waits = [
            MainThreadLatencyMonitor.Wait(postedUptime: posted, milliseconds: 120,
                                          label: "layout readback after focus > read AXPosition,AXSize pid=42",
                                          mainThreadCPUMilliseconds: 1, loadAverage: 2),
            MainThreadLatencyMonitor.Wait(postedUptime: posted, milliseconds: 10, label: "unlabeled"),
            unknown
        ]
        var record = BenchmarkRecord()
        record.stallKindThresholds = .init(starvedAtLoad: 8)
        record.phases.rapid = .init(settledMs: 1, timedOut: false, mainThreadWaitsMs: waits.map(\.milliseconds),
                                    stalls: StagehandModel.stalls(in: waits, recorder: recorder,
                                                                  thresholds: .init(starvedAtLoad: 8)),
                                    finalFocusMatches: true)

        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        let rapid = (json?["phases"] as? [String: Any])?["rapid"] as? [String: Any]
        let stalls = try #require(rapid?["stalls"] as? [[String: Any]])
        #expect(stalls.count == 2)
        #expect(stalls[0]["label"] as? String == "layout readback after focus > read AXPosition,AXSize")
        #expect(stalls[0]["phase"] as? String == "ribbon_animation_started")
        #expect(stalls[0]["mainThreadCPUMs"] as? Double == 1)
        #expect(stalls[0]["kind"] as? String == "waiting")
        #expect(stalls[1]["mainThreadCPUMs"] is NSNull)
        #expect(stalls[1]["kind"] is NSNull)
        let thresholds = json?["stallKindThresholds"] as? [String: Double]
        #expect(thresholds == ["computingCPUFraction": 0.5, "starvedCPUFraction": 0.1, "starvedAtLoad": 8])
        #expect(StagehandModel.stallAttributionLines(record.phases.rapid!.stalls).first
            == "  stalls by kind: waiting 120 ms (1), unknown 90 ms (1); load 2.0-4.0")
    }

    /// The benchmark's monitor reads the main thread's CPU for a stall, as the watchdog does.
    @Test func theLatencyMonitorRecordsTheMainThreadsCPUDuringAStall() async throws {
        let monitor = MainThreadLatencyMonitor()
        monitor.start()
        try await Task.sleep(for: .milliseconds(20))
        let spinUntil = CACurrentMediaTime() + 0.12
        var spins = 0.0
        while CACurrentMediaTime() < spinUntil { spins += 1 }
        try await Task.sleep(for: .milliseconds(30))
        let waits = monitor.stop()

        #expect(spins > 0)
        let stall = try #require(waits.max { $0.milliseconds < $1.milliseconds })
        #expect(stall.milliseconds > MainThreadLatencyMonitor.stallMilliseconds)
        #expect(stall.mainThreadCPUMilliseconds != nil)
        #expect(stall.loadAverage != nil)
        #expect(waits.filter { $0.milliseconds <= MainThreadLatencyMonitor.stallMilliseconds }
            .allSatisfy { $0.mainThreadCPUMilliseconds == nil })
    }

    /// The default workspace stays 2+1+1; a larger one keeps every probe app busy.
    @Test func probeWindowsAreSpreadOverTheProbeApps() throws {
        #expect(StagehandModel.probeWindows(total: StagehandModel.defaultProbeWindowCount) == [2, 1, 1])
        #expect(StagehandModel.probeWindows(total: 12) == [4, 4, 4])
        #expect(StagehandModel.probeWindows(total: 13) == [5, 4, 4])
        #expect(StagehandModel.probeWindows(total: 2) == nil)

        var record = BenchmarkRecord()
        record.settings = .init(gap: 8, widthPresets: [0.5], loggingEnabled: true, busyProbes: true,
                                measuresStacking: false, tiles: false, switches: 24, gestures: false,
                                probeWindows: [4, 4, 4])
        let json = try JSONSerialization.jsonObject(with: record.jsonData()) as? [String: Any]
        #expect((json?["settings"] as? [String: Any])?["probeWindows"] as? [Int] == [4, 4, 4])
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

/// The `--gestures` scenarios: model-path swipes with planned stimulus times.
@MainActor
@Suite(.serialized)
struct BenchmarkGestureTests {
    @Test func scenariosFlickSlowDragAndReturnToTheirStart() {
        let configuration = RibbonAnimationConfiguration.default
        for scenario in StagehandModel.GestureScenario.all {
            let events = scenario.events(towardNext: true, action: .focusNext)
            #expect(events.count == scenario.schedule.count)
            #expect(zip(events.dropFirst(), events).allSatisfy { $0.milliseconds - $1.milliseconds == 8 })
            guard case .began(.horizontal, let first, .plain) = events.first?.event,
                  case .ended(let last, let velocity, _, .plain) = events.last?.event else {
                Issue.record("\(scenario.name) does not begin and end as a swipe")
                continue
            }
            #expect(first < 0, "toward the next window is a negative displacement")
            switch scenario.name {
            case "flick":
                #expect(-velocity >= configuration.flickVelocity && -last >= configuration.flickDistance)
                #expect(events.last!.milliseconds == 56)
            case "slowDrag":
                #expect(-velocity < configuration.flickVelocity)
            default:
                #expect(last == 0)
                #expect(velocity > 0, "released moving back")
            }
        }
        guard case .began(_, let displacement, _) = StagehandModel.GestureScenario.flick
            .events(towardNext: false, action: .focusPrevious).first?.event else { return }
        #expect(displacement > 0)
    }

    private func follow(_ handoff: GestureFollowEnded.Handoff) -> BenchmarkRecord.Follow {
        BenchmarkRecord.Follow(GestureFollowEnded(
            gestureID: 7, summary: RibbonFollowSummary(started: 1, ended: 1.2, ticks: 12, droppedTicks: 0,
                                                       largestTargetGap: 0.017, largestCallbackGap: 0.02,
                                                       lateCallbacks: 0, handedToAnimation: false),
            touchesLanded: 0.99, writes: MotionWriteSummary(), handoff: handoff))
    }

    /// A follow cut by another change (a refresh mid-swipe) is not the swipe's own commit.
    @Test func aGestureIsJudgedByWhatEndedItsFollowAndWhatItsReleaseQueued() {
        typealias Gesture = BenchmarkRecord.Gesture
        #expect(Gesture.outcome(changeID: 5, follow: follow(.change(id: 5))) == .commit)
        #expect(Gesture.outcome(changeID: 5, follow: follow(.settle(operation: "action.focusNext", changeID: 5)))
            == .commit)
        #expect(Gesture.outcome(changeID: nil, follow: follow(.settle(operation: "gesture.preview.restore",
                                                                       changeID: nil))) == .restore)
        #expect(Gesture.outcome(changeID: nil, follow: follow(.change(id: 4))) == .interrupted)
        #expect(Gesture.outcome(changeID: 6, follow: follow(.change(id: 4))) == .interrupted)
        #expect(Gesture.outcome(changeID: nil, follow: follow(.cancelled)) == .none)
        #expect(Gesture.outcome(changeID: nil, follow: nil) == .none)

        var cut = Gesture(scenario: "slowDrag", expected: .commit)
        cut.follow = follow(.change(id: 4))
        cut.outcome = .interrupted
        #expect(BenchmarkRecord.gestureFailures(.init(gestures: [cut]))
            == ["gestures: slowDrag (gesture 1): change 4 cut its follow before the release"])
        #expect(abs((cut.follow?.startedAfterTouchMs ?? 0) - 10) < 1e-9)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns off the preview"))
    func theGesturePhaseCommitsFlicksAndDragsAndRestoresAReversal() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d"], focused: "a", motionDriver: RunningFrameDriver())
        defer { harness.cleanUp() }
        // As a real scan does; the fake's own reports the frames it was created with.
        harness.windows.scansReportLiveFrames = true
        harness.model.start()
        await harness.settle()
        harness.model.diagnostics.isEnabled = false

        let phase = await harness.model.measureGesturePhase(repetitions: 1, busy: false, monitor: MainThreadLatencyMonitor(),
                                                            frameInterval: 1.0 / 60, stallKinds: .init())

        #expect(phase.gestures.map(\.scenario) == ["flick", "slowDrag", "reversal"])
        #expect(phase.gestures.map(\.outcome) == [.commit, .commit, .restore])
        #expect(BenchmarkRecord.gestureFailures(phase) == [])
        #expect(harness.model.gestureFollowSink == nil && harness.model.changeTraceSink == nil)
        for gesture in phase.gestures {
            let schedule = StagehandModel.GestureScenario.all.first { $0.name == gesture.scenario }!.schedule
            #expect(gesture.plannedStimulusMs == schedule.map(\.milliseconds))
            #expect(gesture.actualStimulusMs.count == schedule.count)
            #expect(zip(gesture.actualStimulusMs, gesture.plannedStimulusMs).allSatisfy { $0 >= $1 - 1 })
            let follow = try #require(gesture.follow)
            #expect(follow.ticks > 0)
            #expect(follow.startedAfterTouchMs != nil)
            #expect(gesture.release.timedOut == false)
        }
        #expect(phase.gestures[2].follow?.settleOperation == "gesture.preview.restore")
        #expect(phase.gestures[0].release.changeOutcome == "completed")
        #expect(phase.gestures[0].release.focusMs != nil)
        #expect(phase.gestures[2].release.changeOutcome == nil)
        #expect(phase.resourceCost != nil)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(phase)) as? [String: Any]
        #expect(json?["coverage"] as? String == "modelPath")
        let first = try #require((json?["gestures"] as? [[String: Any]])?.first)
        #expect(first["outcomeMatches"] as? Bool == true)
        #expect(first["largestStimulusLagMs"] is Double)
        #expect((first["follow"] as? [String: Any])?["handoff"] != nil)
    }
}
