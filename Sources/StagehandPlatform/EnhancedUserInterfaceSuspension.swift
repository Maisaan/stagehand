import ApplicationServices
import Foundation

/// An assistive client can turn on AXEnhancedUserInterface for an app (Chrome
/// keeps it on once any client asks). AppKit then animates every accessibility
/// move and resize while answering the write at once, so ribbon motion lands in
/// the app late and readbacks see the frame mid-animation. The attribute is off
/// while Stagehand writes an app's frames and comes back on once the app's
/// windows have been still for `quietPeriod`.
final class EnhancedUserInterfaceSuspension: @unchecked Sendable {
    private struct Burst {
        var suspended: Bool
        var lastWrite: TimeInterval
    }

    private static let attributeName = "AXEnhancedUserInterface"

    private let quietPeriod: TimeInterval
    private let lock = NSLock()
    private var bursts: [pid_t: Burst] = [:]
    private let restoreQueue = DispatchQueue(label: "app.stagehand.enhanced-user-interface", qos: .utility)

    init(quietPeriod: TimeInterval = 1) {
        self.quietPeriod = quietPeriod
    }

    /// Call before writing a frame to one of the app's windows. The first write
    /// of a burst reads the attribute once; later writes cost only the lock.
    /// Returns whether the app's attribute is held off.
    @discardableResult
    func prepareForFrameWrite(pid: pid_t) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let existing: Burst? = lock.withLock {
            if bursts[pid] != nil { bursts[pid]?.lastWrite = now }
            return bursts[pid]
        }
        if let existing { return existing.suspended }
        lock.withLock { bursts[pid] = Burst(suspended: false, lastWrite: now) }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let enabled = AXUIElementCopyAttributeValue(app, Self.attributeName as CFString, &value) == .success
            && (value as? Bool) == true
        let suspended = enabled && AXUIElementSetAttributeValue(app, Self.attributeName as CFString, kCFBooleanFalse) == .success
        lock.withLock { bursts[pid]?.suspended = suspended }
        scheduleRestore(pid: pid, after: quietPeriod)
        return suspended
    }

    /// Turns the attribute back on for every app now; for Stop and quit.
    func restoreAll() {
        let pids: [pid_t] = lock.withLock {
            let suspended = bursts.filter(\.value.suspended).map(\.key)
            bursts.removeAll()
            return suspended
        }
        for pid in pids { setEnabled(pid: pid) }
    }

    func forget(pid: pid_t) {
        lock.withLock { _ = bursts.removeValue(forKey: pid) }
    }

    private func scheduleRestore(pid: pid_t, after delay: TimeInterval) {
        restoreQueue.asyncAfter(deadline: .now() + delay) { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            enum Next { case none, wait(TimeInterval), restore }
            let next: Next = lock.withLock {
                guard let burst = bursts[pid] else { return .none }
                let still = now - burst.lastWrite
                if still < quietPeriod { return .wait(quietPeriod - still) }
                bursts.removeValue(forKey: pid)
                return burst.suspended ? .restore : .none
            }
            switch next {
            case .none: break
            case .wait(let remaining): scheduleRestore(pid: pid, after: remaining)
            case .restore: setEnabled(pid: pid)
            }
        }
    }

    private func setEnabled(pid: pid_t) {
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), Self.attributeName as CFString, kCFBooleanTrue)
    }
}
