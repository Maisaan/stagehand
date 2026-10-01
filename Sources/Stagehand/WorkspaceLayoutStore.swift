import AppKit
import StagehandCore
import StagehandPlatform

/// Saves the ribbon layout so a relaunched Stagehand can return windows to their
/// spaces, order, and widths. Window IDs combine a process ID and a WindowServer
/// window number, so a saved window is restored only while the same process,
/// identified by its launch date, is still running.
struct WorkspaceLayoutStore {
    private struct SavedLayout: Codable {
        var state: WorkspaceState
        var processLaunchDates: [String: Date]
    }

    static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Stagehand/workspace-layout.json")
    }

    let url: URL
    let launchDate: (Int32) -> Date?

    init(url: URL = WorkspaceLayoutStore.defaultURL,
         launchDate: @escaping (Int32) -> Date? = { NSRunningApplication(processIdentifier: $0)?.launchDate }) {
        self.url = url
        self.launchDate = launchDate
    }

    /// Saves memberships of windows whose process can be identified later.
    func save(_ state: WorkspaceState, windows: [WindowRecord]) {
        var launchDates: [String: Date] = [:]
        for window in windows {
            if let date = launchDate(window.pid) { launchDates[window.id] = date }
        }
        var saved = state
        saved.isPaused = false
        saved.reconcile(windowIDs: saved.spaces.flatMap(\.windowIDs).filter { launchDates[$0] != nil })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedLayout(state: saved, processLaunchDates: launchDates))
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Stagehand layout save failed: %@", error.localizedDescription)
        }
    }

    enum LoadResult: Equatable {
        case restored(WorkspaceState)
        case unavailable(reason: String)
    }

    /// The saved layout, limited to windows whose process is still running.
    func load(windows: [WindowRecord]) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .unavailable(reason: "no_saved_layout") }
        guard let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) else {
            return .unavailable(reason: "unreadable")
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
}
