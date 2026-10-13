import AppKit
import StagehandCore
import StagehandPlatform

/// Saves the ribbon layout so a relaunched Stagehand can return windows to their
/// spaces, order, and widths. Window IDs combine a process ID and a WindowServer
/// window number, so a saved window is restored only while the same process,
/// identified by its launch date, is still running.
struct WorkspaceLayoutStore {
    /// Bump when the file's meaning changes. A file from another version is set
    /// aside rather than guessed at.
    static let currentVersion = 1

    private struct SavedLayout: Codable {
        var version: Int
        var state: WorkspaceState
        var processLaunchDates: [String: Date]

        init(version: Int, state: WorkspaceState, processLaunchDates: [String: Date]) {
            self.version = version
            self.state = state
            self.processLaunchDates = processLaunchDates
        }

        /// Files written before the version field existed are version 1.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            state = try container.decode(WorkspaceState.self, forKey: .state)
            processLaunchDates = try container.decode([String: Date].self, forKey: .processLaunchDates)
        }
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Stagehand/workspace-layout.json")
    }

    let url: URL
    let launchDate: (Int32) -> Date?

    init(url: URL = WorkspaceLayoutStore.defaultURL,
         launchDate: @escaping (Int32) -> Date? = { ProcessLaunchDate.launchDate(pid: $0) }) {
        self.url = url
        self.launchDate = launchDate
    }

    /// Saves memberships of windows whose process can be identified later.
    /// Throws on an encoding or file error; the caller records it.
    func save(_ state: WorkspaceState, windows: [WindowRecord]) throws {
        var launchDates: [String: Date] = [:]
        for window in windows {
            if let date = launchDate(window.pid) { launchDates[window.id] = date }
        }
        var saved = state
        saved.isPaused = false
        saved.reconcile(windowIDs: saved.spaces.flatMap(\.windowIDs).filter { launchDates[$0] != nil })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(
            SavedLayout(version: Self.currentVersion, state: saved, processLaunchDates: launchDates)
        )
        try data.write(to: url, options: .atomic)
    }

    enum LoadResult: Equatable {
        case restored(WorkspaceState)
        case unavailable(reason: String)
    }

    /// The saved layout, limited to windows whose process is still running.
    /// A file that cannot be decoded, or was written by another version, is moved
    /// to workspace-layout.unreadable-<timestamp>.json so the next save does not
    /// destroy the only copy.
    func load(windows: [WindowRecord]) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .unavailable(reason: "no_saved_layout") }
        guard let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) else {
            return .unavailable(reason: setAside(because: "unreadable"))
        }
        guard saved.version == Self.currentVersion else {
            return .unavailable(reason: setAside(because: "version_\(saved.version)_unsupported"))
        }
        let pids = Dictionary(windows.map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
        let survivingIDs = saved.state.spaces.flatMap(\.windowIDs).filter { id in
            guard let pid = pids[id], let savedDate = saved.processLaunchDates[id] else { return false }
            return launchDate(pid) == savedDate
        }
        guard !survivingIDs.isEmpty else {
            let savedCount = Set(saved.state.spaces.flatMap(\.windowIDs)).count
            let discovered = saved.state.spaces.flatMap(\.windowIDs).filter { pids[$0] != nil }.count
            return .unavailable(reason: "no_surviving_windows saved=\(savedCount) discovered=\(discovered)")
        }
        var state = saved.state
        state.reconcile(windowIDs: survivingIDs)
        return .restored(state)
    }

    /// Where an unreadable file written at `date` is moved.
    func unreadableURL(at date: Date = Date()) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(name).unreadable-\(Int(date.timeIntervalSince1970)).json")
    }

    private func setAside(because reason: String) -> String {
        let preserved = unreadableURL()
        do {
            try FileManager.default.moveItem(at: url, to: preserved)
            return "\(reason) moved_aside=\(preserved.lastPathComponent)"
        } catch {
            NSLog("Stagehand could not set aside the unreadable layout file: %@", error.localizedDescription)
            return "\(reason) move_aside_failed"
        }
    }
}
