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

    private struct Entry: Encodable {
        let timestamp: String
        let event: String
        let details: [String: String]
    }
}
