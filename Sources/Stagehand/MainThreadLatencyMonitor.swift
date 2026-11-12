import Darwin
import Foundation
import QuartzCore
import StagehandPlatform

/// Posts a block to the main thread every 4 ms from a background thread and
/// records how long each waited. The keyboard tap, gestures, and ribbon frames
/// all run on the main thread, so this delay is the input latency users feel.
/// While a post waits, the `MainThreadActivity` label is sampled every 2 ms, so a
/// stall names the call that was running. A stall also carries the main thread's own
/// CPU during the wait and the load average, as `MainThreadWatchdog` records them.
final class MainThreadLatencyMonitor: @unchecked Sendable {
    struct Wait: Sendable {
        let postedUptime: Double
        let milliseconds: Double
        let label: String
        /// Read only for a wait over `stallMilliseconds`; nil otherwise or when the kernel does not answer.
        var mainThreadCPUMilliseconds: Double?
        var loadAverage: Double?
    }

    static let stallMilliseconds = 33.0

    private let lock = NSLock()
    private var activeRun: Int?
    private var lastRun = 0
    private var recorded: [Wait] = []
    private var samplers = 0
    /// Captured on the main thread, where the benchmark creates the monitor.
    private let mainThreadPort: thread_act_t = Thread.isMainThread ? mach_thread_self() : 0

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
        let mainThreadPort = mainThreadPort
        Thread.detachNewThread { [self] in
            defer { lock.withLock { samplers -= 1 } }
            while lock.withLock({ activeRun == run }) {
                let wait = Self.measureMainThreadWait(mainThreadPort: mainThreadPort)
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

    private static func measureMainThreadWait(mainThreadPort: thread_act_t) -> Wait {
        let cpuBefore = MainThreadWatchdog.cpuMicroseconds(mainThreadPort)
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
        var wait = Wait(postedUptime: posted, milliseconds: (answer.uptime - posted) * 1_000, label: label ?? "unlabeled")
        guard wait.milliseconds > stallMilliseconds else { return wait }
        if let cpuBefore, let cpuAfter = MainThreadWatchdog.cpuMicroseconds(mainThreadPort) {
            wait.mainThreadCPUMilliseconds = Double(cpuAfter - cpuBefore) / 1_000
        }
        var load = [Double](repeating: 0, count: 1)
        if getloadavg(&load, 1) == 1 { wait.loadAverage = load[0] }
        return wait
    }
}

private final class MainThreadAnswer: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var uptime = 0.0
}
