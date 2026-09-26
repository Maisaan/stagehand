import Foundation
import CoreGraphics

/// Original external window frames written before Stagehand first moves each window.
struct WindowRecoveryRecord: Codable, Equatable {
    let windowID: String
    let bundleIdentifier: String
    let pid: Int32
    let launchDate: Date
    let ownerPID: Int32
    let ownerLaunchDate: Date
    let windowNumber: UInt32
    let frame: CGRect

    var isValid: Bool {
        pid > 0 && windowNumber > 0 && ownerPID > 0 &&
        windowID == "\(pid):\(windowNumber)" && !bundleIdentifier.isEmpty &&
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
        abs(frame.minX) < 100_000 && abs(frame.minY) < 100_000 &&
        frame.width > 0 && frame.height > 0 && frame.width < 100_000 && frame.height < 100_000
    }

    func matchesProcess(bundleIdentifier: String?, pid: Int32, launchDate: Date?) -> Bool {
        isValid && self.bundleIdentifier == bundleIdentifier && self.pid == pid &&
        self.launchDate == launchDate
    }

    func isOwnedByProcess(pid: Int32, launchDate: Date?) -> Bool {
        ownerPID == pid && ownerLaunchDate == launchDate
    }
}

final class WindowRecoveryJournal {
    enum JournalError: Error { case invalidRecord }
    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Stagehand/window-recovery.json")
    }

    private(set) var records: [String: WindowRecoveryRecord] = [:]
    private let url: URL

    init(url: URL = WindowRecoveryJournal.defaultURL) {
        self.url = url
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([WindowRecoveryRecord].self, from: data) else { return }
        for record in decoded where record.isValid {
            records[record.windowID] = record
        }
    }

    func save(_ record: WindowRecoveryRecord) throws {
        guard record.isValid else { throw JournalError.invalidRecord }
        guard records[record.windowID] == nil else { return }
        var updated = records
        updated[record.windowID] = record
        try write(updated)
        records = updated
    }

    func remove(windowID: String) throws {
        guard records[windowID] != nil else { return }
        var updated = records
        updated.removeValue(forKey: windowID)
        try write(updated)
        records = updated
    }

    private func write(_ records: [String: WindowRecoveryRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(records.values)).write(to: url, options: .atomic)
    }
}
