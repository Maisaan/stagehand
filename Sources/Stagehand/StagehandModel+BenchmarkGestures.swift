import AppKit
import QuartzCore
import StagehandCore
import StagehandPlatform

/// `--gestures`: swipes replayed through the model's gesture handler on fixed displacement
/// schedules, so the production follow and settle run. The trackpad driver, the recognizer
/// and delivery to main are not exercised: this is model-path coverage.
extension StagehandModel {
    struct GestureScenario {
        let name: String
        let expected: BenchmarkRecord.Gesture.Outcome
        /// Displacement toward the destination, in trackpad widths, at each stimulus time (ms from the start).
        let schedule: [(milliseconds: Double, displacement: Double)]

        /// A trackpad reports about every 8 ms.
        static let stimulusInterval = 8.0

        /// A real swipe's follow lasted p50 55 ms: fast enough to commit as a flick.
        static let flick = GestureScenario(name: "flick", expected: .commit, schedule: sampled(until: 56) {
            0.02 + 0.05 * $0 / 56
        })
        /// Too slow to flick; commits on distance.
        static let slowDrag = GestureScenario(name: "slowDrag", expected: .commit, schedule: sampled(until: 600) {
            0.01 + 0.11 * $0 / 600
        })
        /// Out and back to where it started, released moving back: the preview is restored.
        static let reversal = GestureScenario(name: "reversal", expected: .restore, schedule: sampled(until: 400) {
            $0 <= 200 ? 0.02 + 0.06 * $0 / 200 : 0.08 * (400 - $0) / 200
        })
        static let all = [flick, slowDrag, reversal]

        private static func sampled(until end: Double,
                                    _ displacement: (Double) -> Double) -> [(milliseconds: Double, displacement: Double)] {
            stride(from: 0, through: end, by: stimulusInterval).map { ($0, displacement($0)) }
        }

        /// The handler's events, signed for the direction: a negative displacement goes to the next window.
        func events(towardNext: Bool, action: NavigationAction?) -> [(milliseconds: Double, event: GestureNavigationEvent)] {
            let sign = towardNext ? -1.0 : 1.0
            return schedule.enumerated().map { index, step in
                let displacement = sign * step.displacement
                let velocity = index == 0 ? 0 : sign * (step.displacement - schedule[index - 1].displacement)
                    / ((step.milliseconds - schedule[index - 1].milliseconds) / 1_000)
                let event: GestureNavigationEvent = switch index {
                case 0: .began(axis: .horizontal, displacement: displacement, mode: .plain)
                case schedule.count - 1:
                    .ended(displacement: displacement, velocity: velocity, action: action, mode: .plain)
                default: .changed(displacement: displacement, velocity: velocity)
                }
                return (step.milliseconds, event)
            }
        }
    }

    static let gestureRepetitions = 4
    /// Room between scheduling a gesture and its first stimulus.
    private static let gestureLeadTime: TimeInterval = 0.005

    func measureGesturePhase(repetitions: Int = gestureRepetitions, busy: Bool, monitor: MainThreadLatencyMonitor,
                             frameInterval: Double,
                             stallKinds: BenchmarkRecord.StallKind.Thresholds) async -> BenchmarkRecord.GesturePhase {
        let recorder = BenchmarkSwitchRecorder()
        var follows: [GestureFollowEnded] = []
        diagnostics.eventObserver = { recorder.observe($0) }
        changeTraceSink = { recorder.observe($0) }
        gestureFollowSink = { follows.append($0) }
        ribbonMotion.onFrameTiming = { recorder.frame(at: $0, work: $1, interval: frameInterval) }
        defer {
            diagnostics.eventObserver = nil
            changeTraceSink = nil
            gestureFollowSink = nil
            ribbonMotion.onFrameTiming = nil
        }
        var phase = BenchmarkRecord.GesturePhase()
        var towardNext = true
        monitor.start()
        let costBegan = BenchmarkRecord.ResourceMark.now()
        for _ in 0..<repetitions {
            for scenario in GestureScenario.all {
                _ = await benchmarkWaitUntilIdle()
                var predicted = state
                if !predicted.apply(towardNext ? .focusNext : .focusPrevious) { towardNext.toggle() }
                let action: NavigationAction = towardNext ? .focusNext : .focusPrevious
                var gesture = await replayGesture(scenario, towardNext: towardNext, action: action, recorder: recorder)
                gesture.follow = follows.last { $0.gestureID == gesture.gestureID }.map(BenchmarkRecord.Follow.init)
                gesture.outcome = BenchmarkRecord.Gesture.outcome(changeID: gesture.changeID, follow: gesture.follow)
                phase.gestures.append(gesture)
                try? await Task.sleep(for: .milliseconds(busy ? 300 : 150))
            }
        }
        let waits = monitor.stop()
        phase.resourceCost = BenchmarkRecord.ResourceCost(from: costBegan, to: .now())
        phase.mainThreadWaitsMs = waits.map(\.milliseconds)
        phase.stalls = Self.stalls(in: waits, recorder: recorder, thresholds: stallKinds)
        return phase
    }

