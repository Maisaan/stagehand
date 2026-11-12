import Foundation
import StagehandCore
import StagehandPlatform

/// Remembers where a quitting app's windows sat in the ribbon, so the windows of
/// its next launch (an update's relaunch, a crash restart, a quit and reopen)
/// return to the same spaces, order, widths, and heights instead of joining the
/// active space next to the focused window.
///
/// A relaunched window has a new ID (a new process), so it is matched to the
/// departed one by bundle identifier, then by title, then in ribbon order. Its
/// place is found from the neighbors it had, not from a space number: spaces close
/// and renumber when the app leaves the last one empty.
struct RelaunchPlaces {
    struct DepartedWindow: Equatable {
        let id: String
        let title: String
        /// The layout just before the window left the ribbon.
        let layout: WorkspaceState
        let preferredHeight: CGFloat?
        /// The layout just before the first window of its app's quit left. Windows
        /// close one at a time, so only this one still shows the stacks the app's
        /// windows shared; `layout` alone has lost the mates that closed first.
        var quitLayout: WorkspaceState?
    }

    struct Placement: Equatable {
        let windowID: String
        let departedWindowID: String
        /// Final spaces the window joined.
        let spaceIndices: [Int]
        /// Spaces opened for it, in order; each moved that space and later ones up.
        let openedSpaceIndices: [Int]
        let preferredHeight: CGFloat?
    }

    /// Windows an app closes while quitting usually report their destruction before
    /// the process ends, so a window that left this long before its app quit counts
    /// as part of the quit. A window closed earlier stays closed on relaunch.
    static let quitInterval: TimeInterval = 10
    /// A relaunch restores its windows in a burst. Once the first one has returned,
    /// places its later windows do not claim within this interval are dropped, so a
    /// window opened much later is placed as usual.
    static let claimInterval: TimeInterval = 15

    private struct Leaving {
        let pid: Int32
        let bundleIdentifier: String
        let window: DepartedWindow
        let leftAt: Date
    }

    private struct Departure {
        let pid: Int32
        var windows: [DepartedWindow]
        /// Departed IDs already back, mapped to their new IDs, so a later window
        /// can use an earlier one as its neighbor.
        var returnedIDs: [String: String] = [:]
        var claimant: Int32?
        var claimEnds: Date?
    }

    private var leaving: [Leaving] = []
    private var departures: [String: Departure] = [:]

    var rememberedBundleIdentifiers: Set<String> { Set(departures.keys) }

    /// Records ribbon members that just left `layout`, in case their app is quitting.
    mutating func windowsLeft(_ windows: [WindowRecord], layout: WorkspaceState,
                              preferredHeights: [String: CGFloat], at now: Date) {
        guard !windows.isEmpty || !leaving.isEmpty else { return }
        leaving.removeAll { now.timeIntervalSince($0.leftAt) > Self.quitInterval }
        let memberIDs = Set(layout.spaces.flatMap(\.windowIDs))
        for window in windows where !window.bundleIdentifier.isEmpty && memberIDs.contains(window.id) {
            leaving.removeAll { $0.window.id == window.id }
            leaving.append(Leaving(
                pid: window.pid,
                bundleIdentifier: window.bundleIdentifier,
                window: DepartedWindow(id: window.id, title: window.title, layout: layout,
                                       preferredHeight: preferredHeights[window.id]),
                leftAt: now
            ))
        }
    }

    /// The process quit: the windows it closed while quitting become its places,
    /// replacing any remembered from its app's earlier quit. Returns their count.
    @discardableResult
    mutating func applicationTerminated(pid: Int32, at now: Date) -> (bundleIdentifier: String, count: Int)? {
        let quitting = leaving.filter { $0.pid == pid && now.timeIntervalSince($0.leftAt) <= Self.quitInterval }
        leaving.removeAll { $0.pid == pid }
        guard let bundleIdentifier = quitting.first?.bundleIdentifier else { return nil }
        let quitLayout = quitting.first?.window.layout
        let windows = quitting.filter { $0.bundleIdentifier == bundleIdentifier }.map { leaving in
            var window = leaving.window
            window.quitLayout = quitLayout
            return window
        }.sorted { Self.ribbonOrder($0) < Self.ribbonOrder($1) }
        departures[bundleIdentifier] = Departure(pid: pid, windows: windows)
        return (bundleIdentifier, windows.count)
    }

