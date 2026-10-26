import Foundation

/// Names what the main thread is doing, for `main_thread_stall` reports. The
/// diagnostic log records nothing while the main thread is blocked, so the last
/// event before a stall cannot say what blocked it. The watchdog samples
/// `current` from its own thread while it waits.
///
/// Off unless diagnostic logging is on; labels are built only while enabled and
/// only on the main thread.
public enum MainThreadActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var labels: [String] = []
    /// Labeled reads and writes to other apps on the main thread since the last take.
    nonisolated(unsafe) private static var appCalls = 0

    public static var isEnabled: Bool { lock.withLock { enabled } }

    public static func setEnabled(_ value: Bool) {
        lock.withLock {
            enabled = value
            if !value { labels.removeAll() }
        }
    }

    /// The outermost and innermost labels, e.g. "axCallback AXMoved pid=644 > readFrame pid=644".
    public static var current: String? {
        lock.withLock {
            guard let first = labels.first else { return nil }
            return labels.count == 1 ? first : first + " > " + labels[labels.count - 1]
        }
    }

    /// Synchronous Accessibility reads and writes made on the main thread since the last
    /// call, counted while enabled. Each waits on another app.
    public static func takeAppCallCount() -> Int {
        lock.withLock {
            defer { appCalls = 0 }
            return appCalls
        }
    }

    @discardableResult
    public static func during<T>(_ label: @autoclosure () -> String, _ work: () throws -> T) rethrows -> T {
        guard Thread.isMainThread, lock.withLock({ enabled }) else { return try work() }
        let text = label()
        let appCall = text.hasPrefix("read ") || text.hasPrefix("write ")
        lock.withLock {
            labels.append(text)
            if appCall { appCalls += 1 }
        }
        defer { lock.withLock { if !labels.isEmpty { labels.removeLast() } } }
        return try work()
    }
}
