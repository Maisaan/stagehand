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

    /// The window ID is the tracking key. It is normally "pid:windowNumber", but a
    /// window first seen before WindowServer reported its number keeps its
    /// "pid:fallback:N" key for life, so only the pid prefix is required here.
    /// Recovery locates the window through `windowNumber`, never through the key.
    var isValid: Bool {
        pid > 0 && windowNumber > 0 && ownerPID > 0 &&
        (windowID == "\(pid):\(windowNumber)" || windowID.hasPrefix("\(pid):fallback:")) &&
        !bundleIdentifier.isEmpty &&
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
        abs(frame.minX) < WindowTuning.recoveryFrameBound && abs(frame.minY) < WindowTuning.recoveryFrameBound &&
        frame.width > 0 && frame.height > 0 &&
        frame.width < WindowTuning.recoveryFrameBound && frame.height < WindowTuning.recoveryFrameBound
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
    enum JournalError: Error, Equatable {
        case invalidRecord
        /// The on-disk journal could not be read or set aside. Saving would overwrite
        /// the only copy of frames an earlier session may have left displaced.
        case unreadable(String)
        /// No per-user Application Support directory. A journal in a temporary
        /// directory would not survive to the next launch, so refuse instead.
        case noStorage
    }

    /// Unreadable journals set aside for manual recovery. Older copies are deleted
    /// once this many exist, so a repeatedly corrupt file cannot fill the disk.
    static let quarantineLimit = 5
    static let quarantinePrefix = "window-recovery.unreadable-"

    static var defaultURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Stagehand/window-recovery.json")
    }

    private(set) var records: [String: WindowRecoveryRecord] = [:]
    /// Set when the journal cannot be trusted. `save` throws until the process restarts.
    private(set) var failure: JournalError?
    private let url: URL?

    convenience init() {
        self.init(url: WindowRecoveryJournal.defaultURL)
    }

    init(url: URL?) {
        self.url = url
        guard let url else {
            failure = .noStorage
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == ENOENT {
            return
        } catch {
            failure = .unreadable(error.localizedDescription)
            return
        }
        // Decode each record on its own so one unreadable entry cannot discard the rest.
        guard let decoded = try? JSONDecoder().decode([LossyRecord].self, from: data) else {
            // This file may hold the only copy of displaced frames. Keep it for manual
            // recovery instead of letting the next save overwrite it.
            let preserved = url.deletingLastPathComponent().appendingPathComponent(
                "\(Self.quarantinePrefix)\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            )
            do {
                try FileManager.default.moveItem(at: url, to: preserved)
            } catch {
                failure = .unreadable(error.localizedDescription)
                return
            }
            Self.pruneQuarantine(in: url.deletingLastPathComponent())
            return
        }
        for record in decoded.compactMap(\.record) where record.isValid {
            records[record.windowID] = record
        }
    }

    private struct LossyRecord: Decodable {
        let record: WindowRecoveryRecord?
        init(from decoder: any Decoder) throws {
            record = try? WindowRecoveryRecord(from: decoder)
        }
    }

    func save(_ record: WindowRecoveryRecord) throws {
        guard record.isValid else { throw JournalError.invalidRecord }
        if let failure { throw failure }
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
        guard let url else { throw JournalError.noStorage }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Array(records.values))
        // Write through a sibling with owner-only permissions, then swap it in so the
        // journal is never observed half-written and never world-readable.
        let staging = directory.appendingPathComponent(".window-recovery.\(ProcessInfo.processInfo.processIdentifier).tmp")
        guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Keeps the newest `quarantineLimit` set-aside journals, by name, which embeds the time.
    private static func pruneQuarantine(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let quarantined = names.filter { $0.hasPrefix(quarantinePrefix) && $0.hasSuffix(".json") }.sorted()
        guard quarantined.count > quarantineLimit else { return }
        for name in quarantined.prefix(quarantined.count - quarantineLimit) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
