import Foundation

@MainActor
final class DiagnosticLogger {
    static let preferenceKey = "diagnosticLoggingEnabled"

    static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Logs/Stagehand/stagehand.log")
    }

    var isEnabled: Bool
    let logURL: URL

    private let now: () -> Date

    init(logURL: URL = DiagnosticLogger.defaultLogURL, enabled: Bool, now: @escaping () -> Date = Date.init) {
        self.logURL = logURL
        isEnabled = enabled
        self.now = now
    }

    func record(_ event: String, details: [String: String] = [:]) {
        guard isEnabled else { return }
        let entry = Entry(timestamp: now().ISO8601Format(), event: event, details: details)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            var data = try encoder.encode(entry)
            data.append(0x0A)
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
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("Stagehand diagnostic log write failed: %@", error.localizedDescription)
        }
    }

    func recordWindowGeometry(
        event: String,
        appName: String?,
        bundleIdentifier: String?,
        pid: Int32?,
        windowID: String,
        requestedFrame: CGRect,
        actualFrame: CGRect?,
        details: [String: String] = [:]
    ) {
        var context = details
        context["windowID"] = windowID
        context["requestedX"] = String(Double(requestedFrame.minX))
        context["requestedY"] = String(Double(requestedFrame.minY))
        context["requestedWidth"] = String(Double(requestedFrame.width))
        context["requestedHeight"] = String(Double(requestedFrame.height))
        context["actualFrameAvailable"] = String(actualFrame != nil)
        if let appName { context["appName"] = appName }
        if let bundleIdentifier { context["bundleIdentifier"] = bundleIdentifier }
        if let pid { context["pid"] = String(pid) }
        if let actualFrame {
            context["actualX"] = String(Double(actualFrame.minX))
            context["actualY"] = String(Double(actualFrame.minY))
            context["actualWidth"] = String(Double(actualFrame.width))
            context["actualHeight"] = String(Double(actualFrame.height))
        }
        record(event, details: context)
    }

    private struct Entry: Encodable {
        let timestamp: String
        let event: String
        let details: [String: String]
    }
}
