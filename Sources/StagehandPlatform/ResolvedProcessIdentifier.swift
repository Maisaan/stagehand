import AppKit
import Darwin

extension NSRunningApplication {
    /// The app's pid. AppKit reports -1 for some apps that are launched from inside
    /// another app's bundle, such as Xcode's Device Hub, both in the workspace list and
    /// from `NSRunningApplication(processIdentifier:)`. Their pid is then found
    /// from the kernel process table by executable path. Stays -1 when no
    /// process matches.
    public var resolvedProcessIdentifier: pid_t {
        let pid = processIdentifier
        return pid > 0 ? pid : ProcessIdentifierResolver.shared.pid(for: self)
    }
}

final class ProcessIdentifierResolver: @unchecked Sendable {
    static let shared = ProcessIdentifierResolver()

    private struct Key: Hashable {
        let path: String
        let launchDate: Date?
    }

    private let lock = NSLock()
    private var resolved: [Key: pid_t] = [:]
    /// Bounds the process-table walk for an app whose process cannot be found.
    private var failedAt: [Key: TimeInterval] = [:]
    private static let retrySeconds: TimeInterval = 2

    func pid(for app: NSRunningApplication) -> pid_t {
        guard let path = app.executableURL?.resolvingSymlinksInPath().path else { return -1 }
        let key = Key(path: path, launchDate: app.launchDate)
        lock.lock()
        defer { lock.unlock() }
        if let pid = resolved[key] {
            // A dead process keeps its pid so termination can still be matched;
            // a pid reused by another executable is looked up again.
            switch Self.executablePath(pid: pid) {
            case nil, path?: return pid
            default: resolved.removeValue(forKey: key)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let failed = failedAt[key], now - failed < Self.retrySeconds { return -1 }
        guard let pid = Self.findProcess(path: path, launchDate: app.launchDate) else {
            failedAt[key] = now
            return -1
        }
        failedAt.removeValue(forKey: key)
        resolved[key] = pid
        return pid
    }

    /// Among processes running `path`, the one that started closest to `launchDate`.
    static func findProcess(path: String, launchDate: Date?) -> pid_t? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return nil }
        let matches = pids.prefix(Int(count)).filter { $0 > 0 && executablePath(pid: $0) == path }
        guard let launchDate, matches.count > 1 else { return matches.first }
        return matches.min { lhs, rhs in
            let lhsGap = ProcessLaunchDate.kernelStartDate(pid: lhs).map { abs($0.timeIntervalSince(launchDate)) } ?? .infinity
            let rhsGap = ProcessLaunchDate.kernelStartDate(pid: rhs).map { abs($0.timeIntervalSince(launchDate)) } ?? .infinity
            return lhsGap < rhsGap
        }
    }

    static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }
}