    /// Puts windows that are not yet members back into the places their app's
    /// previous process left. Windows without a place are left for the usual
    /// placement. Spaces opened here go through `restoration` so remembered
    /// memberships stay aligned.
    mutating func place(_ windows: [WindowRecord], state: inout WorkspaceState,
                        restoration: inout WorkspaceRestoration, at now: Date) -> [Placement] {
        departures = departures.filter { _, departure in
            departure.claimEnds.map { now <= $0 } ?? true
        }
        guard !departures.isEmpty else { return [] }
        var placements: [Placement] = []
        for window in windows {
            let members = Set(state.spaces.flatMap(\.windowIDs))
            guard !members.contains(window.id),
                  var departure = departures[window.bundleIdentifier],
                  departure.pid != window.pid,
                  departure.claimant.map({ $0 == window.pid }) ?? true,
                  let match = departure.windows.firstIndex(where: { !window.title.isEmpty && $0.title == window.title })
                    ?? departure.windows.indices.first else { continue }
            let departed = departure.windows[match]
            let (spaces, opened) = Self.place(window.id, as: departed, returnedIDs: departure.returnedIDs,
                                              state: &state, restoration: &restoration)
            guard !spaces.isEmpty else { continue }
            departure.windows.remove(at: match)
            departure.returnedIDs[departed.id] = window.id
            departure.claimant = window.pid
            departure.claimEnds = departure.claimEnds ?? now.addingTimeInterval(Self.claimInterval)
            departures[window.bundleIdentifier] = departure.windows.isEmpty ? nil : departure
            placements.append(Placement(windowID: window.id, departedWindowID: departed.id,
                                        spaceIndices: spaces, openedSpaceIndices: opened,
                                        preferredHeight: departed.preferredHeight))
        }
        return placements
    }

    private static func ribbonOrder(_ window: DepartedWindow) -> RibbonOrder {
        guard let space = window.layout.spaces.firstIndex(where: { $0.windowIDs.contains(window.id) }),
              let position = window.layout.spaces[space].windowIDs.firstIndex(of: window.id) else {
            return RibbonOrder(space: .max, position: .max)
        }
        return RibbonOrder(space: space, position: position)
    }

    private struct RibbonOrder: Comparable {
        let space: Int
        let position: Int
        static func < (lhs: Self, rhs: Self) -> Bool { (lhs.space, lhs.position) < (rhs.space, rhs.position) }
    }

    /// Adds `windowID` to the current spaces that match the departed window's
    /// memberships. Returns the spaces it joined and the spaces opened for it.
    private static func place(_ windowID: String, as departed: DepartedWindow, returnedIDs: [String: String],
                              state: inout WorkspaceState,
                              restoration: inout WorkspaceRestoration) -> (joined: [Int], opened: [Int]) {
        let resolve = { (id: String) in returnedIDs[id] ?? id }
        var joined: [Int] = []
        var opened: [Int] = []
        for savedIndex in departed.layout.spaces.indices {
            let savedSpace = departed.layout.spaces[savedIndex]
            guard let savedPosition = savedSpace.windowIDs.firstIndex(of: departed.id) else { continue }
            let neighbors = savedSpace.windowIDs.map(resolve)
            let target: Int
            if let existing = bestSpace(containing: neighbors, in: state, near: savedIndex, excluding: windowID) {
                target = existing
            } else if let (index, isNew) = openSpace(for: savedIndex, from: departed.layout, resolve: resolve,
                                                     state: &state, restoration: &restoration) {
                target = index
                if isNew {
                    // Opening a space shifts the ones already joined.
                    joined = joined.map { $0 >= index ? $0 + 1 : $0 }
                    opened.append(index)
                }
            } else {
                continue
            }
            let space = state.spaces[target]
            guard !space.contains(windowID: windowID) else { continue }
            // A stacked window goes back into the tile holding its tile-mates.
            if let savedTile = stackTile(of: departed, in: savedSpace),
               state.rejoin(windowID: windowID,
                            savedMembers: savedTile.windowIDs.map { $0 == departed.id ? windowID : resolve($0) },
                            heightWeight: savedTile.heightWeight(for: departed.id), inSpace: target) {
                joined.append(target)
                continue
            }
            // Otherwise it is a tile of its own next to the tile of its nearest
            // remaining neighbor.
            let earlier = neighbors[..<savedPosition].reversed().first { space.contains(windowID: $0) }
            let later = neighbors[(savedPosition + 1)...].first { space.contains(windowID: $0) }
            let position = earlier.flatMap { space.tileIndex(of: $0) }.map { $0 + 1 }
                ?? later.flatMap { space.tileIndex(of: $0) }
                ?? space.tiles.endIndex
            if state.insert(windowID: windowID, inSpace: target, at: position,
                            width: savedSpace.widthFraction(for: departed.id)) {
                joined.append(target)
            }
        }
        return (joined, opened)
    }

