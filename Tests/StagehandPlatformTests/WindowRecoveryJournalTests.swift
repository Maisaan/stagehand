import ApplicationServices
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
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: Date(), ownerPID: 99, ownerLaunchDate: Date(), windowNumber: 17,
        frame: CGRect(x: 0, y: 0, width: 0, height: 100)
    )
    #expect(throws: WindowRecoveryJournal.JournalError.self) {
        try WindowRecoveryJournal(url: url).save(invalid)
    }
    let otherProcessKey = WindowRecoveryRecord(
        windowID: "43:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: Date(), ownerPID: 99, ownerLaunchDate: Date(), windowNumber: 17,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
    #expect(throws: WindowRecoveryJournal.JournalError.self) {
        try WindowRecoveryJournal(url: url).save(otherProcessKey)
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

/// The journal holds the only copy of frames a crash left displaced. One record
/// from another version must not discard the rest, and an unreadable file must
/// not be overwritten by the next save.
@Test func windowRecoveryJournalKeepsReadableRecordsAndPreservesAnUnreadableFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("window-recovery.json")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let valid = WindowRecoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, windowNumber: 17,
        frame: CGRect(x: 10, y: 20, width: 300, height: 200)
    )
    let validJSON = String(decoding: try JSONEncoder().encode(valid), as: UTF8.self)
    try Data("[\(validJSON), {\"windowID\": \"43:1\", \"futureField\": true}]".utf8).write(to: url)
    #expect(WindowRecoveryJournal(url: url).records == [valid.windowID: valid])

    try Data("{ truncated".utf8).write(to: url)
    let journal = WindowRecoveryJournal(url: url)
    try journal.save(valid)
    let preserved = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("window-recovery.unreadable") }
    #expect(preserved.count == 1)
    #expect(WindowRecoveryJournal(url: url).records == [valid.windowID: valid])
}

/// A window tracked before WindowServer reported its number keeps its fallback
/// key. Its record must still be writable once the number is known, or the window
/// could never be managed.
@Test func windowRecoveryJournalAcceptsAFallbackKeyOnceTheWindowNumberIsKnown() throws {
    let (directory, url, _) = try journalFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let fallback = WindowRecoveryRecord(
        windowID: "42:fallback:3", bundleIdentifier: "example.app", pid: 42,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, windowNumber: 17,
        frame: CGRect(x: 10, y: 20, width: 300, height: 200)
    )
    try WindowRecoveryJournal(url: url).save(fallback)
    #expect(WindowRecoveryJournal(url: url).records == [fallback.windowID: fallback])
}

@Test func recoveryRecordRequiresEveryIdentityBeforeAWindowIsMoved() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
    let complete = WindowSystem.recoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42, windowNumber: 17,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, frame: frame
    )
    #expect(complete?.windowID == "42:17")
    #expect(complete?.isValid == true)
    #expect(WindowSystem.recoveryRecord(
        windowID: "42:fallback:1", bundleIdentifier: "example.app", pid: 42, windowNumber: nil,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, frame: frame
    ) == nil)
    #expect(WindowSystem.recoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42, windowNumber: 17,
        launchDate: nil, ownerPID: 99, ownerLaunchDate: date, frame: frame
    ) == nil)
    #expect(WindowSystem.recoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42, windowNumber: 17,
        launchDate: date, ownerPID: 99, ownerLaunchDate: nil, frame: frame
    ) == nil)
    #expect(WindowSystem.recoveryRecord(
        windowID: "42:17", bundleIdentifier: "", pid: 42, windowNumber: 17,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, frame: frame
    ) == nil)
    #expect(WindowSystem.recoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42, windowNumber: 17,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, frame: CGRect(x: 0, y: 0, width: 0, height: 10)
    ) == nil)
}

/// Without _AXUIElementGetWindow every identity lookup is nil. The second
/// recovery inventory must not read that as "every journaled window closed" and
/// delete the journal.
@Test func recoverySearchDistinguishesAbsentFromUnidentifiable() {
    let first = AXUIElementCreateApplication(1)
    let second = AXUIElementCreateApplication(2)
    let elements = [first, second]
    switch WindowSystem.recoveryMatch(elements, numbers: [5, 7], target: 7, identityAvailable: true) {
    case .found(let element): #expect(CFEqual(element, second))
    default: Issue.record("Expected the element whose number matched")
    }
    switch WindowSystem.recoveryMatch(elements, numbers: [5, 7], target: 9, identityAvailable: true) {
    case .absent: break
    default: Issue.record("A number missing from a readable list means the window closed")
    }
    switch WindowSystem.recoveryMatch(elements, numbers: [nil, nil], target: 7, identityAvailable: false) {
    case .unavailable: break
    default: Issue.record("Nil identities from a missing symbol must keep the record")
    }
    switch WindowSystem.recoveryMatch([], numbers: [], target: 7, identityAvailable: false) {
    case .unavailable: break
    default: Issue.record("An empty list is still not evidence without identities")
    }
}

