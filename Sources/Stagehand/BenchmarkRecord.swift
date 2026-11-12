import Foundation
import StagehandPlatform

/// The raw samples of one `--benchmark` run, written as JSON with `--raw-output`.
/// A phase that did not run stays nil and is left out of the JSON.
struct BenchmarkRecord: Encodable {
    static let schema = 1

    var failures: [String] = []
    var ownerInput: String?
    var build: BuildIdentity?
    var environment: Environment?
    var settings: Settings?
    var stallKindThresholds: StallKind.Thresholds?
    var phases = Phases()

    var passed: Bool { failures.isEmpty }

    mutating func noteOwnerInput(_ reading: OwnerInputReading) {
        ownerInput = reading.summary
        if reading.touched { failures.append("owner input during run: \(reading.summary)") }
    }

    struct Environment: Encodable {
        var displayWidthPoints: Double
        var displayHeightPoints: Double
        var backingScale: Double
        var maximumFramesPerSecond: Int
        var ribbonFramesPerSecond: Double
        var reduceMotion: Bool
    }

    struct Settings: Encodable {
        var gap: Double
        var widthPresets: [Double]
        var loggingEnabled: Bool
        var busyProbes: Bool
        var measuresStacking: Bool
        var tiles: Bool
        var switches: Int
        var gestures: Bool
    }

    struct Phases: Encodable {
        var start: Start?
        var sequential: SwitchPhase?
        var rapid: Rapid?
        var gestures: GesturePhase?
        var panes: SwitchPhase?
        var spaces: SwitchPhase?
        var interface: Interface?
        var idle: Idle?
        var pause: Pause?
    }

    /// The whole process's CPU time and wakeups over one phase, read from the kernel at its
    /// start and end, logged or not. Nil counts mean a read failed: unavailable, not zero.
    struct ResourceCost: Encodable, Equatable {
        var durationMs: Double
        var cpuMs: Double?
        var idleWakeups: Int?
        var interruptWakeups: Int?

        init(from start: ResourceMark, to end: ResourceMark) {
            durationMs = (end.uptime - start.uptime) * 1_000
            guard let before = start.usage, let after = end.usage else { return }
            cpuMs = Double(after.cpuNanoseconds &- before.cpuNanoseconds) / 1e6
            idleWakeups = Int(after.idleWakeups &- before.idleWakeups)
            interruptWakeups = Int(after.interruptWakeups &- before.interruptWakeups)
        }

        var available: Bool { cpuMs != nil }
        var cpuPercent: Double? { cpuMs.flatMap { durationMs > 0 ? $0 / durationMs * 100 : nil } }
        var idleWakeupsPerSecond: Double? { idleWakeups.flatMap(perSecond) }
        var interruptWakeupsPerSecond: Double? { interruptWakeups.flatMap(perSecond) }

        private func perSecond(_ count: Int) -> Double? {
            durationMs > 0 ? Double(count) / durationMs * 1_000 : nil
        }

        private enum CodingKeys: String, CodingKey {
            case available, durationMs, cpuMs, cpuPercent, idleWakeups, idleWakeupsPerSecond,
                 interruptWakeups, interruptWakeupsPerSecond
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(cpuMs, forKey: .cpuMs)
            try container.encode(cpuPercent, forKey: .cpuPercent)
            try container.encode(idleWakeups, forKey: .idleWakeups)
            try container.encode(idleWakeupsPerSecond, forKey: .idleWakeupsPerSecond)
            try container.encode(interruptWakeups, forKey: .interruptWakeups)
            try container.encode(interruptWakeupsPerSecond, forKey: .interruptWakeupsPerSecond)
        }
    }

    /// A point to measure a phase's resource cost from: when, and the process's usage then.
    struct ResourceMark {
        let uptime: TimeInterval
        let usage: ResourceSampler.Usage?

        static func now(read: () -> ResourceSampler.Usage? = ResourceSampler.currentUsage) -> ResourceMark {
            ResourceMark(uptime: ProcessInfo.processInfo.systemUptime, usage: read())
        }
    }

