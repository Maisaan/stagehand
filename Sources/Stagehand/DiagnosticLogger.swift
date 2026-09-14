import Foundation

@MainActor
final class DiagnosticLogger {
    static let preferenceKey = "diagnosticLoggingEnabled"

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
    private var handle: FileHandle?

    init(logURL: URL = DiagnosticLogger.defaultLogURL, enabled: Bool, now: @escaping () -> Date = Date.init) {
        self.logURL = logURL
        isEnabled = enabled
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func record(_ event: String, details: @autoclosure () -> [String: String] = [:]) {
        guard isEnabled else { return }
        let entry = Entry(timestamp: now().ISO8601Format(), event: event, details: details())
        do {
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try appendHandle().write(contentsOf: data)
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

    private struct Entry: Encodable {
        let timestamp: String
        let event: String
        let details: [String: String]
    }
}
