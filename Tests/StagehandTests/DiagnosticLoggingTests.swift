import Foundation
import Testing
@testable import Stagehand

@Test @MainActor func diagnosticLoggingCapturesAutomaticPauseOnlyWhenEnabled() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagehandDiagnosticLoggingTests-(UUID().uuidString)", isDirectory: true)
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
