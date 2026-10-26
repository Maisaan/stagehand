import Darwin
import Foundation

/// Records how heavy Stagehand is while it runs: memory footprint, CPU use, wakeups
/// and threads, once a minute while diagnostic logging is on, as `resource_sample`.
/// `analyze-log.py --split` compares them across builds. Each sample is two
/// syscalls; between samples the task sleeps.
@MainActor
final class ResourceSampler {
    static let interval: Duration = .seconds(60)

    struct Usage: Equatable {
        var footprintBytes: UInt64
        /// User plus system CPU time, in nanoseconds.
        var cpuNanoseconds: UInt64
        var idleWakeups: UInt64
        var interruptWakeups: UInt64
        var threads: Int32
        var uptime: TimeInterval
    }

    private let record: (String, [String: String]) -> Void
    private let read: () -> Usage?
    private var task: Task<Void, Never>?
    private var previous: Usage?

    init(record: @escaping (String, [String: String]) -> Void, read: @escaping () -> Usage? = ResourceSampler.currentUsage) {
        self.record = record
        self.read = read
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != (task != nil) else { return }
        task?.cancel()
        task = nil
        previous = nil
        guard enabled else { return }
        sample()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.interval) } catch { return }
                self?.sample()
            }
        }
    }

    /// Records one sample; CPU and wakeup rates cover the time since the previous one.
    func sample() {
        guard let usage = read() else { return }
        record("resource_sample", Self.details(usage, since: previous))
        previous = usage
    }

    nonisolated static func details(_ usage: Usage, since previous: Usage?) -> [String: String] {
        var details = [
            "footprintMegabytes": String(format: "%.1f", Double(usage.footprintBytes) / 1_048_576),
            "threads": String(usage.threads)
        ]
        if let previous, usage.uptime > previous.uptime {
            let seconds = usage.uptime - previous.uptime
            let cpu = Double(usage.cpuNanoseconds &- previous.cpuNanoseconds) / 1e9
            details["periodSeconds"] = String(Int(seconds.rounded()))
            details["cpuPercent"] = String(format: "%.2f", cpu / seconds * 100)
            details["idleWakeupsPerSecond"] = String(format: "%.1f",
                Double(usage.idleWakeups &- previous.idleWakeups) / seconds)
            details["interruptWakeupsPerSecond"] = String(format: "%.1f",
                Double(usage.interruptWakeups &- previous.interruptWakeups) / seconds)
        }
        return details
    }

    nonisolated static func currentUsage() -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size) == size ? task.pti_threadnum : 0
        // rusage CPU times are in Mach absolute time units.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(footprintBytes: info.ri_phys_footprint,
                     cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)),
                     idleWakeups: info.ri_pkg_idle_wkups,
                     interruptWakeups: info.ri_interrupt_wkups,
                     threads: threads,
                     uptime: ProcessInfo.processInfo.systemUptime)
    }
}