    /// Delivers each stimulus at its planned time, as the trackpad path would (`InputArrival`
    /// from the planned time, so input-to-main is the replay's own lag), then times the release.
    private func replayGesture(_ scenario: GestureScenario, towardNext: Bool, action: NavigationAction,
                               recorder: BenchmarkSwitchRecorder) async -> BenchmarkRecord.Gesture {
        var gesture = BenchmarkRecord.Gesture(scenario: scenario.name, expected: scenario.expected)
        let events = scenario.events(towardNext: towardNext, action: scenario.expected == .commit ? action : nil)
        let touchesLanded = ProcessInfo.processInfo.systemUptime + Self.gestureLeadTime
        var releaseBegan = CACurrentMediaTime()
        var committedChangeID: Int?
        for (index, stimulus) in events.enumerated() {
            let due = touchesLanded + stimulus.milliseconds / 1_000
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            let isRelease = index == events.count - 1
            let changesBefore = lastChangeID
            if isRelease {
                releaseBegan = CACurrentMediaTime()
                recorder.begin(at: releaseBegan)
            }
            let delivered = ProcessInfo.processInfo.systemUptime
            let arrival = InputArrival(source: .trackpad, eventUptime: due, receivedUptime: due,
                                       touchesLandedUptime: touchesLanded)
            InputArrival.delivering(arrival) { handleGesture(stimulus.event) }
            if index == 0 { gesture.gestureID = lastGestureID }
            if isRelease, lastChangeID > changesBefore { committedChangeID = lastChangeID }
            gesture.plannedStimulusMs.append(stimulus.milliseconds)
            gesture.actualStimulusMs.append((delivered - touchesLanded) * 1_000)
        }
        recorder.expectChange(committedChangeID)
        gesture.changeID = committedChangeID
        let idle = await benchmarkWaitUntilIdle()
        var release = recorder.finish()
        release.settledMs = (CACurrentMediaTime() - releaseBegan) * 1_000
        release.timedOut = !idle
        if release.slid {
            let motion = windowSystem.motionWriteStatistics(reset: false, focusedWindowID: state.focusedWindowID)
            release.focusedGapMs = motion["focusedMotionGapMilliseconds"].flatMap(Double.init)
            release.largestGapMs = motion["largestMotionGapMilliseconds"].flatMap(Double.init)
        }
        gesture.release = release
        return gesture
    }

    static func gesturePhaseLines(_ phase: BenchmarkRecord.GesturePhase) -> [String] {
        var lines: [String] = []
        for scenario in GestureScenario.all {
            let gestures = phase.gestures.filter { $0.scenario == scenario.name }
            guard !gestures.isEmpty else { continue }
            let follows = gestures.compactMap(\.follow)
            let releases = gestures.map(\.release)
            let matched = gestures.count { $0.outcome == $0.expected }
            lines.append("  \(scenario.name): \(matched) of \(gestures.count) ended \(scenario.expected.rawValue) as expected"
                + String(format: "; stimulus lag max %.0f ms", gestures.map(\.largestStimulusLagMs).max() ?? 0))
            lines.append("    follow: touch to start " + percentiles(follows.compactMap(\.startedAfterTouchMs))
                + "; to first acknowledged write " + percentiles(follows.compactMap(\.firstAcknowledgedWriteAfterTouchMs))
                + "; longest callback gap " + percentiles(follows.compactMap(\.largestCallbackGapMs))
                + "; dropped ticks \(follows.compactMap(\.droppedTicks).reduce(0, +))"
                + ", no follow \(gestures.count - follows.count)")
            lines.append("    release: to motion scheduled " + percentiles(releases.compactMap(\.motionScheduledMs))
                + "; to focus confirmed " + percentiles(releases.compactMap(\.focusMs))
                + "; to settled " + percentiles(releases.map(\.settledMs))
                + "; longest freeze of the destination " + percentiles(releases.compactMap(\.focusedGapMs)))
        }
        lines.append("  main thread: " + stallSummary(phase.mainThreadWaitsMs))
        lines += stallAttributionLines(phase.stalls)
        if let cost = phase.resourceCost { lines.append("  cost: " + costSummary(cost)) }
        return lines
    }
}
