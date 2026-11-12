import Foundation
import QuartzCore
import StagehandPlatform

/// Posts a block to the main thread every 4 ms from a background thread and
/// records how long each waited. The keyboard tap, gestures, and ribbon frames
/// all run on the main thread, so this delay is the input latency users feel.
/// While a post waits, the `MainThreadActivity` label is sampled every 2 ms, so a
/// stall names the call that was running.
final class MainThreadLatencyMonitor: @unchecked Sendable {
    struct Wait: Sendable {
        let postedUptime: Double
        let milliseconds: Double
        let label: String
    }

    static let stallMilliseconds = 33.0

    private let lock = NSLock()
    private var activeRun: Int?
    private var lastRun = 0
    private var recorded: [Wait] = []
    private var samplers = 0

    var liveSamplers: Int { lock.withLock { samplers } }
    var waits: [Wait] { lock.withLock { recorded } }

    func start() {
        let run: Int = lock.withLock {
            lastRun += 1
            activeRun = lastRun
            recorded.removeAll()
            samplers += 1
            return lastRun
        }
        Thread.detachNewThread { [self] in
            defer { lock.withLock { samplers -= 1 } }
            while lock.withLock({ activeRun == run }) {
                let wait = Self.measureMainThreadWait()
                lock.withLock { if activeRun == run { recorded.append(wait) } }
                usleep(4_000)
            }
        }
    }

    @discardableResult
    func stop() -> [Wait] {
        lock.withLock {
            activeRun = nil
            return recorded
        }
    }

    private static func measureMainThreadWait() -> Wait {
        let posted = CACurrentMediaTime()
        let answer = MainThreadAnswer()
        DispatchQueue.main.async {
            answer.uptime = CACurrentMediaTime()
            answer.semaphore.signal()
        }
        var seen: [String: Int] = [:]
        while answer.semaphore.wait(timeout: .now() + 0.002) == .timedOut {
            seen[MainThreadActivity.current ?? "unlabeled", default: 0] += 1
        }
        let label = seen.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return Wait(postedUptime: posted, milliseconds: (answer.uptime - posted) * 1_000, label: label ?? "unlabeled")
    }
}

private final class MainThreadAnswer: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var uptime = 0.0
}
