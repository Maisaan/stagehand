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
    }

    struct Phases: Encodable {
        var start: Start?
        var sequential: SwitchPhase?
        var rapid: Rapid?
        var panes: SwitchPhase?
        var spaces: SwitchPhase?
        var interface: Interface?
        var pause: Pause?
    }

    struct Start: Encodable {
        var callMs: Double
        var settledMs: Double
        var timedOut: Bool
        var mainThreadWaitsMs: [Double]
    }

    struct SwitchPhase: Encodable {
        var switches: [Switch] = []
        var mainThreadWaitsMs: [Double] = []
        var stalls: [Stall] = []
        var finalFocusMatches: Bool?
        var finalFocusMismatch: String?
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

        private enum CodingKeys: String, CodingKey { case waitedMs, label, phase, changeStep }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(waitedMs, forKey: .waitedMs)
            try container.encode(label, forKey: .label)
            try container.encode(phase, forKey: .phase)
            try container.encode(changeStep, forKey: .changeStep)
        }
    }

    struct Rapid: Encodable {
        var settledMs: Double
        var timedOut: Bool
        var mainThreadWaitsMs: [Double]
        var finalFocusMatches: Bool
    }

    struct Interface: Encodable {
        var appBarShowMs: [Double]
        var settingsOpenMs: [Double]
        var quickControlsOpenMs: [Double]
    }

    struct Pause: Encodable {
        var callMs: Double
    }

    private enum CodingKeys: String, CodingKey {
        case schema, result, failures, ownerInput, build, environment, settings, phases
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
