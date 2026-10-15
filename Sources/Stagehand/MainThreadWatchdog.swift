import Foundation
import QuartzCore

/// Reports main-thread stalls to the diagnostic log. The keyboard tap, gestures,
/// and ribbon frames all run on the main thread, so a stall there delays typing
/// in every app. A background thread posts a block every 50 ms and measures how
/// long it waited; a wait of `threshold` or more is recorded as
/// `main_thread_stall` with the last diagnostic event before it, which names the
/// phase that blocked. Idle while logging is off.
final class MainThreadWatchdog: @unchecked Sendable {
    static let interval: TimeInterval = 0.05
    static let thresholdMilliseconds = 50

    private let lock = NSLock()
    private var enabled = false
    private let report: @MainActor (_ waitedMilliseconds: Int) -> Void

    init(report: @escaping @MainActor (_ waitedMilliseconds: Int) -> Void) {
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
                DispatchQueue.main.async {
                    let waited = Int((CACurrentMediaTime() - posted) * 1_000)
                    if waited >= Self.thresholdMilliseconds {
                        MainActor.assumeIsolated { self.report(waited) }
                    }
                    answered.signal()
                }
                answered.wait()
                Thread.sleep(forTimeInterval: Self.interval)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        lock.withLock { enabled = value }
    }
}
