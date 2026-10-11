import Foundation
import Testing
@testable import Stagehand

@MainActor
private struct LogFixture {
    let directory: URL
    let logURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        logURL = directory.appendingPathComponent("stagehand.log")
    }

    func contents() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    func fileNumber() throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? Int)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Each prune reads, decodes, and replaces the whole log. That used to happen on
/// the main thread from record(), and once the log covered 24 hours nearly every
/// write pruned. Writes are now plain appends; pruning is a separate pass.
@MainActor
@Test func recordingAppendsWithoutRewritingAndPruningRemovesOnlyExpiredEntries() async throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true, now: { now })

    for _ in 0..<60 {
        logger.record("yesterday")
        now += 1
    }
    now += 24 * 60 * 60 - 60
    let before = try fixture.fileNumber()
    for _ in 0..<60 {
        logger.record("today")
        now += 1
        #expect(try fixture.fileNumber() == before)
    }

    now += 2 * 60 * 60
    await logger.pruneExpiredEntries()
    var contents = fixture.contents()
    #expect(!contents.contains("\"yesterday\""))
    #expect(contents.contains("\"today\""))
    #expect(contents.split(separator: "\n").count == 60)

    // The handle reopens after the swap and keeps appending.
    logger.record("later")
    contents = fixture.contents()
    #expect(contents.hasSuffix("\"event\":\"later\",\"timestamp\":\"\(now.ISO8601Format(.init(includingFractionalSeconds: true)))\"}\n"))
    #expect(contents.split(separator: "\n").count == 61)
}

@MainActor
@Test func pruningRunsOnATimerWithoutNewRecords() async throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true, now: { now },
                                  pruneInterval: .milliseconds(20))
    logger.record("old")
    #expect(fixture.contents().contains("\"old\""))
    now += 25 * 60 * 60

    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while fixture.contents().contains("\"old\""), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!fixture.contents().contains("\"old\""))
    _ = logger
}

@MainActor
@Test func turningLoggingOffPrunesTheLog() async throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true, now: { now })
    logger.record("old")
    now += 25 * 60 * 60

    logger.isEnabled = false
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while fixture.contents().contains("\"old\""), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!fixture.contents().contains("\"old\""))
    logger.record("ignored")
    #expect(!fixture.contents().contains("\"ignored\""))
}

@MainActor
@Test func theLogRotatesAtTheSizeLimitAndAnAgedRotationIsRemoved() async throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true, now: { now }, rotationSize: 600)
    for index in 0..<10 {
        logger.record("entry\(index)")
        now += 1
    }

    let rotated = (try? String(contentsOf: logger.rotatedLogURL, encoding: .utf8)) ?? ""
    #expect(rotated.contains("\"entry0\""))
    #expect(!rotated.isEmpty)
    #expect(fixture.contents().contains("\"entry9\""))
    #expect(!fixture.contents().contains("\"entry0\""))
    let currentSize = try #require(FileManager.default.attributesOfItem(atPath: fixture.logURL.path)[.size] as? Int)
    #expect(currentSize < 600)

    // The rotated file is removed once everything in it has expired.
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)], ofItemAtPath: logger.rotatedLogURL.path
    )
    await logger.pruneExpiredEntries()
    #expect(!FileManager.default.fileExists(atPath: logger.rotatedLogURL.path))
}

@MainActor
@Test func theLogFileIsPrivateToTheUser() throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true)
    logger.record("first")
    let permissions = try #require(FileManager.default.attributesOfItem(atPath: fixture.logURL.path)[.posixPermissions] as? Int)
    #expect(permissions == 0o600)
}

@MainActor
@Test func writeFailuresBackOffInsteadOfRetryingEveryEvent() throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    // A regular file where the log directory should be makes every open fail.
    try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
    let blocker = fixture.directory.appendingPathComponent("blocked")
    try Data().write(to: blocker)
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: blocker.appendingPathComponent("stagehand.log"), enabled: true, now: { now })

    logger.record("one")
    logger.record("two")
    logger.record("three")
    #expect(logger.writeAttempts == 1)
    #expect(logger.writeFailures == 1)

    now += 1
    logger.record("four")
    #expect(logger.writeAttempts == 2)
    #expect(logger.writeFailures == 2)
    now += 1
    logger.record("five")
    #expect(logger.writeAttempts == 2)
    now += 1
    logger.record("six")
    #expect(logger.writeAttempts == 3)
}

@MainActor
@Test func windowGeometryIdentifiesTheAppByBundleIdentifierOnly() throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true)
    logger.recordWindowGeometry(
        event: "frame_write_constrained",
        bundleIdentifier: "com.example.editor",
        pid: 42,
        windowID: "42:7",
        requestedFrame: CGRect(x: 1, y: 2, width: 300, height: 200),
        actualFrame: CGRect(x: 1, y: 2, width: 320, height: 200)
    )
    let line = try #require(fixture.contents().split(separator: "\n").first)
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let details = try #require(object["details"] as? [String: String])
    #expect(details["bundleIdentifier"] == "com.example.editor")
    #expect(details["pid"] == "42")
    #expect(details["actualWidth"] == "320.0")
    #expect(details["appName"] == nil)
    #expect(!line.contains("appName"))
}

@MainActor
@Test func clearRemovesTheLogAndItsRotation() throws {
    let fixture = LogFixture()
    defer { fixture.remove() }
    let logger = DiagnosticLogger(logURL: fixture.logURL, enabled: true, rotationSize: 100)
    for index in 0..<4 { logger.record("entry\(index)") }
    #expect(FileManager.default.fileExists(atPath: logger.rotatedLogURL.path))
    logger.clear()
    #expect(!FileManager.default.fileExists(atPath: fixture.logURL.path))
    #expect(!FileManager.default.fileExists(atPath: logger.rotatedLogURL.path))
    logger.record("after")
    #expect(fixture.contents().contains("\"after\""))
}
