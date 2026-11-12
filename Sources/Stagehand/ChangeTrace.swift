import Foundation
import StagehandPlatform

/// When each step of one change that a user can feel happened, on the system-uptime
/// clock (the log's `uptimeMs`). Filled with diagnostic logging on or off.
struct ChangeTrace: Equatable {
    var input: InputArrival?
    var queued: TimeInterval
    var started: TimeInterval?
    var motionScheduled: TimeInterval?
    /// The first motion write the destination window's app acknowledged.
    var firstAcknowledgedWrite: TimeInterval?
    var motionEnded: TimeInterval?
    var motionWrites: MotionWriteSummary?
    var focusRequested: TimeInterval?
    var focusConfirmed: TimeInterval?
    var heldInput: HeldInputRelease?
    var ended: TimeInterval?

    init(input: InputArrival?, queued: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.input = input
        self.queued = queued
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Fields for the change's terminal event. Every key is new to that event.
    var details: [String: String] {
        var details: [String: String] = [:]
        func stamp(_ key: String, _ uptime: TimeInterval?) {
            if let uptime { details[key] = Self.milliseconds(uptime) }
        }
        if let input {
            details["inputSource"] = input.source.rawValue
            stamp("inputEventUptimeMs", input.eventUptime)
            stamp("inputReceivedUptimeMs", input.receivedUptime)
            stamp("inputDeliveredUptimeMs", input.deliveredUptime)
            stamp("touchesLandedUptimeMs", input.touchesLandedUptime)
        }
        stamp("queuedUptimeMs", queued)
        stamp("startedUptimeMs", started)
        stamp("motionScheduledUptimeMs", motionScheduled)
        stamp("firstAcknowledgedWriteUptimeMs", firstAcknowledgedWrite)
        stamp("motionEndedUptimeMs", motionEnded)
        if let motionWrites {
            details["motionWritesAcknowledged"] = String(motionWrites.acknowledged)
            details["motionWritesUnacknowledged"] = String(motionWrites.unacknowledged)
            details["motionWritesFailed"] = String(motionWrites.failed)
        }
        stamp("focusRequestedUptimeMs", focusRequested)
        stamp("focusConfirmedUptimeMs", focusConfirmed)
        if let heldInput {
            details["heldInputEvents"] = String(heldInput.heldEvents)
            details["heldInputTransferAgeMs"] = Self.milliseconds(heldInput.transferAge)
            if let age = heldInput.oldestHeldEventAge { details["oldestHeldInputAgeMs"] = Self.milliseconds(age) }
            stamp("heldInputPostedUptimeMs", heldInput.postedUptime)
        }
        return details
    }

    /// The last step this change had reached at `uptime`, by time: work then belonged to it.
    func step(at uptime: TimeInterval) -> String {
        let steps: [(name: String, uptime: TimeInterval?)] = [
            ("queued", queued), ("started", started), ("motionScheduled", motionScheduled),
            ("motionEnded", motionEnded), ("focusRequested", focusRequested), ("focusConfirmed", focusConfirmed),
            ("heldInputPosted", heldInput?.postedUptime)
        ]
        return steps.compactMap { step in step.uptime.map { (step.name, $0) } }
            .filter { $0.1 <= uptime }
            .max { $0.1 < $1.1 }?.0 ?? "queued"
    }

    /// Microsecond precision, like the log's `uptimeMs`.
    static func milliseconds(_ seconds: TimeInterval) -> String {
        String((seconds * 1_000_000).rounded() / 1_000)
    }
}

/// A change's trace as it ended, for the benchmark.
struct EndedChangeTrace {
    let changeID: Int
    let operation: String
    /// `completed`, or a `change_ended` outcome.
    let outcome: String
    let trace: ChangeTrace
}
