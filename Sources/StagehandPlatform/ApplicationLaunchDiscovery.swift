import Foundation

/// Launch, reopening a windowless app, and AX window-created notifications can all
/// precede a usable window. Recheck briefly after launch/activation, never while idle.
@MainActor
final class ApplicationLaunchDiscovery {
    private var tasks: [Int32: Task<Void, Never>] = [:]
    private let delays: [Duration]

    init(delays: [Duration] = [.milliseconds(100), .milliseconds(250), .milliseconds(500),
                               .seconds(1), .seconds(2)]) {
        self.delays = delays
    }

    func schedule(pid: Int32, refresh: @escaping @MainActor () -> Bool) {
        guard tasks[pid] == nil else { return }
        tasks[pid] = Task { @MainActor [weak self, delays] in
            for delay in delays {
                do { try await Task.sleep(for: delay) }
                catch { return }
                guard !Task.isCancelled else { return }
                let keepChecking = refresh()
                guard !Task.isCancelled else { return }
                if !keepChecking { break }
            }
            self?.tasks.removeValue(forKey: pid)
        }
    }

    func cancel(pid: Int32) {
        tasks.removeValue(forKey: pid)?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
