import Foundation
import Testing
@testable import Stagehand

/// Each prune reads, decodes, and atomically replaces the whole log on the main
/// thread (about 100 ms for a day of navigation). Once the log covered 24 hours,
/// the oldest entry expired seconds after every prune, so nearly every write pruned.
@MainActor
@Test func steadyLoggingPrunesTheLogAtMostOncePerInterval() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let logURL = directory.appendingPathComponent("stagehand.log")
    var now = Date(timeIntervalSince1970: 1_000_000)
    let logger = DiagnosticLogger(logURL: logURL, enabled: true, now: { now })
    func fileNumber() throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? Int)
    }

    for _ in 0..<60 {
        logger.record("yesterday")
        now += 1
    }
    now += 24 * 60 * 60 - 60
    var replacements = 0
    var previous = try fileNumber()
    for _ in 0..<60 {
        logger.record("today")
        now += 1
        let current = try fileNumber()
        if current != previous { replacements += 1 }
        previous = current
    }

    #expect(replacements <= 1)
    // Expired entries are still removed once the interval passes.
    now += 2 * 60 * 60
    logger.record("later")
    let contents = try String(contentsOf: logURL, encoding: .utf8)
    #expect(!contents.contains("\"yesterday\""))
    #expect(contents.contains("\"today\""))
}
