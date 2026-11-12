import Foundation
import StagehandPlatform

/// A gesture's live follow, measured apart from the settle that ends it.
extension StagehandModel {
    struct GestureFollowStart {
        let gestureID: Int
        let input: InputArrival?
    }

    /// The settle about to start, so a follow it replaces can name it.
    struct SettleStart {
        let operation: String
        let changeID: Int?
        /// Writes counted before the settle reset them: the follow's, if it is replacing one.
        let writesBefore: MotionWriteSummary
    }

    func measureGestureFollows() {
        ribbonMotion.onFollowStarted = { [weak self] in
            guard let self else { return }
            // Follow writes are counted on their own; settle resets again as it starts.
            _ = self.windowSystem.motionWriteSummary(reset: true)
            self.gestureFollow = GestureFollowStart(gestureID: self.lastGestureID, input: InputArrival.beingDelivered)
        }
        ribbonMotion.onFollowEnded = { [weak self] in self?.recordGestureFollowEnded($0) }
    }

    private func recordGestureFollowEnded(_ summary: RibbonFollowSummary) {
        let follow = gestureFollow
        gestureFollow = nil
        let settle = summary.handedToAnimation ? settleStart : nil
        let writes = settle?.writesBefore ?? windowSystem.motionWriteSummary(reset: false)
        func milliseconds(_ seconds: TimeInterval?) -> String {
            seconds.map { String(Int(($0 * 1_000).rounded())) } ?? "none"
        }
        let landed = follow?.input?.touchesLandedUptime
        let firstAcknowledged = writes.firstAcknowledgedUptime.values.min()
        var details = [
            "durationMilliseconds": milliseconds(summary.ended - summary.started),
            "ticks": String(summary.ticks),
            "droppedTicks": summary.droppedTicks.map(String.init) ?? "unknown",
            "largestTickGapMilliseconds": milliseconds(summary.largestTargetGap),
            "largestCallbackGapMilliseconds": milliseconds(summary.largestCallbackGap),
            "lateCallbacks": String(summary.lateCallbacks),
            "followStartedAfterTouchMilliseconds": milliseconds(landed.map { summary.started - $0 }),
            "firstAcknowledgedWriteAfterTouchMilliseconds": milliseconds(
                landed.flatMap { landed in firstAcknowledged.map { $0 - landed } }),
            "motionWritesSent": String(writes.sent),
            "motionWritesAcknowledged": String(writes.acknowledged),
            "motionWritesUnacknowledged": String(writes.unacknowledged),
            "motionWritesFailed": String(writes.failed)
        ]
        if let follow { details["gestureID"] = String(follow.gestureID) }
        if let settle {
            details["handoff"] = "settle"
            details["settleOperation"] = settle.operation
            if let changeID = settle.changeID { details["handoffChangeID"] = String(changeID) }
        } else if let active = activeChange {
            details["handoff"] = "change"
            details["handoffChangeID"] = String(active.id)
        } else {
            details["handoff"] = "cancelled"
        }
        diagnostics.record("gesture_follow_ended", details: details)
    }
}
