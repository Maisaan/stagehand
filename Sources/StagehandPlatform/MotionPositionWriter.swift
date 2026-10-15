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
        let element: AXUIElement
        let position: CGPoint
    }

    private let lock = NSLock()
    private var pending: [pid_t: [String: Pending]] = [:]
    /// Apps with a drain queued or running.
    private var draining: Set<pid_t> = []
    private var queues: [pid_t: DispatchQueue] = [:]

    func write(windowID: String, pid: pid_t, element: AXUIElement, position: CGPoint) {
        let queue: DispatchQueue? = lock.withLock {
            pending[pid, default: [:]][windowID] = Pending(element: element, position: position)
            guard draining.insert(pid).inserted else { return nil }
            return queueLocked(pid: pid)
        }
        queue?.async { self.drain(pid: pid) }
    }

    /// Drops queued writes for the app and waits for one already in progress.
    /// Call before any other frame change to the app's windows, so a stale motion
    /// write cannot land after it. Free when no motion write is outstanding.
    func settle(pid: pid_t) {
        let queue: DispatchQueue? = lock.withLock {
            pending[pid] = nil
            return draining.contains(pid) ? queues[pid] : nil
        }
        queue?.sync {}
    }

    /// Waits, without blocking the caller's thread, until every queued write has been sent.
    func flush() async {
        let queues: [DispatchQueue] = lock.withLock { draining.compactMap { self.queues[$0] } }
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
                AXUIElementSetAttributeValue(item.element, kAXPositionAttribute as CFString, value)
            }
        }
    }
}
