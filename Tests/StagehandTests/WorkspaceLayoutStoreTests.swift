import Foundation
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

private func record(_ id: String, pid: Int32) -> WindowRecord {
    WindowRecord(id: id, appName: "App", title: id, bundleIdentifier: "test.app", pid: pid,
                 frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
}

private struct StoreFixture {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("workspace-layout.json")
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct WorkspaceLayoutStoreTests {
    @Test func aCorruptFileIsMovedAsideInsteadOfBeingOverwritten() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: fixture.url)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in Date(timeIntervalSinceReferenceDate: 1) })

        let result = store.load(windows: [record("a", pid: 1)])

        guard case .unavailable(let reason) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(reason.hasPrefix("unreadable moved_aside=workspace-layout.unreadable-"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        let preserved = try #require(fixture.files().first { $0.hasPrefix("workspace-layout.unreadable-") })
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent(preserved), encoding: .utf8) == "{not json")

        // A later save writes a fresh file next to the preserved one.
        try store.save(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")]),
                       windows: [record("a", pid: 1)])
        #expect(fixture.files().count == 2)
        #expect(store.load(windows: [record("a", pid: 1)]) ==
                .restored(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")])))
    }

    @Test func aFileFromAnotherVersionIsMovedAside() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in launchDate })
        try store.save(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")]),
                       windows: [record("a", pid: 1)])
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        #expect(object["version"] as? Int == WorkspaceLayoutStore.currentVersion)
        object["version"] = WorkspaceLayoutStore.currentVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.url)

        let result = store.load(windows: [record("a", pid: 1)])

        #expect(result == .unavailable(reason: "version_\(WorkspaceLayoutStore.currentVersion + 1)_unsupported moved_aside=\(store.unreadableURL().lastPathComponent)"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(fixture.files().contains { $0.hasPrefix("workspace-layout.unreadable-") })
    }

    @Test func savingDropsThePausedFlagAndWindowsWithoutALaunchDate() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { $0 == 1 ? launchDate : nil })
        var paused = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b"], focusedWindowID: "b")])
        paused.isPaused = true

        try store.save(paused, windows: [record("a", pid: 1), record("b", pid: 2)])
        let result = store.load(windows: [record("a", pid: 1), record("b", pid: 2)])

        guard case .restored(let restored) = result else {
            Issue.record("expected restored, got \(result)")
            return
        }
        #expect(!restored.isPaused)
        #expect(restored.spaces[0].windowIDs == ["a"])
    }

    @Test func aRelaunchedProcessDoesNotRestoreItsOldWindows() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let saving = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in launchDate })
        try saving.save(WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b"], focusedWindowID: "a")]),
                        windows: [record("a", pid: 1), record("b", pid: 2)])

        // Process 2 relaunched: same window ID, later launch date.
        let loading = WorkspaceLayoutStore(url: fixture.url, launchDate: {
            $0 == 2 ? launchDate.addingTimeInterval(5) : launchDate
        })
        #expect(loading.load(windows: [record("a", pid: 1), record("b", pid: 2)]) ==
                .restored(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")])))

        let allRelaunched = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in launchDate.addingTimeInterval(5) })
        #expect(allRelaunched.load(windows: [record("a", pid: 1), record("b", pid: 2)]) ==
                .unavailable(reason: "no_surviving_windows saved=2 discovered=2"))
        // The file is intact for a process that is still running.
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test func aSaveFailureIsThrownToTheCaller() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let blocker = fixture.directory.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let store = WorkspaceLayoutStore(url: blocker.appendingPathComponent("workspace-layout.json"),
                                         launchDate: { _ in Date() })
        #expect(throws: (any Error).self) {
            try store.save(WorkspaceState(), windows: [record("a", pid: 1)])
        }
    }
}
