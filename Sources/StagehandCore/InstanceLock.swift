import Foundation

/// An exclusive advisory lock on a file, held for the lifetime of the object.
/// Two Stagehand processes moving the same windows would fight over frames and
/// restore each other's parking, so every mode that touches windows takes this
/// lock first. flock() is released by the kernel when the process exits, so a
/// crash cannot leave a stale lock behind.
public final class InstanceLock {
    public enum Failure: Error, Equatable {
        /// Another process holds the lock.
        case held
        case io(errno: Int32)
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Stagehand/instance.lock")
    }

    public let url: URL
    private let descriptor: Int32

    /// Takes the lock without waiting. Throws `.held` when another process has it.
    public init(url: URL = InstanceLock.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io(errno: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw code == EWOULDBLOCK ? Failure.held : Failure.io(errno: code)
        }
        self.descriptor = descriptor
        // The holder's PID helps a developer find the other instance; the lock
        // itself does not depend on it.
        let pid = Data("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        pid.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
