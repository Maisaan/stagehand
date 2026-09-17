import Foundation
import Testing
@testable import Stagehand

@Test @MainActor func diagnosticLoggingCapturesAutomaticPauseOnlyWhenEnabled() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticLoggingTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = DiagnosticLogger(logURL: logURL, enabled: false, now: { Date(timeIntervalSince1970: 0) })
    logger.record("automatic_pause", details: [
        "operation": "focusNext",
        "reason": "focus_confirmation_failed"
    ])
    #expect(!FileManager.default.fileExists(atPath: logURL.path))

    logger.isEnabled = true
    logger.record("automatic_pause", details: [
        "operation": "focusNext",
        "reason": "focus_confirmation_failed"
    ])
    let enabledContents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(enabledContents.contains("\"event\":\"automatic_pause\""))
    #expect(enabledContents.contains("\"operation\":\"focusNext\""))
    #expect(enabledContents.contains("\"reason\":\"focus_confirmation_failed\""))

    logger.isEnabled = false
    logger.record("automatic_pause", details: ["reason": "ribbon_position_failed"])
    #expect(try String(contentsOf: logURL, encoding: .utf8) == enabledContents)
}

@Test @MainActor func diagnosticLogTimestampsPreserveSubsecondTiming() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticTimestampTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = DiagnosticLogger(
        logURL: logURL,
        enabled: true,
        now: { Date(timeIntervalSince1970: 0.123) }
    )
    logger.record("timed_event")

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(contents.contains("\"timestamp\":\"1970-01-01T00:00:00.123Z\""))
}

@Test @MainActor func diagnosticWindowGeometryIncludesIdentityAndAcceptedFrame() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticGeometryTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = DiagnosticLogger(logURL: logURL, enabled: true, now: { Date(timeIntervalSince1970: 0) })
    logger.recordWindowGeometry(
        event: "window_size_constraint_observed",
        appName: "Example",
        bundleIdentifier: "com.example.app",
        pid: 42,
        windowID: "42:7",
        requestedFrame: CGRect(x: 100, y: 200, width: 900, height: 700),
        beforeFrame: CGRect(x: -880, y: 900, width: 840, height: 680),
        actualFrame: CGRect(x: 100, y: 200, width: 840, height: 680),
        details: ["constraintAxes": "width,height", "pass": "9"]
    )

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(contents.contains("\"event\":\"window_size_constraint_observed\""))
    #expect(contents.contains("\"appName\":\"Example\""))
    #expect(contents.contains("\"bundleIdentifier\":\"com.example.app\""))
    #expect(contents.contains("\"windowID\":\"42:7\""))
    #expect(contents.contains("\"requestedWidth\":\"900.0\""))
    #expect(contents.contains("\"beforeX\":\"-880.0\""))
    #expect(contents.contains("\"beforeY\":\"900.0\""))
    #expect(contents.contains("\"beforeFrameAvailable\":\"true\""))
    #expect(contents.contains("\"actualWidth\":\"840.0\""))
    #expect(contents.contains("\"actualFrameAvailable\":\"true\""))
}

@Test @MainActor func diagnosticLogCanBeCleared() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticClearTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    let logger = DiagnosticLogger(logURL: logURL, enabled: true)
    logger.record("started")
    #expect(FileManager.default.fileExists(atPath: logURL.path))

    logger.clear()
    #expect(!FileManager.default.fileExists(atPath: logURL.path))
    logger.clear()
}

@Test @MainActor func diagnosticLogRetainsOnlyThePrevious24Hours() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticRetentionTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    var currentDate = Date(timeIntervalSince1970: 0)
    let logger = DiagnosticLogger(logURL: logURL, enabled: true, now: { currentDate })
    logger.record("expired")

    currentDate.addTimeInterval(60 * 60)
    logger.record("at_retention_limit")

    currentDate.addTimeInterval(22 * 60 * 60)
    logger.record("retained")

    currentDate.addTimeInterval(2 * 60 * 60)
    logger.record("current")

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(!contents.contains("\"event\":\"expired\""))
    #expect(!contents.contains("\"event\":\"at_retention_limit\""))
    #expect(contents.contains("\"event\":\"retained\""))
    #expect(contents.contains("\"event\":\"current\""))
}

@Test @MainActor func diagnosticLogPrunesExpiredEntriesWhenOpened() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticStartupRetentionTests-\(UUID().uuidString)", isDirectory: true)
    let logURL = directory.appendingPathComponent("stagehand.log")
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let currentDate = Date(timeIntervalSince1970: 48 * 60 * 60)
    let retainedDate = currentDate.addingTimeInterval(-60 * 60)
    let existingLog = """
    {"details":{},"event":"expired","timestamp":"1970-01-01T00:00:00Z"}
    {"details":{},"event":"retained","timestamp":"\(retainedDate.ISO8601Format())"}

    """
    try existingLog.write(to: logURL, atomically: true, encoding: .utf8)

    _ = DiagnosticLogger(logURL: logURL, enabled: false, now: { currentDate })

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(!contents.contains("\"event\":\"expired\""))
    #expect(contents.contains("\"event\":\"retained\""))
}
