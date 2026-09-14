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
        actualFrame: CGRect(x: 100, y: 200, width: 840, height: 680),
        details: ["constraintAxes": "width,height", "pass": "9"]
    )

    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(contents.contains("\"event\":\"window_size_constraint_observed\""))
    #expect(contents.contains("\"appName\":\"Example\""))
    #expect(contents.contains("\"bundleIdentifier\":\"com.example.app\""))
    #expect(contents.contains("\"windowID\":\"42:7\""))
    #expect(contents.contains("\"requestedWidth\":\"900.0\""))
    #expect(contents.contains("\"actualWidth\":\"840.0\""))
    #expect(contents.contains("\"actualFrameAvailable\":\"true\""))
}
