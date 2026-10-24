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
/// is off.
final class MainThreadWatchdog: @unchecked Sendable {
    static let interval: TimeInterval = 0.05
    static let thresholdMilliseconds = 50
    static let sampleInterval: TimeInterval = 0.01

    private let lock = NSLock()
    private var enabled = false
    /// Labels sampled while the current post waits; read by the posted block.
    private var samples: [String: Int] = [:]
    private let report: @MainActor (_ waitedMilliseconds: Int, _ activity: String) -> Void

    init(report: @escaping @MainActor (_ waitedMilliseconds: Int, _ activity: String) -> Void) {
        self.report = report
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "app.stagehand.main-thread-watchdog"
            while let self {
                guard self.lock.withLock({ self.enabled }) else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                let posted = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                self.lock.withLock { self.samples.removeAll() }
                DispatchQueue.main.async {
                    let waited = Int((CACurrentMediaTime() - posted) * 1_000)
                    if waited >= Self.thresholdMilliseconds {
                        let activity = Self.summary(self.lock.withLock { self.samples })
                        MainActor.assumeIsolated { self.report(waited, activity) }
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

    /// Most-sampled labels first, each with its share of the samples, e.g.
    /// "observe AXWindowCreated pid=20569 x9, unlabeled x1".
    static func summary(_ samples: [String: Int]) -> String {
        guard !samples.isEmpty else { return "none" }
        return samples.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
    }
}
