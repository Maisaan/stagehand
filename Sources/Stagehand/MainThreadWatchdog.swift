import Darwin
import Foundation
import QuartzCore
import StagehandPlatform

/// Reports main-thread stalls to the diagnostic log. The keyboard tap, gestures,
/// and ribbon frames all run on the main thread, so a stall there delays typing
/// in every app. A background thread posts a block every 50 ms and measures how
/// long it waited; a wait of `threshold` or more is recorded as
/// `main_thread_stall` with the last diagnostic event before it, which names the
/// phase that blocked, and with the `MainThreadActivity` labels sampled every
/// 10 ms while it waited, which name the call that blocked. Idle while logging
/// is off. Each stall also carries the main thread's own CPU time during the wait
/// and the load average: CPU close to the wait means Stagehand was computing, CPU
/// near zero means it was waiting, on another app's reply or, under high load, for
/// a CPU at all.
final class MainThreadWatchdog: @unchecked Sendable {
    static let interval: TimeInterval = 0.05
    static let thresholdMilliseconds = 50
    static let sampleInterval: TimeInterval = 0.01

    private let lock = NSLock()
    private var enabled = false
    /// Labels sampled while the current post waits; read by the posted block.
    private var samples: [String: Int] = [:]
    private let report: @MainActor (_ waitedMilliseconds: Int, _ activity: String, _ details: [String: String]) -> Void
    /// The main thread's Mach port, for reading its CPU time from the watchdog thread.
    /// Captured in init, which the model runs on the main thread; kept for the process.
    private let mainThreadPort: thread_act_t = Thread.isMainThread ? mach_thread_self() : 0

    init(report: @escaping @MainActor (_ waitedMilliseconds: Int, _ activity: String, _ details: [String: String]) -> Void) {
        self.report = report
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "app.stagehand.main-thread-watchdog"
            while let self {
                guard self.lock.withLock({ self.enabled }) else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                let posted = CACurrentMediaTime()
                let cpuBefore = Self.cpuMicroseconds(self.mainThreadPort)
                let answered = DispatchSemaphore(value: 0)
                self.lock.withLock { self.samples.removeAll() }
                DispatchQueue.main.async {
                    let waited = Int((CACurrentMediaTime() - posted) * 1_000)
                    if waited >= Self.thresholdMilliseconds {
                        let activity = Self.summary(self.lock.withLock { self.samples })
                        var details: [String: String] = [:]
                        if let cpuBefore, let cpuAfter = Self.cpuMicroseconds(self.mainThreadPort) {
                            details["mainThreadCPUMilliseconds"] = String((cpuAfter - cpuBefore) / 1_000)
                        }
                        var load = [Double](repeating: 0, count: 1)
                        if getloadavg(&load, 1) == 1 { details["loadAverage"] = String(format: "%.1f", load[0]) }
                        MainActor.assumeIsolated { self.report(waited, activity, details) }
                    }
                    answered.signal()
                }
                while answered.wait(timeout: .now() + Self.sampleInterval) == .timedOut {
                    let label = MainThreadActivity.current ?? "unlabeled"
                    self.lock.withLock { self.samples[label, default: 0] += 1 }
                }
                Thread.sleep(forTimeInterval: Self.interval)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value }
        MainThreadActivity.setEnabled(value)
    }

    /// User plus system CPU time a thread has used, or nil if the kernel does not answer.
    static func cpuMicroseconds(_ thread: thread_act_t) -> Int64? {
        guard thread != 0 else { return nil }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.user_time.seconds + info.system_time.seconds) * 1_000_000
            + Int64(info.user_time.microseconds + info.system_time.microseconds)
    }

    /// Most-sampled labels first, each with its share of the samples, e.g.
    /// "observe AXWindowCreated pid=20569 x9, unlabeled x1".
    static func summary(_ samples: [String: Int]) -> String {
        guard !samples.isEmpty else { return "none" }
        return samples.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
    }
}
