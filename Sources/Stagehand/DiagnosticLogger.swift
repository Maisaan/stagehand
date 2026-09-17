import Foundation

@MainActor
final class DiagnosticLogger {
    static let preferenceKey = "diagnosticLoggingEnabled"
    private static let retentionDuration: TimeInterval = 24 * 60 * 60

    static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/Stagehand/stagehand.log")
    }

    var isEnabled: Bool {
        didSet { if !isEnabled { closeHandle() } }
    }
    let logURL: URL

    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var handle: FileHandle?
    private var nextPruneDate: Date?

    init(logURL: URL = DiagnosticLogger.defaultLogURL, enabled: Bool, now: @escaping () -> Date = Date.init) {
        self.logURL = logURL
        isEnabled = enabled
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try pruneExpiredEntries(at: now())
        } catch {
            NSLog("Stagehand diagnostic log retention failed: %@", error.localizedDescription)
        }
    }

    func record(_ event: String, details: @autoclosure () -> [String: String] = [:]) {
        guard isEnabled else { return }
        let timestamp = now()
        let entry = Entry(
            timestamp: timestamp.ISO8601Format(.init(includingFractionalSeconds: true)),
            event: event,
            details: details()
        )
        do {
            try pruneExpiredEntries(at: timestamp)
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try appendHandle().write(contentsOf: data)
            schedulePrune(for: timestamp)
        } catch {
            closeHandle()
            NSLog("Stagehand diagnostic log write failed: %@", error.localizedDescription)
        }
    }

    func clear() {
        closeHandle()
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: logURL)
        } catch {
            NSLog("Stagehand diagnostic log clear failed: %@", error.localizedDescription)
        }
    }

    func recordWindowGeometry(
        event: String,
        appName: String?,
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
        if let appName { context["appName"] = appName }
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

    private func appendHandle() throws -> FileHandle {
        if let handle { return handle }
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func pruneExpiredEntries(at date: Date) throws {
        if let nextPruneDate, date < nextPruneDate { return }

        closeHandle()
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            nextPruneDate = date.addingTimeInterval(Self.retentionDuration)
            return
        }

        let cutoff = date.addingTimeInterval(-Self.retentionDuration)
        let data = try Data(contentsOf: logURL)
        var retained = Data()
        var oldestRetainedDate: Date?
        var removedEntry = false

        for line in data.split(separator: 0x0A) {
            guard
                let entry = try? decoder.decode(TimestampedEntry.self, from: line),
                let timestamp = try? Date(entry.timestamp, strategy: .iso8601),
                timestamp > cutoff
            else {
                removedEntry = true
                continue
            }

            retained.append(contentsOf: line)
            retained.append(0x0A)
            oldestRetainedDate = min(oldestRetainedDate ?? timestamp, timestamp)
        }

        if removedEntry {
            try retained.write(to: logURL, options: .atomic)
        }
        nextPruneDate = (oldestRetainedDate ?? date).addingTimeInterval(Self.retentionDuration)
    }

    private func schedulePrune(for timestamp: Date) {
        let expiration = timestamp.addingTimeInterval(Self.retentionDuration)
        nextPruneDate = min(nextPruneDate ?? expiration, expiration)
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
