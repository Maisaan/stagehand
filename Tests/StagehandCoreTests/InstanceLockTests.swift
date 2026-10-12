import Foundation
import Testing
@testable import StagehandCore

struct InstanceLockTests {
    @Test func aSecondHolderIsRefusedUntilTheFirstReleases() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/instance.lock")

        var first: InstanceLock? = try InstanceLock(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")

        #expect(throws: InstanceLock.Failure.held) {
            try InstanceLock(url: url)
        }

        first = nil
        let second = try InstanceLock(url: url)
        #expect(second.url == url)
    }

    @Test func anUnwritableLocationReportsTheSystemError() {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: blocker) }
        try? Data().write(to: blocker)
        #expect(throws: (any Error).self) {
            try InstanceLock(url: blocker.appendingPathComponent("instance.lock"))
        }
    }
}