    /// The stack the departed window was in, in the space of its layout that is
    /// `savedSpace`, as it was before its app's first window left. Nil when it
    /// was alone in its tile.
    private static func stackTile(of departed: DepartedWindow, in savedSpace: SpaceState) -> Tile? {
        var candidates = [savedSpace]
        if let quitLayout = departed.quitLayout {
            // The same space before the quit: it holds the window and, of every
            // space that does, the most of the members it still had on leaving.
            let members = Set(savedSpace.windowIDs)
            if let before = quitLayout.spaces.filter({ $0.contains(windowID: departed.id) })
                .max(by: { $0.windowIDs.count(where: members.contains) < $1.windowIDs.count(where: members.contains) }) {
                candidates.insert(before, at: 0)
            }
        }
        for space in candidates {
            if let tile = space.tileIndex(of: departed.id), space.tiles[tile].isMultiPane {
                return space.tiles[tile]
            }
        }
        return nil
    }

    /// The current space holding most of `ids`, the nearest to `savedIndex` on a tie.
    private static func bestSpace(containing ids: [String], in state: WorkspaceState,
                                  near savedIndex: Int, excluding windowID: String) -> Int? {
        let wanted = Set(ids).subtracting([windowID])
        let scored = state.spaces.indices.map { index in
            (index, state.spaces[index].windowIDs.count(where: wanted.contains))
        }.filter { $0.1 > 0 }
        return scored.max { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 < rhs.1 : abs(lhs.0 - savedIndex) > abs(rhs.0 - savedIndex)
        }?.0
    }

    /// The departed window's space closed when it left. Reopens it between the
    /// spaces that were its neighbors, using an empty space already there.
    /// `isNew` is false for an empty space, which renumbers nothing.
    private static func openSpace(for savedIndex: Int, from layout: WorkspaceState, resolve: (String) -> String,
                                  state: inout WorkspaceState,
                                  restoration: inout WorkspaceRestoration) -> (index: Int, isNew: Bool)? {
        let resolved = layout.spaces.map { $0.windowIDs.map(resolve) }
        let current = state
        let find = { (savedSpace: Int) in
            bestSpace(containing: resolved[savedSpace], in: current, near: savedSpace, excluding: "")
        }
        var found: Int?
        for savedSpace in (0..<savedIndex).reversed() {
            if let before = find(savedSpace) { found = before + 1; break }
        }
        if found == nil {
            for savedSpace in (savedIndex + 1)..<layout.spaces.count {
                if let after = find(savedSpace) { found = after; break }
            }
        }
        guard let index = found else { return nil }
        guard state.spaces.indices.contains(index) else { return nil }
        if state.spaces[index].windowIDs.isEmpty { return (index, false) }
        return restoration.openSpace(state: &state, at: index) ? (index, true) : nil
    }
}
