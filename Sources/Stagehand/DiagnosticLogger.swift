import Foundation

/// One JSON object per line in ~/Library/Logs/Stagehand/stagehand.log.
///
/// Writes are single appends on the main actor so entries are on disk when the
/// call returns. Retention work (reading and rewriting the file) runs on a
/// utility queue; the main actor only swaps the pruned file back in, merging any
/// lines appended while the scan ran. The file rotates to stagehand.1.log once
/// it reaches `rotationSize`.
@MainActor
final class DiagnosticLogger {
    static let retentionDuration: TimeInterval = 24 * 60 * 60
    static let defaultPruneInterval: Duration = .seconds(60 * 60)
    static let defaultRotationSize = 5 * 1024 * 1024
    /// Entries may outlive the retention period by up to this interval.
    private static let minimumPruneInterval: TimeInterval = 60 * 60
    private static let maximumWriteBackoff: TimeInterval = 60
    private static let pruneQueue = DispatchQueue(label: "dev.stagehand.diagnostic-log", qos: .utility)

    static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/Stagehand/stagehand.log")
    }

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            closeHandle()
            // Entries keep expiring while logging is off.
            Task { await self.pruneExpiredEntries() }
        }
    }
    let logURL: URL
    var rotatedLogURL: URL {
        let name = logURL.deletingPathExtension().lastPathComponent
        let extensionSuffix = logURL.pathExtension.isEmpty ? "" : ".\(logURL.pathExtension)"
        return logURL.deletingLastPathComponent().appendingPathComponent("\(name).1\(extensionSuffix)")
    }
    /// Consecutive failed writes. Each one doubles the pause before the next attempt.
    private(set) var writeFailures = 0
    private(set) var writeAttempts = 0

    private let now: () -> Date
    private let rotationSize: Int
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var fileSize = 0
    /// Advances on every main-actor change to the files other than an append
    /// (rotation, clear). A background scan taken under an older value is stale.
    private var mutations = 0
    /// Test hook: awaited after the background scan returns, before the swap.
    var pruneSwapDelay: (@MainActor () async -> Void)?
    private var writeSuspendedUntil: Date?
    private var nextPruneDate: Date?
    private var pruneTask: Task<Void, Never>?
    private var pruneTimer: Task<Void, Never>?

    init(logURL: URL = DiagnosticLogger.defaultLogURL, enabled: Bool, now: @escaping () -> Date = Date.init,
         pruneInterval: Duration = DiagnosticLogger.defaultPruneInterval,
         rotationSize: Int = DiagnosticLogger.defaultRotationSize) {
        self.logURL = logURL
        isEnabled = enabled
        self.now = now
        self.rotationSize = max(1, rotationSize)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        Task { await self.pruneExpiredEntries() }
        pruneTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pruneInterval) } catch { return }
                guard let self else { return }
                await self.pruneExpiredEntries()
            }
        }
    }

    /// Benchmark hook: sees each event name with its uptime, logged or not.
    var eventObserver: ((String) -> Void)?

    /// The latest event and when it was recorded (system uptime), logged or not.
    /// A main_thread_stall names it as the phase that blocked.
    private(set) var lastEvent: (name: String, uptime: TimeInterval)?

    func record(_ event: String, details: @autoclosure () -> [String: String] = [:]) {
        eventObserver?(event)
        if event != "main_thread_stall" { lastEvent = (event, ProcessInfo.processInfo.systemUptime) }
        guard isEnabled else { return }
        let timestamp = now()
        if let writeSuspendedUntil, timestamp < writeSuspendedUntil { return }
        let entry = Entry(
            timestamp: timestamp.ISO8601Format(.init(includingFractionalSeconds: true)),
            event: event,
            details: details()
        )
        writeAttempts += 1
        do {
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try appendHandle().write(contentsOf: data)
            fileSize += data.count
            writeFailures = 0
            writeSuspendedUntil = nil
            if fileSize >= rotationSize { rotate() }
            if let nextPruneDate {
                if timestamp >= nextPruneDate { Task { await self.pruneExpiredEntries() } }
            } else {
                nextPruneDate = timestamp.addingTimeInterval(Self.retentionDuration)
            }
        } catch {
            closeHandle()
            writeFailures += 1
            let backoff = min(Self.maximumWriteBackoff, pow(2, Double(writeFailures - 1)))
            writeSuspendedUntil = timestamp.addingTimeInterval(backoff)
            NSLog("Stagehand diagnostic log write failed (%d in a row, retrying in %.0f s): %@",
                  writeFailures, backoff, error.localizedDescription)
        }
    }

    func clear() {
        closeHandle()
        fileSize = 0
        mutations += 1
        for url in [logURL, rotatedLogURL] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                NSLog("Stagehand diagnostic log clear failed: %@", error.localizedDescription)
            }
        }
    }

    /// Geometry of one window operation. Identifies the app by bundle identifier
    /// and PID only; the localized app name and the window title are not recorded.
    func recordWindowGeometry(
        event: String,
        bundleIdentifier: String?,
        pid: Int32?,
        windowID: String,
        requestedFrame: CGRect,
        beforeFrame: CGRect? = nil,
        actualFrame: CGRect?,
        details: @autoclosure () -> [String: String] = [:]
    ) {
        guard isEnabled else { return }
        var context = details()
        context["windowID"] = windowID
        context["requestedX"] = String(Double(requestedFrame.minX))
        context["requestedY"] = String(Double(requestedFrame.minY))
        context["requestedWidth"] = String(Double(requestedFrame.width))
        context["requestedHeight"] = String(Double(requestedFrame.height))
        context["beforeFrameAvailable"] = String(beforeFrame != nil)
        context["actualFrameAvailable"] = String(actualFrame != nil)
        if let bundleIdentifier { context["bundleIdentifier"] = bundleIdentifier }
        if let pid { context["pid"] = String(pid) }
        if let beforeFrame {
            context["beforeX"] = String(Double(beforeFrame.minX))
            context["beforeY"] = String(Double(beforeFrame.minY))
            context["beforeWidth"] = String(Double(beforeFrame.width))
            context["beforeHeight"] = String(Double(beforeFrame.height))
        }
        if let actualFrame {
            context["actualX"] = String(Double(actualFrame.minX))
            context["actualY"] = String(Double(actualFrame.minY))
            context["actualWidth"] = String(Double(actualFrame.width))
            context["actualHeight"] = String(Double(actualFrame.height))
        }
        record(event, details: context)
    }

    /// Removes entries older than the retention period and a rotated log that
    /// has aged out entirely. Runs at most one pass at a time; concurrent calls
    /// wait for the pass in progress.
    func pruneExpiredEntries() async {
        if let pruneTask {
            await pruneTask.value
            return
        }
        let task = Task { await self.prune() }
        pruneTask = task
        await task.value
        if pruneTask == task { pruneTask = nil }
    }

    private func prune() async {
        let date = now()
        let cutoff = date.addingTimeInterval(-Self.retentionDuration)
        let mutationsAtStart = mutations
        let url = logURL
        let rotated = rotatedLogURL
        let result: (scan: PruneScan?, archiveModified: Date?) = await withCheckedContinuation { continuation in
            Self.pruneQueue.async {
                continuation.resume(returning: (
                    Self.scanRetainedEntries(at: url, cutoff: cutoff),
                    Self.modificationDate(of: rotated)
                ))
            }
        }
        if let pruneSwapDelay { await pruneSwapDelay() }
        // The files were rotated or cleared meanwhile. The scan describes a file
        // that no longer exists, and the archive may now hold fresh entries; the
        // next pass sees the new files.
        guard mutationsAtStart == mutations else { return }
        let scan = result.scan
        // Deleting the archive here, on the main actor, cannot race a rotation.
        if let archiveModified = result.archiveModified, archiveModified < cutoff {
            try? FileManager.default.removeItem(at: rotated)
        }
        if let scan, scan.removedEntry {
            closeHandle()
            do {
                var retained = scan.retained
                // Lines appended during the scan are newer than anything scanned.
                if let tail = try Self.readTail(of: url, from: scan.scannedBytes) { retained.append(tail) }
                try Self.replaceLog(at: url, with: retained)
                fileSize = retained.count
            } catch {
                NSLog("Stagehand diagnostic log retention failed: %@", error.localizedDescription)
            }
        }
        nextPruneDate = max(
            (scan?.oldestRetainedDate ?? date).addingTimeInterval(Self.retentionDuration),
            date.addingTimeInterval(Self.minimumPruneInterval)
        )
    }

    private func appendHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // O_APPEND makes every write land at the current end even if another
        // handle or a prune touched the file; the mode applies only on creation.
        let descriptor = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.posixError() }
        // Logs written by earlier versions were world-readable.
        _ = fchmod(descriptor, 0o600)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fileSize = Int((try? handle.seekToEnd()) ?? 0)
        self.handle = handle
        return handle
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func rotate() {
        closeHandle()
        do {
            if FileManager.default.fileExists(atPath: rotatedLogURL.path) {
                try FileManager.default.removeItem(at: rotatedLogURL)
            }
            try FileManager.default.moveItem(at: logURL, to: rotatedLogURL)
            mutations += 1
            fileSize = 0
        } catch {
            NSLog("Stagehand diagnostic log rotation failed: %@", error.localizedDescription)
        }
    }

    private struct PruneScan: Sendable {
        var retained: Data
        /// Bytes of the file covered by the scan, ending at a newline.
        var scannedBytes: Int
        var removedEntry: Bool
        var oldestRetainedDate: Date?
    }

    /// Reads the log on the calling (background) queue. Nil when there is no file.
    nonisolated private static func scanRetainedEntries(at url: URL, cutoff: Date) -> PruneScan? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        // A write in progress may have left a partial last line; leave it for the tail merge.
        let scannedBytes = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        var scan = PruneScan(retained: Data(), scannedBytes: scannedBytes, removedEntry: false)
        scan.retained.reserveCapacity(scannedBytes)
        for line in data[..<scannedBytes].split(separator: 0x0A) {
            guard
                let entry = try? decoder.decode(TimestampedEntry.self, from: line),
                let timestamp = try? Date(entry.timestamp, strategy: .iso8601),
                timestamp > cutoff
            else {
                scan.removedEntry = true
                continue
            }
            scan.retained.append(contentsOf: line)
            scan.retained.append(0x0A)
            scan.oldestRetainedDate = min(scan.oldestRetainedDate ?? timestamp, timestamp)
        }
        return scan
    }

    nonisolated private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func readTail(of url: URL, from offset: Int) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.readToEnd()
    }

    /// Writes to a private temporary file in the same directory, then renames it
    /// over the log so readers never see a half-written file.
    private static func replaceLog(at url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).prune-\(getpid())")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    nonisolated private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private struct Entry: Encodable {
        let timestamp: String
        let event: String
        let details: [String: String]
    }

    private struct TimestampedEntry: Decodable {
        let timestamp: String
    }
}