    /// Stagehand left alone: no switches and the benchmark's own latency monitor stopped,
    /// so its cost is Stagehand's idle cost (with logging on, the watchdog's and sampler's too).
    struct Idle: Encodable {
        var seconds: Double
        let latencyMonitorStopped = true
        var resourceCost: ResourceCost

        private enum CodingKeys: String, CodingKey { case seconds, latencyMonitorStopped, resourceCost }
    }

    struct Start: Encodable {
        var callMs: Double
        var settledMs: Double
        var timedOut: Bool
        var mainThreadWaitsMs: [Double]
        var stalls: [Stall] = []
        var resourceCost: ResourceCost?
    }

    struct SwitchPhase: Encodable {
        var switches: [Switch] = []
        var mainThreadWaitsMs: [Double] = []
        var stalls: [Stall] = []
        var finalFocusMatches: Bool?
        var finalFocusMismatch: String?
        var resourceCost: ResourceCost?
    }

    struct Switch: Encodable {
        var motionScheduledMs: Double?
        var focusMs: Double?
        var focusRejected = false
        var settledMs = 0.0
        var timedOut = false
        var frameWorkMs: [Double] = []
        var droppedFrames = 0
        var focusedGapMs: Double?
        var largestGapMs: Double?
        var frontmostMs: Double?
        var reordersAfterFrontmost: Int?
        /// From the change's trace, measured from when it was queued; logged or not.
        var changeOutcome: String?
        var queueWaitMs: Double?
        var firstAcknowledgedWriteMs: Double?
        var motionEndedMs: Double?
        var motionWritesAcknowledged: Int?
        var motionWritesUnacknowledged: Int?
        var motionWritesFailed: Int?

        var slid: Bool { motionScheduledMs != nil }
        var focusAttempted: Bool { focusMs != nil || focusRejected }

        private enum CodingKeys: String, CodingKey {
            case slid, motionScheduledMs, focusMs, focusRejected, settledMs, timedOut, frameWorkMs,
                 droppedFrames, focusedGapMs, largestGapMs, frontmostMs, reordersAfterFrontmost,
                 changeOutcome, queueWaitMs, firstAcknowledgedWriteMs, motionEndedMs,
                 motionWritesAcknowledged, motionWritesUnacknowledged, motionWritesFailed
        }

        // Nil is written as null so a switch without motion or focus stays visible as one.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(slid, forKey: .slid)
            try container.encode(motionScheduledMs, forKey: .motionScheduledMs)
            try container.encode(focusMs, forKey: .focusMs)
            try container.encode(focusRejected, forKey: .focusRejected)
            try container.encode(settledMs, forKey: .settledMs)
            try container.encode(timedOut, forKey: .timedOut)
            try container.encode(frameWorkMs, forKey: .frameWorkMs)
            try container.encode(droppedFrames, forKey: .droppedFrames)
            try container.encode(focusedGapMs, forKey: .focusedGapMs)
            try container.encode(largestGapMs, forKey: .largestGapMs)
            try container.encodeIfPresent(frontmostMs, forKey: .frontmostMs)
            try container.encodeIfPresent(reordersAfterFrontmost, forKey: .reordersAfterFrontmost)
            try container.encode(changeOutcome, forKey: .changeOutcome)
            try container.encode(queueWaitMs, forKey: .queueWaitMs)
            try container.encode(firstAcknowledgedWriteMs, forKey: .firstAcknowledgedWriteMs)
            try container.encode(motionEndedMs, forKey: .motionEndedMs)
            try container.encode(motionWritesAcknowledged, forKey: .motionWritesAcknowledged)
            try container.encode(motionWritesUnacknowledged, forKey: .motionWritesUnacknowledged)
            try container.encode(motionWritesFailed, forKey: .motionWritesFailed)
        }

