import AppKit
import Darwin

/// When a process started, used with its pid to tell one process from a later
/// reuse of the same pid. `NSRunningApplication.launchDate` is nil for some
/// apps, Finder among them, so the kernel's process start time stands in.
public enum ProcessLaunchDate {
    public static func launchDate(for app: NSRunningApplication) -> Date? {
        app.launchDate ?? kernelStartDate(pid: app.processIdentifier)
    }

    public static func launchDate(pid: pid_t) -> Date? {
        if let app = NSRunningApplication(processIdentifier: pid) { return launchDate(for: app) }
        return kernelStartDate(pid: pid)
    }

    /// The start time recorded in the kernel process table, to the microsecond.
    /// Nil when no process has that pid.
    static func kernelStartDate(pid: pid_t) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
