import ApplicationServices
import Foundation

/// Ribbon motion moves windows at display rate. Each move is a synchronous
/// cross-process AX message that waits until the target app's run loop is free,
/// so on the main thread one busy app would stall every frame, the other apps'
/// windows, and the input taps. Writes run on one serial queue per app, and only
/// the newest position per window is written; positions superseded while an app
/// is busy are dropped.
final class MotionPositionWriter: @unchecked Sendable {
    private struct Pending {
        let windowID: String
        let element: AXUIElement
        let position: CGPoint
    }

    private let lock = NSLock()
    private var pending: [pid_t: [String: Pending]] = [:]
    /// Apps with a drain queued or running.
    private var draining: Set<pid_t> = []
    private var queues: [pid_t: DispatchQueue] = [:]
    /// Per-animation counts for diagnostics: positions requested, AX writes sent, slowest write.
    private var requested = 0
    private var sent = 0
    private var slowestWrite: Double = 0
    /// When each window last moved, and the longest it went without moving. A
    /// long gap is a visible freeze of that window mid-motion.
    private var lastSent: [String: Double] = [:]
    private var largestGap: [String: Double] = [:]

    func resetStatistics() {
        lock.withLock {
            requested = 0
            sent = 0
            slowestWrite = 0
            lastSent = [:]
            largestGap = [:]
        }
    }

    struct Statistics {
        let requested: Int
        let sent: Int
        let slowestMilliseconds: Int
        let largestGapMilliseconds: [String: Int]
    }

    var statistics: Statistics {
        lock.withLock {
            Statistics(requested: requested, sent: sent, slowestMilliseconds: Int(slowestWrite * 1_000),
                       largestGapMilliseconds: largestGap.mapValues { Int($0 * 1_000) })
        }
    }

    func write(windowID: String, pid: pid_t, element: AXUIElement, position: CGPoint) {
        let queue: DispatchQueue? = lock.withLock {
            requested += 1
            pending[pid, default: [:]][windowID] = Pending(windowID: windowID, element: element, position: position)
            guard draining.insert(pid).inserted else { return nil }
            return queueLocked(pid: pid)
        }
        queue?.async { self.drain(pid: pid) }
    }

    /// Brings a window to the front without activating its app, ahead of any
    /// position written to it afterwards. An app answers this at once while it is
    /// idle; activation, which also raises, is what keeps an app busy.
    func raise(pid: pid_t, element: AXUIElement) {
        let queue = lock.withLock { queueLocked(pid: pid) }
        queue.async { _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
    }

    /// Drops queued writes for the app and waits for one already in progress.
    /// Call before any other frame change to the app's windows, so a stale motion
    /// write cannot land after it. Free when no motion write is outstanding.
    func settle(pid: pid_t) {
        let queue: DispatchQueue? = lock.withLock {
            pending[pid] = nil
            return queues[pid]
        }
        // Waits for a raise or a write already sent; free when the queue is idle.
        queue?.sync {}
    }

    /// Waits, without blocking the caller's thread, until every queued write has been sent.
    func flush() async {
        let queues: [DispatchQueue] = lock.withLock { Array(self.queues.values) }
        for queue in queues {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }

    func forget(pid: pid_t) {
        settle(pid: pid)
        lock.withLock { _ = queues.removeValue(forKey: pid) }
    }

    private func queueLocked(pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "app.stagehand.motion-writes.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }

    private func drain(pid: pid_t) {
        while true {
            let batch: [Pending]? = lock.withLock {
                guard let windows = pending.removeValue(forKey: pid), !windows.isEmpty else {
                    draining.remove(pid)
                    return nil
                }
                return Array(windows.values)
            }
            guard let batch else { return }
            for item in batch {
                var position = item.position
                guard let value = AXValueCreate(.cgPoint, &position) else { continue }
                let began = CFAbsoluteTimeGetCurrent()
                AXUIElementSetAttributeValue(item.element, kAXPositionAttribute as CFString, value)
                let finished = CFAbsoluteTimeGetCurrent()
                lock.withLock {
                    sent += 1
                    slowestWrite = max(slowestWrite, finished - began)
                    if let previous = lastSent[item.windowID] {
                        largestGap[item.windowID] = max(largestGap[item.windowID] ?? 0, finished - previous)
                    }
                    lastSent[item.windowID] = finished
                }
            }
        }
    }
}