        mutating func note(_ ended: EndedChangeTrace) {
            let trace = ended.trace
            func sinceQueued(_ uptime: TimeInterval?) -> Double? { uptime.map { ($0 - trace.queued) * 1_000 } }
            changeOutcome = ended.outcome
            queueWaitMs = sinceQueued(trace.started)
            firstAcknowledgedWriteMs = sinceQueued(trace.firstAcknowledgedWrite)
            motionEndedMs = sinceQueued(trace.motionEnded)
            motionWritesAcknowledged = trace.motionWrites?.acknowledged
            motionWritesUnacknowledged = trace.motionWrites?.unacknowledged
            motionWritesFailed = trace.motionWrites?.failed
        }
    }

    struct Stall: Encodable {
        var waitedMs: Double
        var label: String
        /// The last diagnostic event before the stall; events recorded only with logging on are missing without it.
        var phase: String
        /// The last step of the change running then, from its trace, logged or not; nil outside any change.
        var changeStep: String?
        /// The main thread's own CPU during the wait; nil when the kernel did not answer.
        var mainThreadCPUMs: Double?
        var loadAverage: Double?
        /// Nil without the main thread's CPU.
        var kind: StallKind?

        private enum CodingKeys: String, CodingKey {
            case waitedMs, label, phase, changeStep, mainThreadCPUMs, loadAverage, kind
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(waitedMs, forKey: .waitedMs)
            try container.encode(label, forKey: .label)
            try container.encode(phase, forKey: .phase)
            try container.encode(changeStep, forKey: .changeStep)
            try container.encode(mainThreadCPUMs, forKey: .mainThreadCPUMs)
            try container.encode(loadAverage, forKey: .loadAverage)
            try container.encode(kind, forKey: .kind)
        }
    }

    /// What the main thread did during a stall, by its own CPU time, as analyze-log.py splits logged stalls.
    enum StallKind: String, Encodable {
        /// CPU for at least half the wait: Stagehand's own work.
        case computing
        /// Less: most likely an Accessibility reply from another app.
        case waiting
        /// CPU under a tenth of the wait at a 1-minute load of at least the CPU count: waiting for a CPU.
        case starved

        struct Thresholds: Encodable {
            var computingCPUFraction = 0.5
            var starvedCPUFraction = 0.1
            var starvedAtLoad = Double(ProcessInfo.processInfo.activeProcessorCount)
        }

        static func classify(waitedMs: Double, mainThreadCPUMs: Double?, loadAverage: Double?,
                             thresholds: Thresholds = Thresholds()) -> StallKind? {
            guard let cpu = mainThreadCPUMs else { return nil }
            if cpu >= waitedMs * thresholds.computingCPUFraction { return .computing }
            if cpu < waitedMs * thresholds.starvedCPUFraction, let loadAverage,
               loadAverage >= thresholds.starvedAtLoad { return .starved }
            return .waiting
        }
    }

    struct Rapid: Encodable {
        var settledMs: Double
        var timedOut: Bool
        var mainThreadWaitsMs: [Double]
        var stalls: [Stall] = []
        var finalFocusMatches: Bool
        var resourceCost: ResourceCost?
    }

    /// Synthetic swipes: fixed displacement schedules through the model's gesture handler, so the
    /// production follow and settle run. Not trackpad recognition or delivery.
    struct GesturePhase: Encodable {
        let coverage = "modelPath"
        var gestures: [Gesture] = []
        var mainThreadWaitsMs: [Double] = []
        var stalls: [Stall] = []
        var resourceCost: ResourceCost?

        private enum CodingKeys: String, CodingKey { case coverage, gestures, mainThreadWaitsMs, stalls, resourceCost }
    }

    struct Gesture: Encodable {
        enum Outcome: String, Encodable {
            /// The release queued the swipe's change.
            case commit
            /// The follow was handed to `gesture.preview.restore`.
            case restore
            /// A change that was not the swipe's own cut its follow.
            case interrupted
            case none
        }

        var scenario: String
        var expected: Outcome
        var outcome: Outcome = .none
        var gestureID: Int?
        /// The change the release queued; nil when it queued none.
        var changeID: Int?
        /// Stimulus times from the gesture's planned start; actual is when main ran the handler.
        var plannedStimulusMs: [Double] = []
        var actualStimulusMs: [Double] = []
        /// Nil when no live follow ran.
        var follow: Follow?
        /// From the release, measured as a switch is.
        var release = Switch()

        var largestStimulusLagMs: Double { zip(actualStimulusMs, plannedStimulusMs).map { $0 - $1 }.max() ?? 0 }

        private enum CodingKeys: String, CodingKey {
            case scenario, expected, outcome, outcomeMatches, gestureID, changeID, plannedStimulusMs,
                 actualStimulusMs, largestStimulusLagMs, follow, release
        }

        /// From what ended the follow and what the release queued.
        static func outcome(changeID: Int?, follow: Follow?) -> Outcome {
            if let follow, follow.handoff == "change", follow.handoffChangeID != changeID { return .interrupted }
            if changeID != nil { return .commit }
            return follow?.settleOperation == "gesture.preview.restore" ? .restore : .none
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scenario, forKey: .scenario)
            try container.encode(expected, forKey: .expected)
            try container.encode(outcome, forKey: .outcome)
            try container.encode(outcome == expected, forKey: .outcomeMatches)
            try container.encode(gestureID, forKey: .gestureID)
            try container.encode(changeID, forKey: .changeID)
            try container.encode(plannedStimulusMs, forKey: .plannedStimulusMs)
            try container.encode(actualStimulusMs, forKey: .actualStimulusMs)
            try container.encode(largestStimulusLagMs, forKey: .largestStimulusLagMs)
            try container.encode(follow, forKey: .follow)
            try container.encode(release, forKey: .release)
        }
    }

    /// A gesture's live follow, from `gesture_follow_ended`'s numbers. Touch times are the stimulus's planned start.
    struct Follow: Encodable {
        var handoff: String
        var settleOperation: String?
        var handoffChangeID: Int?
        var durationMs: Double
        var ticks: Int
        var droppedTicks: Int?
        var largestTickGapMs: Double?
        var largestCallbackGapMs: Double?
        var lateCallbacks: Int
        var startedAfterTouchMs: Double?
        var firstAcknowledgedWriteAfterTouchMs: Double?
        var motionWritesSent: Int
        var motionWritesAcknowledged: Int
        var motionWritesUnacknowledged: Int
        var motionWritesFailed: Int

        init(_ ended: GestureFollowEnded) {
            func milliseconds(_ seconds: TimeInterval?) -> Double? { seconds.map { $0 * 1_000 } }
            switch ended.handoff {
            case .change(let id):
                handoff = "change"
                handoffChangeID = id
            case .settle(let operation, let changeID):
                handoff = "settle"
                settleOperation = operation
                handoffChangeID = changeID
            case .cancelled: handoff = "cancelled"
            }
            let summary = ended.summary
            durationMs = (summary.ended - summary.started) * 1_000
            ticks = summary.ticks
            droppedTicks = summary.droppedTicks
            largestTickGapMs = milliseconds(summary.largestTargetGap)
            largestCallbackGapMs = milliseconds(summary.largestCallbackGap)
            lateCallbacks = summary.lateCallbacks
            startedAfterTouchMs = milliseconds(ended.followStartedAfterTouch)
            firstAcknowledgedWriteAfterTouchMs = milliseconds(ended.firstAcknowledgedWriteAfterTouch)
            motionWritesSent = ended.writes.sent
            motionWritesAcknowledged = ended.writes.acknowledged
            motionWritesUnacknowledged = ended.writes.unacknowledged
            motionWritesFailed = ended.writes.failed
        }

        private enum CodingKeys: String, CodingKey {
            case handoff, settleOperation, handoffChangeID, durationMs, ticks, droppedTicks, largestTickGapMs, largestCallbackGapMs,
                 lateCallbacks, startedAfterTouchMs, firstAcknowledgedWriteAfterTouchMs, motionWritesSent,
                 motionWritesAcknowledged, motionWritesUnacknowledged, motionWritesFailed
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(handoff, forKey: .handoff)
            try container.encode(settleOperation, forKey: .settleOperation)
            try container.encode(handoffChangeID, forKey: .handoffChangeID)
            try container.encode(durationMs, forKey: .durationMs)
            try container.encode(ticks, forKey: .ticks)
            try container.encode(droppedTicks, forKey: .droppedTicks)
            try container.encode(largestTickGapMs, forKey: .largestTickGapMs)
            try container.encode(largestCallbackGapMs, forKey: .largestCallbackGapMs)
            try container.encode(lateCallbacks, forKey: .lateCallbacks)
            try container.encode(startedAfterTouchMs, forKey: .startedAfterTouchMs)
            try container.encode(firstAcknowledgedWriteAfterTouchMs, forKey: .firstAcknowledgedWriteAfterTouchMs)
            try container.encode(motionWritesSent, forKey: .motionWritesSent)
            try container.encode(motionWritesAcknowledged, forKey: .motionWritesAcknowledged)
            try container.encode(motionWritesUnacknowledged, forKey: .motionWritesUnacknowledged)
            try container.encode(motionWritesFailed, forKey: .motionWritesFailed)
        }
    }

    /// A gesture that did not do what its schedule should, had no live follow, or whose commit was not confirmed.
    static func gestureFailures(_ phase: GesturePhase) -> [String] {
        var failures: [String] = []
        for (index, gesture) in phase.gestures.enumerated() {
            let name = "gestures: \(gesture.scenario) (gesture \(index + 1))"
            if gesture.outcome == .interrupted {
                failures.append("\(name): change \(gesture.follow?.handoffChangeID.map(String.init) ?? "?")"
                    + " cut its follow before the release")
            } else if gesture.outcome != gesture.expected {
                failures.append("\(name) ended \(gesture.outcome.rawValue), expected \(gesture.expected.rawValue)")
            }
            if gesture.follow == nil { failures.append("\(name) had no live follow") }
            if gesture.release.timedOut { failures.append("\(name): idle wait timed out") }
            if gesture.release.focusRejected { failures.append("\(name): focus rejected") }
            if gesture.expected == .commit, gesture.outcome == .commit, !gesture.release.focusAttempted {
                failures.append("\(name): no focus attempt")
            }
        }
        return failures
    }

    struct Interface: Encodable {
        var appBarShowMs: [Double]
        var settingsOpenMs: [Double]
        var quickControlsOpenMs: [Double]
        var resourceCost: ResourceCost?
    }

    struct Pause: Encodable {
        var callMs: Double
        var resourceCost: ResourceCost?
    }

    private enum CodingKeys: String, CodingKey {
        case schema, result, failures, ownerInput, build, environment, settings, stallKindThresholds, phases
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(passed ? "pass" : "fail", forKey: .result)
        try container.encode(failures, forKey: .failures)
        try container.encodeIfPresent(ownerInput, forKey: .ownerInput)
        try container.encodeIfPresent(build, forKey: .build)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encodeIfPresent(settings, forKey: .settings)
        try container.encodeIfPresent(stallKindThresholds, forKey: .stallKindThresholds)
        try container.encode(phases, forKey: .phases)
    }

    /// Failures for switches that timed out, had focus rejected, or never attempted focus.
    static func switchFailures(_ phase: SwitchPhase, name: String) -> [String] {
        var failures: [String] = []
        for (index, timing) in phase.switches.enumerated() {
            if timing.timedOut { failures.append("\(name): idle wait timed out after switch \(index + 1)") }
            if timing.focusRejected { failures.append("\(name): focus rejected on switch \(index + 1)") }
            if !timing.focusAttempted { failures.append("\(name): no focus attempt on switch \(index + 1)") }
        }
        if phase.finalFocusMatches == false {
            failures.append("\(name): final focus does not match the ribbon"
                + (phase.finalFocusMismatch.map { ": \($0)" } ?? ""))
        }
        return failures
    }

    var resultLine: String {
        passed ? "Result: PASS" : "Result: FAIL: " + failures.joined(separator: "; ")
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
