import CoreGraphics
import Foundation
import Testing
@testable import StagehandPlatform

@Test func windowRecoveryJournalKeepsTheFirstFrameAcrossRestarts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("window-recovery.json")
    let launchDate = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WindowRecoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: launchDate, ownerPID: 99, ownerLaunchDate: launchDate, windowNumber: 17,
        frame: CGRect(x: 10, y: 20, width: 300, height: 200)
    )
    let journal = WindowRecoveryJournal(url: url)
    try journal.save(original)
    let second = WindowRecoveryRecord(
        windowID: "42:18", bundleIdentifier: "example.app", pid: 42,
        launchDate: launchDate, ownerPID: 99, ownerLaunchDate: launchDate, windowNumber: 18,
        frame: CGRect(x: 50, y: 60, width: 400, height: 300)
    )
    try journal.save(second)
    try journal.save(WindowRecoveryRecord(
        windowID: original.windowID, bundleIdentifier: original.bundleIdentifier,
        pid: original.pid, launchDate: launchDate,
        ownerPID: 99, ownerLaunchDate: launchDate, windowNumber: 17,
        frame: CGRect(x: -500, y: 20, width: 300, height: 200)
    ))

    let relaunched = WindowRecoveryJournal(url: url)
    #expect(relaunched.records[original.windowID] == original)
    #expect(original.matchesProcess(bundleIdentifier: "example.app", pid: 42,
                                    launchDate: launchDate))
    #expect(!original.matchesProcess(bundleIdentifier: "example.app", pid: 42,
                                     launchDate: launchDate.addingTimeInterval(1)))
    #expect(!original.matchesProcess(bundleIdentifier: "other.app", pid: 42,
                                     launchDate: launchDate))
    #expect(!original.matchesProcess(bundleIdentifier: "example.app", pid: 43,
                                     launchDate: launchDate))
    #expect(original.isOwnedByProcess(pid: 99, launchDate: launchDate))
    #expect(!original.isOwnedByProcess(pid: 99, launchDate: launchDate.addingTimeInterval(1)))
    try relaunched.remove(windowID: original.windowID)
    #expect(WindowRecoveryJournal(url: url).records == [second.windowID: second])
}

@Test func windowRecoveryJournalRejectsMalformedAndUnidentifiedFrames() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("window-recovery.json")
    try Data("invalid JSON".utf8).write(to: url)
    #expect(WindowRecoveryJournal(url: url).records.isEmpty)

    let invalid = WindowRecoveryRecord(
        windowID: "42:fallback:1", bundleIdentifier: "example.app", pid: 42,
        launchDate: Date(), ownerPID: 99, ownerLaunchDate: Date(), windowNumber: 17,
        frame: CGRect(x: 0, y: 0, width: 0, height: 100)
    )
    #expect(throws: WindowRecoveryJournal.JournalError.self) {
        try WindowRecoveryJournal(url: url).save(invalid)
    }
    #expect(WindowRecoveryJournal(url: url).records.isEmpty)

    let extreme = WindowRecoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: Date(), ownerPID: 99, ownerLaunchDate: Date(), windowNumber: 17,
        frame: CGRect(x: 1_000_000, y: 0, width: 100, height: 100)
    )
    try JSONEncoder().encode([extreme]).write(to: url)
    #expect(WindowRecoveryJournal(url: url).records.isEmpty)
}
