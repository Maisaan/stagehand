import Foundation

/// One gesture follow's display ticks, without per-frame logging. Target times are the
/// display link's; entry times are when the callback began, kept apart.
struct RibbonFollowMeter {
    let started: TimeInterval
    private(set) var ticks = 0
    private var lastTarget: TimeInterval?
    private var lastEntry: TimeInterval?
    private var largestTargetGap: TimeInterval?
    private var largestEntryGap: TimeInterval?
    /// Nil once a tick arrives without the link's cadence: then drops cannot be counted.
    private var droppedTicks: Int? = 0
    private var lateCallbacks = 0

    init(started: TimeInterval) {
        self.started = started
    }

    /// `interval` is the display link's own frame interval for this tick.
    mutating func tick(target: TimeInterval, entered: TimeInterval, interval: TimeInterval?) {
        ticks += 1
        if entered > target { lateCallbacks += 1 }
        if let lastTarget {
            let gap = target - lastTarget
            largestTargetGap = max(largestTargetGap ?? 0, gap)
            if let interval, interval > 0, let dropped = droppedTicks {
                droppedTicks = dropped + max(0, Int((gap / interval).rounded()) - 1)
            } else {
                droppedTicks = nil
            }
        }
        if let lastEntry { largestEntryGap = max(largestEntryGap ?? 0, entered - lastEntry) }
        lastTarget = target
        lastEntry = entered
    }

    func summary(ended: TimeInterval, handedToAnimation: Bool) -> RibbonFollowSummary {
        RibbonFollowSummary(started: started, ended: ended, ticks: ticks, droppedTicks: droppedTicks,
                            largestTargetGap: largestTargetGap, largestCallbackGap: largestEntryGap,
                            lateCallbacks: lateCallbacks, handedToAnimation: handedToAnimation)
    }
}

struct RibbonFollowSummary: Equatable {
    let started: TimeInterval
    let ended: TimeInterval
    let ticks: Int
    /// Ticks the display link skipped at the cadence it reported; nil when it reported none.
    let droppedTicks: Int?
    /// Longest step between the ticks' target times.
    let largestTargetGap: TimeInterval?
    /// Longest step between the callbacks' entry times.
    let largestCallbackGap: TimeInterval?
    /// Callbacks that began after the frame time they were drawing for.
    let lateCallbacks: Int
    /// A settle animation replaced the follow; otherwise the motion was cancelled.
    let handedToAnimation: Bool
}
