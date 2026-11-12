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

    @Test func heightsRoundTripForSurvivingWindows() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { $0 == 1 ? launchDate : nil })
        let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b"], focusedWindowID: "a")])
        try store.save(state, windows: [record("a", pid: 1), record("b", pid: 2)],
                       preferredHeights: ["a": 640, "b": 480])

        let result = store.load(windows: [record("a", pid: 1)])

        #expect(result == .restored(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")]),
                                    preferredHeights: ["a": 640]))
    }

    @Test func aFileWithoutHeightsStillLoads() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in launchDate })
        try store.save(WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")]),
                       windows: [record("a", pid: 1)], preferredHeights: ["a": 640])
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [String: Any])
        object.removeValue(forKey: "preferredHeights")
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.url)

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

    @Test func aFlatVersionOneFileIsMovedAsideRatherThanMigrated() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let flat: [String: Any] = [
            "version": 1,
            "state": ["spaces": [["windowIDs": ["a"], "focusedWindowID": "a", "widthFractions": ["a": 0.5]]]],
            "processLaunchDates": ["a": launchDate.timeIntervalSinceReferenceDate],
            "preferredHeights": [:] as [String: Double]
        ]
        try JSONSerialization.data(withJSONObject: flat).write(to: fixture.url)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in launchDate })

        let result = store.load(windows: [record("a", pid: 1)])

        #expect(result == .unavailable(reason: "version_1_unsupported moved_aside=\(store.unreadableURL().lastPathComponent)"))
        #expect(fixture.files().contains { $0.hasPrefix("workspace-layout.unreadable-") })
    }

    @Test func stacksRoundTripAndLoseOnlyWindowsWhoseProcessEnded() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { $0 == 3 ? nil : launchDate })
        let state = WorkspaceState(spaces: [SpaceState(tiles: [
            Tile(id: "left", windowIDs: ["a", "b", "c"], widthFraction: 0.6,
                 activeWindowID: "b", heightWeights: [2, 1, 1]),
            Tile(windowIDs: ["d"])
        ], focusedWindowID: "d")])
        try store.save(state, windows: [record("a", pid: 1), record("b", pid: 2), record("c", pid: 3),
                                        record("d", pid: 1)])

        let result = store.load(windows: [record("a", pid: 1), record("b", pid: 2), record("d", pid: 1)])

        #expect(result == .restored(WorkspaceState(spaces: [SpaceState(tiles: [
            Tile(id: "left", windowIDs: ["a", "b"], widthFraction: 0.6,
                 activeWindowID: "b", heightWeights: [2, 1]),
            Tile(windowIDs: ["d"])
        ], focusedWindowID: "d")])))
    }

    @Test func aVersion2FileFromBeforeTheTileRenameRestoresAndSavesUnchanged() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let emptySpace = #"{"columns":[]}"#
        let writtenBy824312a = #"{"version":2,"state":{"isPaused":false,"activeSpaceIndex":0,"spaces":["#
            + #"{"columns":[{"id":"left","windowIDs":["a","b"],"widthFraction":0.6,"activeWindowID":"b","#
            + #""heightWeights":[2,1]},{"id":"c","windowIDs":["c"],"widthFraction":0.95,"activeWindowID":"c","#
            + #""heightWeights":[1]}],"focusedWindowID":"c"},"#
            + #"{"columns":[{"id":"b","windowIDs":["b"],"widthFraction":0.5,"activeWindowID":"b","#
            + #""heightWeights":[1]}],"focusedWindowID":"b"},"#
            + Array(repeating: emptySpace, count: 7).joined(separator: ",")
            + #"]},"processLaunchDates":{"a":1,"b":1,"c":1},"preferredHeights":{"c":640}}"#
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Data(writtenBy824312a.utf8).write(to: fixture.url)
        let store = WorkspaceLayoutStore(url: fixture.url, launchDate: { _ in Date(timeIntervalSinceReferenceDate: 1) })
        let windows = [record("a", pid: 1), record("b", pid: 2), record("c", pid: 3)]
        let expected = WorkspaceState(spaces: [
            SpaceState(tiles: [
                Tile(id: "left", windowIDs: ["a", "b"], widthFraction: 0.6, activeWindowID: "b", heightWeights: [2, 1]),
                Tile(windowIDs: ["c"])
            ], focusedWindowID: "c"),
            SpaceState(tiles: [Tile(windowIDs: ["b"], widthFraction: 0.5)], focusedWindowID: "b")
        ])

        #expect(store.load(windows: windows) == .restored(expected, preferredHeights: ["c": 640]))

        try store.save(expected, windows: windows, preferredHeights: ["c": 640])
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(writtenBy824312a.utf8)) as? NSDictionary
        #expect(saved == original)
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

        guard case .restored(let restored, _) = result else {
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