/// Accessibility lists only the current Space's windows, so a window in native full
/// screen is missing from its app's list. It read as "maybe published late" and blocked
/// every Start until the app quit (1Password, 2026-10-26). WindowServer's Space types tell
/// it apart: only a window on full-screen Spaces alone is macOS's.
@Test func aWindowMissingBecauseItIsInFullScreenIsNotAbsent() {
    let elements = [AXUIElementCreateApplication(1)]
    func search(_ types: [Int32]?) -> WindowSystem.RecoverySearch {
        WindowSystem.recoveryMatch(elements, numbers: [5], target: 9, identityAvailable: true,
                                   targetSpaceTypes: { types })
    }
    if case .fullScreen = search([NativeSpaces.fullScreenSpaceType]) {} else { Issue.record("Full screen") }
    if case .absent = search([0]) {} else { Issue.record("A window on another Desktop stays absent") }
    if case .absent = search([0, NativeSpaces.fullScreenSpaceType]) {} else { Issue.record("Not only full screen") }
    if case .absent = search([]) {} else { Issue.record("A window WindowServer does not have is absent") }
    if case .absent = search(nil) {} else { Issue.record("No answer is not evidence of full screen") }

    var asked = false
    _ = WindowSystem.recoveryMatch(elements, numbers: [9], target: 9, identityAvailable: true,
                                   targetSpaceTypes: { asked = true; return nil })
    #expect(!asked)
    // A window that does not exist is on no Space.
    #expect(!NativeSpaces.isInFullScreen(spaceTypes: NativeSpaces.spaceTypes(UInt32.max)))
}

private func journalFixture() throws -> (directory: URL, url: URL, record: WindowRecoveryRecord) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let record = WindowRecoveryRecord(
        windowID: "42:17", bundleIdentifier: "example.app", pid: 42,
        launchDate: date, ownerPID: 99, ownerLaunchDate: date, windowNumber: 17,
        frame: CGRect(x: 10, y: 20, width: 300, height: 200)
    )
    return (directory, directory.appendingPathComponent("window-recovery.json"), record)
}

/// A read error other than "no such file" could hide displaced frames, so the
/// journal refuses to save over the file it could not read.
@Test func windowRecoveryJournalRefusesToSaveAfterAReadErrorOtherThanMissingFile() throws {
    let (directory, url, record) = try journalFixture()
    defer { try? FileManager.default.removeItem(at: directory) }

    let missing = WindowRecoveryJournal(url: url)
    #expect(missing.failure == nil)
    try missing.save(record)
    #expect(WindowRecoveryJournal(url: url).records == [record.windowID: record])

    // A directory where the file should be cannot be read, and is not "no file".
    let blocked = directory.appendingPathComponent("blocked.json")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    let journal = WindowRecoveryJournal(url: blocked)
    #expect(journal.failure != nil)
    #expect(throws: WindowRecoveryJournal.JournalError.self) { try journal.save(record) }
    #expect(journal.records.isEmpty)
}

@Test func windowRecoveryJournalRefusesToSaveWhenAnUnreadableFileCannotBeSetAside() throws {
    let (directory, url, record) = try journalFixture()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    try Data("{ truncated".utf8).write(to: url)
    // A read-only directory refuses the quarantine move.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    let journal = WindowRecoveryJournal(url: url)
    #expect(journal.failure != nil)
    #expect(throws: WindowRecoveryJournal.JournalError.self) { try journal.save(record) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try Data(contentsOf: url) == Data("{ truncated".utf8))
}

@Test func windowRecoveryJournalKeepsOnlyTheNewestQuarantinedFiles() throws {
    let (directory, url, record) = try journalFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    for index in 0..<WindowRecoveryJournal.quarantineLimit + 2 {
        let name = "\(WindowRecoveryJournal.quarantinePrefix)\(1_000_000 + index)-old.json"
        try Data("old".utf8).write(to: directory.appendingPathComponent(name))
    }
    try Data("{ truncated".utf8).write(to: url)
    let journal = WindowRecoveryJournal(url: url)
    #expect(journal.failure == nil)
    try journal.save(record)
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(WindowRecoveryJournal.quarantinePrefix) }.sorted()
    #expect(quarantined.count == WindowRecoveryJournal.quarantineLimit)
    let newest = try #require(quarantined.last)
    #expect(try Data(contentsOf: directory.appendingPathComponent(newest)) == Data("{ truncated".utf8))
    #expect(!quarantined.contains("\(WindowRecoveryJournal.quarantinePrefix)1000000-old.json"))
}

@Test func windowRecoveryJournalIsOwnerReadableOnlyAndNeedsApplicationSupport() throws {
    let (directory, url, record) = try journalFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try WindowRecoveryJournal(url: url).save(record)
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    try WindowRecoveryJournal(url: url).remove(windowID: record.windowID)
    let afterRemove = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(afterRemove == 0o600)

    let unavailable = WindowRecoveryJournal(url: nil)
    #expect(unavailable.failure == .noStorage)
    #expect(throws: WindowRecoveryJournal.JournalError.self) { try unavailable.save(record) }
}
