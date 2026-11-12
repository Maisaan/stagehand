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
        let handoff: GestureFollowEnded.Handoff
        if let settle {
            handoff = .settle(operation: settle.operation, changeID: settle.changeID)
        } else if let active = activeChange {
            handoff = .change(id: active.id)
        } else {
            handoff = .cancelled
        }
        let ended = GestureFollowEnded(gestureID: follow?.gestureID, summary: summary,
                                       touchesLanded: follow?.input?.touchesLandedUptime, writes: writes,
                                       handoff: handoff)
        gestureFollowSink?(ended)
        diagnostics.record("gesture_follow_ended", details: ended.details)
    }
}

/// One live follow as it ended: logged as `gesture_follow_ended` and given to the benchmark, logged or not.
struct GestureFollowEnded {
    enum Handoff: Equatable {
        /// A change started and cut the follow: the swipe's own when it navigated.
        case change(id: Int)
        /// An animation replaced it: `gesture.preview.restore` for a swipe that went back.
        case settle(operation: String, changeID: Int?)
        case cancelled
    }

    let gestureID: Int?
    let summary: RibbonFollowSummary
    let touchesLanded: TimeInterval?
    /// The follow's own writes: statistics restart when it starts.
    let writes: MotionWriteSummary
    let handoff: Handoff

    var followStartedAfterTouch: TimeInterval? { touchesLanded.map { summary.started - $0 } }
    var firstAcknowledgedWriteAfterTouch: TimeInterval? {
        touchesLanded.flatMap { landed in writes.firstAcknowledgedUptime.values.min().map { $0 - landed } }
    }

    var details: [String: String] {
        func milliseconds(_ seconds: TimeInterval?) -> String {
            seconds.map { String(Int(($0 * 1_000).rounded())) } ?? "none"
        }
        var details = [
            "durationMilliseconds": milliseconds(summary.ended - summary.started),
            "ticks": String(summary.ticks),
            "droppedTicks": summary.droppedTicks.map(String.init) ?? "unknown",
            "largestTickGapMilliseconds": milliseconds(summary.largestTargetGap),
            "largestCallbackGapMilliseconds": milliseconds(summary.largestCallbackGap),
            "lateCallbacks": String(summary.lateCallbacks),
            "followStartedAfterTouchMilliseconds": milliseconds(followStartedAfterTouch),
            "firstAcknowledgedWriteAfterTouchMilliseconds": milliseconds(firstAcknowledgedWriteAfterTouch),
            "motionWritesSent": String(writes.sent),
            "motionWritesAcknowledged": String(writes.acknowledged),
            "motionWritesUnacknowledged": String(writes.unacknowledged),
            "motionWritesFailed": String(writes.failed)
        ]
        if let gestureID { details["gestureID"] = String(gestureID) }
        switch handoff {
        case .settle(let operation, let changeID):
            details["handoff"] = "settle"
            details["settleOperation"] = operation
            if let changeID { details["handoffChangeID"] = String(changeID) }
        case .change(let id):
            details["handoff"] = "change"
            details["handoffChangeID"] = String(id)
        case .cancelled:
            details["handoff"] = "cancelled"
        }
        return details
    }
}
