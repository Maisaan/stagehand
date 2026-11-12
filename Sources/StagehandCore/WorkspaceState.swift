import Foundation

public enum NavigationAction: Equatable, Sendable {
    case focusPrevious
    case focusNext
    case previousSpace
    case nextSpace
    case reorderPrevious
    case reorderNext
    case moveWindowUpSpace
    case moveWindowDownSpace
    case goToSpace(index: Int)
    case moveToSpace(index: Int, follow: Bool)
    case shareToSpace(index: Int)
    case shrinkWidth
    case growWidth
    /// Steps the focused window's width through the saved presets, wrapping at the ends.
    case nextWidthPreset
    case previousWidthPreset
    case shrinkHeight
    case growHeight
    case togglePause
    case showSettings
    /// Shows or hides the shortcut ribbon at the bottom of the screen.
    case toggleShortcutHints
    /// Alone in its tile, the focused window joins the tile before it, at the
    /// bottom; in a stack, it leaves as its own tile before the stack.
    case stackPrevious
    /// The same move toward the tile after it.
    case stackNext
    /// Focuses the window above the focused one in its tile.
    case focusMemberAbove
    /// Focuses the window below the focused one in its tile.
    case focusMemberBelow

    /// Commands for Stagehand itself. They never move focus, so their chords pass
    /// through the keyboard tap to Carbon instead of reserving a focus transfer.
    public var isStagehandCommand: Bool {
        switch self {
        case .togglePause, .showSettings, .toggleShortcutHints: true
        default: false
        }
    }
}

/// One place in the ribbon: windows stacked top to bottom that share one width.
public struct Tile: Codable, Equatable, Sendable {
    public static let defaultHeightWeight = 1.0

    /// Stable for the tile's life in its space. A new tile takes the ID of the
    /// window that starts it, made unique within the space; it does not follow
    /// that window when it leaves.
    public let id: String
    /// Members top to bottom. Never empty inside a `SpaceState`.
    public fileprivate(set) var windowIDs: [String]
    public fileprivate(set) var widthFraction: Double
    /// The member that horizontal focus enters; the focused window when this
    /// tile holds focus.
    public fileprivate(set) var activeWindowID: String
    /// Each member's relative share of a stack's height, parallel to `windowIDs`.
    public fileprivate(set) var heightWeights: [Double]

    public var isMultiPane: Bool { windowIDs.count > 1 }
    // Kept for StagehandModel+Benchmark.swift until slice B.
    public var isStack: Bool { isMultiPane }

    public init(
        id: String? = nil,
        windowIDs: [String],
        widthFraction: Double = SpaceState.defaultWidthFraction,
        activeWindowID: String? = nil,
        heightWeights: [Double] = []
    ) {
        var seen = Set<String>()
        var members: [String] = []
        var weights: [Double] = []
        for (offset, windowID) in windowIDs.enumerated() where !windowID.isEmpty && seen.insert(windowID).inserted {
            members.append(windowID)
            weights.append(Self.clampedHeightWeight(heightWeights.indices.contains(offset) ? heightWeights[offset] : nil))
        }
        self.id = id.flatMap { $0.isEmpty ? nil : $0 } ?? members.first ?? ""
        self.windowIDs = members
        self.widthFraction = SpaceState.clampedWidth(widthFraction)
        self.activeWindowID = activeWindowID.flatMap { seen.contains($0) ? $0 : nil } ?? members.first ?? ""
        self.heightWeights = weights
    }

    public func heightWeight(for windowID: String) -> Double {
        windowIDs.firstIndex(of: windowID).map { heightWeights[$0] } ?? Self.defaultHeightWeight
    }

    fileprivate static func clampedHeightWeight(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return defaultHeightWeight }
        return value
    }

    fileprivate mutating func append(windowID: String) {
        windowIDs.append(windowID)
        heightWeights.append(Self.defaultHeightWeight)
    }

    fileprivate mutating func insertMember(_ windowID: String, at position: Int, heightWeight: Double) {
        let index = min(max(position, 0), windowIDs.count)
        windowIDs.insert(windowID, at: index)
        heightWeights.insert(Self.clampedHeightWeight(heightWeight), at: index)
    }

    /// Removes a member. A removed active member hands that role to the window
    /// that takes its place, or to the one above when it was the bottom member.
    fileprivate mutating func removeMember(at index: Int) {
        let windowID = windowIDs.remove(at: index)
        heightWeights.remove(at: index)
        if activeWindowID == windowID, !windowIDs.isEmpty {
            activeWindowID = windowIDs[min(index, windowIDs.count - 1)]
        }
    }

    fileprivate mutating func moveMember(from source: Int, to destination: Int) {
        let windowID = windowIDs.remove(at: source)
        let weight = heightWeights.remove(at: source)
        windowIDs.insert(windowID, at: destination)
        heightWeights.insert(weight, at: destination)
    }

    private enum CodingKeys: String, CodingKey {
        case id, windowIDs, widthFraction, activeWindowID, heightWeights
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id),
            windowIDs: try values.decodeIfPresent([String].self, forKey: .windowIDs) ?? [],
            widthFraction: try values.decodeIfPresent(Double.self, forKey: .widthFraction)
                ?? SpaceState.defaultWidthFraction,
            activeWindowID: try values.decodeIfPresent(String.self, forKey: .activeWindowID),
            heightWeights: try values.decodeIfPresent([Double].self, forKey: .heightWeights) ?? []
        )
    }
}

/// A space's ribbon: ordered tiles. A window appears at most once per space,
/// tiles are never empty, and the focused window is its tile's active member.
/// A window can belong to several spaces; stack composition is per space.
public struct SpaceState: Codable, Equatable, Sendable {
    public static let minimumWidthFraction = 0.25
    public static let maximumWidthFraction = 1.0
    public static let defaultWidthFraction = 0.95
    public static let defaultWidthPresets: [Double] = [0.5, 0.75, 1.0]

    /// Presets as the preset shortcuts use them: within the supported width range,
    /// rounded to whole percent, without duplicates, ascending. An empty or
    /// unusable list falls back to the defaults.
    public static func normalizedWidthPresets(_ presets: [Double]) -> [Double] {
        let usable = presets.filter(\.isFinite).map { clampedWidth($0) }
        let normalized = Array(Set(usable.map { ($0 * 100).rounded() / 100 })).sorted()
        return normalized.isEmpty ? defaultWidthPresets : normalized
    }

    /// The ribbon's tiles, left to right.
    public fileprivate(set) var tiles: [Tile] {
        didSet { indexMembers() }
    }
    // Kept for StagehandModel+Benchmark.swift until slice B.
    public var columns: [Tile] { tiles }
    /// Every member, tile by tile, top to bottom. Derived from `tiles` and
    /// rebuilt on each change, so per-frame readers do not allocate.
    public private(set) var windowIDs: [String] = []
    private var tileIndexByWindowID: [String: Int] = [:]
    public fileprivate(set) var focusedWindowID: String?

    /// A space whose windows each have a tile of their own.
    public init(
        windowIDs: [String] = [],
        focusedWindowID: String? = nil,
        widthFractions: [String: Double] = [:]
    ) {
        self.init(
            tiles: windowIDs.map {
                Tile(windowIDs: [$0], widthFraction: widthFractions[$0] ?? Self.defaultWidthFraction)
            },
            focusedWindowID: focusedWindowID
        )
    }

    /// Drops empty tiles and any window already placed in an earlier tile,
    /// and makes tile IDs unique.
    public init(tiles: [Tile], focusedWindowID: String? = nil) {
        var seen = Set<String>()
        var usedIDs = Set<String>()
        var kept: [Tile] = []
        for tile in tiles {
            let indices = tile.windowIDs.indices.filter { seen.insert(tile.windowIDs[$0]).inserted }
            guard let first = indices.first else { continue }
            let id = Self.uniqueTileID(tile.id.isEmpty ? tile.windowIDs[first] : tile.id, used: usedIDs)
            usedIDs.insert(id)
            kept.append(Tile(
                id: id,
                windowIDs: indices.map { tile.windowIDs[$0] },
                widthFraction: tile.widthFraction,
                activeWindowID: tile.activeWindowID,
                heightWeights: indices.map { tile.heightWeights[$0] }
            ))
        }
        self.tiles = kept
        self.focusedWindowID = nil
        indexMembers()
        if let focus = focusedWindowID.flatMap({ seen.contains($0) ? $0 : nil }) ?? kept.first?.activeWindowID {
            setFocus(windowID: focus)
        }
    }

    public func contains(windowID: String) -> Bool {
        tileIndexByWindowID[windowID] != nil
    }

    public func tileIndex(of windowID: String) -> Int? {
        tileIndexByWindowID[windowID]
    }

    public var focusedTileIndex: Int? {
        focusedWindowID.flatMap(tileIndex(of:))
    }

    /// The width of the window's tile.
    public func widthFraction(for windowID: String) -> Double {
        tileIndex(of: windowID).map { tiles[$0].widthFraction } ?? Self.defaultWidthFraction
    }

    fileprivate static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidthFraction }
        return min(max(value, minimumWidthFraction), maximumWidthFraction)
    }

    private static func uniqueTileID(_ base: String, used: Set<String>) -> String {
        guard used.contains(base) else { return base }
        var suffix = 2
        while used.contains("\(base)#\(suffix)") { suffix += 1 }
        return "\(base)#\(suffix)"
    }

    private mutating func indexMembers() {
        var flat: [String] = []
        var index: [String: Int] = [:]
        for (tileIndex, tile) in tiles.enumerated() {
            for windowID in tile.windowIDs {
                flat.append(windowID)
                index[windowID] = tileIndex
            }
        }
        windowIDs = flat
        tileIndexByWindowID = index
    }

    /// Focuses a member and makes it its tile's active member.
    fileprivate mutating func setFocus(windowID: String) {
        guard let index = tileIndex(of: windowID) else { return }
        if tiles[index].activeWindowID != windowID { tiles[index].activeWindowID = windowID }
        focusedWindowID = windowID
    }

    /// A one-window tile for `windowID` with an ID unused in this space.
    fileprivate func newTile(windowID: String, width: Double) -> Tile {
        Tile(id: Self.uniqueTileID(windowID, used: Set(tiles.map(\.id))),
             windowIDs: [windowID], widthFraction: width)
    }

    /// Adds a window as its own tile after the focused tile.
    fileprivate mutating func insert(windowID: String, width: Double, focus: Bool) {
        guard !windowID.isEmpty, !contains(windowID: windowID) else { return }
        let insertionIndex = focusedTileIndex.map { $0 + 1 } ?? tiles.endIndex
        tiles.insert(newTile(windowID: windowID, width: width), at: insertionIndex)
        if focus || focusedWindowID == nil { setFocus(windowID: windowID) }
    }

    /// A focused window that leaves hands focus to a tile-mate (the one below,
    /// or above when it was the bottom member); a window alone in its tile
    /// hands it to the next tile's active member, or the previous tile's.
    fileprivate mutating func remove(windowID: String) {
        guard let index = tileIndex(of: windowID),
              let member = tiles[index].windowIDs.firstIndex(of: windowID) else { return }
        if tiles[index].isMultiPane {
            tiles[index].removeMember(at: member)
            if focusedWindowID == windowID { setFocus(windowID: tiles[index].activeWindowID) }
        } else {
            tiles.remove(at: index)
            if focusedWindowID == windowID {
                focusedWindowID = nil
                if !tiles.isEmpty { setFocus(windowID: tiles[min(index, tiles.count - 1)].activeWindowID) }
            }
        }
    }

    /// Puts a window that is not a member back between the tile-mates it had.
    /// `savedMembers` is its saved tile top to bottom, itself included. It joins
    /// the tile of its nearest saved mate above (just below that mate), else of
    /// its nearest saved mate below (just above it). False when no mate is here.
    fileprivate mutating func rejoin(windowID: String, savedMembers: [String], heightWeight: Double) -> Bool {
        guard !contains(windowID: windowID), let position = savedMembers.firstIndex(of: windowID) else { return false }
        let above = savedMembers[..<position].reversed().first { contains(windowID: $0) }
        let below = savedMembers[(position + 1)...].first { contains(windowID: $0) }
        guard let mate = above ?? below, let tile = tileIndex(of: mate),
              let mateIndex = tiles[tile].windowIDs.firstIndex(of: mate) else { return false }
        tiles[tile].insertMember(windowID, at: above != nil ? mateIndex + 1 : mateIndex,
                                 heightWeight: heightWeight)
        return true
    }

    /// Takes a window out of its tile and returns it as a tile of its own.
    /// A window alone in its tile takes that tile, ID included. Focus is the
    /// caller's to restore.
    fileprivate mutating func detach(windowID: String) -> Tile? {
        guard let index = tileIndex(of: windowID),
              let member = tiles[index].windowIDs.firstIndex(of: windowID) else { return nil }
        guard tiles[index].isMultiPane else { return tiles.remove(at: index) }
        let width = tiles[index].widthFraction
        tiles[index].removeMember(at: member)
        return newTile(windowID: windowID, width: width)
    }

    private enum CodingKeys: String, CodingKey {
        // Version 2 layout files store tiles under this key.
        case tiles = "columns", focusedWindowID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tiles: try values.decodeIfPresent([Tile].self, forKey: .tiles) ?? [],
            focusedWindowID: try values.decodeIfPresent(String.self, forKey: .focusedWindowID)
        )
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let spaceCount = 9

    public var isPaused: Bool
    public private(set) var spaces: [SpaceState]
    public private(set) var activeSpaceIndex: Int

    public var currentSpace: SpaceState { spaces[activeSpaceIndex] }
    public var focusedWindowID: String? { currentSpace.focusedWindowID }
    public var displayedSpaceIndices: [Int] {
        spaces.indices.filter { $0 == activeSpaceIndex || !spaces[$0].windowIDs.isEmpty }
    }

    public init(
        isPaused: Bool = false,
        spaces: [SpaceState] = [],
        activeSpaceIndex: Int = 0
    ) {
        self.isPaused = isPaused
        self.spaces = Array(spaces.prefix(Self.spaceCount))
        self.spaces.append(contentsOf: repeatElement(SpaceState(), count: Self.spaceCount - self.spaces.count))
        self.activeSpaceIndex = min(max(activeSpaceIndex, 0), Self.spaceCount - 1)
    }

    /// Restore returning windows without undoing changes to windows already in the workspace.
    public mutating func restoreMemberships(windowIDs: Set<String>, from savedState: WorkspaceState) {
        let returningIDs = windowIDs.subtracting(spaces.flatMap(\.windowIDs))
        for index in spaces.indices {
            let savedSpace = savedState.spaces[index]
            for (offset, windowID) in savedSpace.windowIDs.enumerated() where returningIDs.contains(windowID) {
                // A window that was stacked rejoins the tile holding its saved
                // tile-mates, between the same neighbors, with its saved share.
                if let savedTile = savedSpace.tileIndex(of: windowID).map({ savedSpace.tiles[$0] }),
                   savedTile.isMultiPane,
                   spaces[index].rejoin(windowID: windowID, savedMembers: savedTile.windowIDs,
                                        heightWeight: savedTile.heightWeight(for: windowID)) {
                    continue
                }
                // Insert before the next surviving neighbor's tile, preserving the
                // current order of windows the user has already resumed and rearranged.
                // Otherwise a returning window comes back as a tile of its own.
                let nextID = savedSpace.windowIDs.dropFirst(offset + 1)
                    .first { spaces[index].contains(windowID: $0) }
                let insertionIndex = nextID.flatMap { spaces[index].tileIndex(of: $0) }
                    ?? spaces[index].tiles.endIndex
                spaces[index].tiles.insert(
                    spaces[index].newTile(windowID: windowID, width: savedSpace.widthFraction(for: windowID)),
                    at: insertionIndex
                )
            }
            if spaces[index].focusedWindowID == nil,
               let focus = savedSpace.focusedWindowID.flatMap({ spaces[index].contains(windowID: $0) ? $0 : nil })
                ?? spaces[index].tiles.first?.activeWindowID {
                spaces[index].setFocus(windowID: focus)
            }
        }
    }

    /// Reconcile against all live managed windows, including windows in other spaces.
    /// Only globally unknown windows are added to the active space.
    public mutating func reconcile(
        windowIDs: [String],
        initialWidthFractions: [String: Double] = [:]
    ) {
        let wasOccupied = !currentSpace.windowIDs.isEmpty
        let liveIDs = Set(windowIDs)
        for index in spaces.indices {
            for windowID in spaces[index].windowIDs where !liveIDs.contains(windowID) {
                spaces[index].remove(windowID: windowID)
            }
        }
        var knownIDs = Set(spaces.flatMap(\.windowIDs))
        for windowID in windowIDs where !windowID.isEmpty && knownIDs.insert(windowID).inserted {
            spaces[activeSpaceIndex].insert(
                windowID: windowID,
                width: initialWidthFractions[windowID] ?? SpaceState.defaultWidthFraction,
                focus: true
            )
        }
        if wasOccupied && currentSpace.windowIDs.isEmpty {
            // Keep numbered shortcuts stable; empty spaces disappear from the picker.
            activeSpaceIndex = spaces.indices.last(where: { $0 < activeSpaceIndex && !spaces[$0].windowIDs.isEmpty })
                ?? spaces.indices.first(where: { !spaces[$0].windowIDs.isEmpty }) ?? 0
        }
    }

    /// Remove an empty numbered space so later spaces move down together.
    @discardableResult
    public mutating func closeEmptySpace(at index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].windowIDs.isEmpty,
              spaces[(index + 1)...].contains(where: { !$0.windowIDs.isEmpty }) else { return false }
        discardSpace(at: index)
        return true
    }

    /// Opens an empty numbered space at `index`; it and later spaces move up one.
    /// Fails when the last space is occupied or active, since it would be dropped.
    @discardableResult
    public mutating func openSpace(at index: Int) -> Bool {
        let last = Self.spaceCount - 1
        guard spaces.indices.contains(index), spaces[last].windowIDs.isEmpty,
              activeSpaceIndex != last else { return false }
        spaces.removeLast()
        spaces.insert(SpaceState(), at: index)
        if activeSpaceIndex >= index { activeSpaceIndex += 1 }
        return true
    }

    /// Adds a window that is not yet a member of the space as its own tile at
    /// tile index `position`, keeping the space's focus, as a relaunched window
    /// returning to its place in the ribbon.
    @discardableResult
    public mutating func insert(windowID: String, inSpace index: Int, at position: Int, width: Double) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty,
              !spaces[index].contains(windowID: windowID) else { return false }
        let clamped = min(max(position, 0), spaces[index].tiles.count)
        spaces[index].tiles.insert(spaces[index].newTile(windowID: windowID, width: width), at: clamped)
        if spaces[index].focusedWindowID == nil { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Adds a window that is not yet a member of the space into the tile holding
    /// its nearest saved tile-mate, as a relaunched stack member returning to its
    /// stack. `savedMembers` is its saved tile top to bottom, with this window's
    /// ID in its own place. Keeps the space's focus and the tile's width. False
    /// when none of its mates is in the space.
    @discardableResult
    public mutating func rejoin(windowID: String, savedMembers: [String], heightWeight: Double,
                                inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty else { return false }
        return spaces[index].rejoin(windowID: windowID, savedMembers: savedMembers, heightWeight: heightWeight)
    }

    /// Keep a saved membership snapshot aligned after the corresponding live space closes.
    public mutating func discardSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        spaces.remove(at: index)
        spaces.append(SpaceState())
        if activeSpaceIndex > index { activeSpaceIndex -= 1 }
    }

    @discardableResult
    public mutating func focus(windowID: String) -> Bool {
        focus(windowID: windowID, inSpace: activeSpaceIndex)
    }

    @discardableResult
    public mutating func focus(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID),
              activeSpaceIndex != index || spaces[index].focusedWindowID != windowID else { return false }
        activeSpaceIndex = index
        spaces[index].setFocus(windowID: windowID)
        return true
    }

    /// Moves a member, as a tile of its own, directly after the space's focused
    /// tile, then focuses it there, as macOS does when the user reopens a window.
    /// A stacked window leaves its stack.
    @discardableResult
    public mutating func placeAfterFocused(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID) else { return false }
        if let anchor = spaces[index].focusedWindowID, anchor != windowID,
           let tile = spaces[index].detach(windowID: windowID) {
            let anchorIndex = spaces[index].tileIndex(of: anchor) ?? spaces[index].tiles.endIndex - 1
            spaces[index].tiles.insert(tile, at: anchorIndex + 1)
        }
        activeSpaceIndex = index
        spaces[index].setFocus(windowID: windowID)
        return true
    }

    /// Moves the window's whole tile to tile index `index` in the current
    /// space, preserving focus and per-space widths.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int) -> Bool {
        reorderWindow(windowID: windowID, to: index, inSpace: activeSpaceIndex)
    }

    /// Moves the window's whole tile to tile index `index` without making the
    /// space active. While every tile holds one window, a tile index is a
    /// window index.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int, inSpace spaceIndex: Int) -> Bool {
        guard spaces.indices.contains(spaceIndex),
              let originalIndex = spaces[spaceIndex].tileIndex(of: windowID) else { return false }
        let destination = min(max(index, 0), spaces[spaceIndex].tiles.count - 1)
        guard originalIndex != destination else { return false }
        var tiles = spaces[spaceIndex].tiles
        tiles.insert(tiles.remove(at: originalIndex), at: destination)
        spaces[spaceIndex].tiles = tiles
        return true
    }

    /// Moves a member to `position` within its own tile, top to bottom. Its
    /// height weight moves with it; focus and width do not change.
    @discardableResult
    public mutating func reorderMember(windowID: String, to position: Int, inSpace spaceIndex: Int) -> Bool {
        guard spaces.indices.contains(spaceIndex),
              let tile = spaces[spaceIndex].tileIndex(of: windowID),
              let member = spaces[spaceIndex].tiles[tile].windowIDs.firstIndex(of: windowID) else { return false }
        let destination = min(max(position, 0), spaces[spaceIndex].tiles[tile].windowIDs.count - 1)
        guard member != destination else { return false }
        spaces[spaceIndex].tiles[tile].moveMember(from: member, to: destination)
        return true
    }

    /// Adds a window at the bottom of the tile at `tileIndex` in the space,
    /// taking that tile's width. A focused window keeps focus.
    @discardableResult
    public mutating func stack(windowID: String, intoTileAt tileIndex: Int, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].tiles.indices.contains(tileIndex),
              let source = spaces[index].tileIndex(of: windowID), source != tileIndex else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        let sourceDisappears = !spaces[index].tiles[source].isMultiPane
        _ = spaces[index].detach(windowID: windowID)
        let target = sourceDisappears && source < tileIndex ? tileIndex - 1 : tileIndex
        spaces[index].tiles[target].append(windowID: windowID)
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Takes a stacked window out of its tile as a tile of its own, directly
    /// before it (`direction` < 0) or after it, with the stack's width. A focused
    /// window keeps focus.
    @discardableResult
    public mutating func unstack(windowID: String, toward direction: Int, inSpace index: Int) -> Bool {
        guard direction != 0, spaces.indices.contains(index),
              let source = spaces[index].tileIndex(of: windowID),
              spaces[index].tiles[source].isMultiPane else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        guard let tile = spaces[index].detach(windowID: windowID) else { return false }
        spaces[index].tiles.insert(tile, at: direction < 0 ? source : source + 1)
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Takes a stacked window out of its tile as a tile of its own at tile
    /// index `position`, counted with its stack still in place, with the stack's
    /// width, as a member dropped outside its tile. A focused window keeps focus.
    @discardableResult
    public mutating func unstack(windowID: String, toTileAt position: Int, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index),
              let source = spaces[index].tileIndex(of: windowID),
              spaces[index].tiles[source].isMultiPane else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        guard let tile = spaces[index].detach(windowID: windowID) else { return false }
        spaces[index].tiles.insert(tile, at: min(max(position, 0), spaces[index].tiles.count))
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Sets a stacked member's relative share of its tile's height in the
    /// current space. A window alone in its tile has no share to set.
    @discardableResult
    public mutating func setHeightWeight(_ weight: Double, for windowID: String) -> Bool {
        guard weight.isFinite, weight > 0,
              let tile = currentSpace.tileIndex(of: windowID), currentSpace.tiles[tile].isMultiPane,
              let member = currentSpace.tiles[tile].windowIDs.firstIndex(of: windowID),
              currentSpace.tiles[tile].heightWeights[member] != weight else { return false }
        spaces[activeSpaceIndex].tiles[tile].heightWeights[member] = weight
        return true
    }

    /// The sideways stacking move for the focused window: alone in its tile, it
    /// joins the neighboring tile on that side at the bottom; in a stack, it
    /// leaves as its own tile on that side. Focus stays on it.
    @discardableResult
    public mutating func moveFocusedWindowAcrossTiles(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID,
              let tile = currentSpace.tileIndex(of: windowID) else { return false }
        if currentSpace.tiles[tile].isMultiPane {
            return unstack(windowID: windowID, toward: direction, inSpace: activeSpaceIndex)
        }
        let target = tile + direction.signum()
        guard currentSpace.tiles.indices.contains(target) else { return false }
        return stack(windowID: windowID, intoTileAt: target, inSpace: activeSpaceIndex)
    }

    /// Focuses the window above (`direction` < 0) or below the focused window in
    /// its tile. Stops at the ends.
    @discardableResult
    public mutating func focusMember(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID,
              let tile = currentSpace.tileIndex(of: windowID) else { return false }
        let members = currentSpace.tiles[tile].windowIDs
        guard let member = members.firstIndex(of: windowID),
              members.indices.contains(member + direction.signum()) else { return false }
        spaces[activeSpaceIndex].setFocus(windowID: members[member + direction.signum()])
        return true
    }

    /// Sets the width of the window's tile in the current space.
    @discardableResult
    public mutating func setWidthFraction(_ width: Double, for windowID: String) -> Bool {
        guard let tile = currentSpace.tileIndex(of: windowID) else { return false }
        let value = SpaceState.clampedWidth(width)
        guard currentSpace.tiles[tile].widthFraction != value else { return false }
        spaces[activeSpaceIndex].tiles[tile].widthFraction = value
        return true
    }

    /// Removing the final membership would orphan a live window, so it is a no-op.
    @discardableResult
    public mutating func removeFromCurrentSpace(windowID: String) -> Bool {
        remove(windowID: windowID, fromSpace: activeSpaceIndex)
    }

    @discardableResult
    public mutating func remove(windowID: String, fromSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID),
              spaces.membershipCount(of: windowID) > 1 else { return false }
        spaces[index].remove(windowID: windowID)
        return true
    }

    @discardableResult
    public mutating func share(windowID: String, toSpace index: Int) -> Bool {
        share(windowID: windowID, fromSpace: activeSpaceIndex, toSpace: index)
    }

    @discardableResult
    public mutating func share(windowID: String, fromSpace sourceIndex: Int, toSpace destinationIndex: Int) -> Bool {
        guard spaces.indices.contains(sourceIndex), spaces.indices.contains(destinationIndex),
              sourceIndex != destinationIndex, spaces[sourceIndex].contains(windowID: windowID),
              !spaces[destinationIndex].contains(windowID: windowID) else { return false }
        spaces[destinationIndex].insert(
            windowID: windowID,
            width: spaces[sourceIndex].widthFraction(for: windowID),
            focus: false
        )
        return true
    }

    @discardableResult
    public mutating func move(windowID: String, fromSpace sourceIndex: Int, toSpace destinationIndex: Int) -> Bool {
        guard spaces.indices.contains(sourceIndex), spaces.indices.contains(destinationIndex),
              sourceIndex != destinationIndex, spaces[sourceIndex].contains(windowID: windowID) else { return false }
        let width = spaces[sourceIndex].widthFraction(for: windowID)
        spaces[destinationIndex].insert(windowID: windowID, width: width, focus: false)
        spaces[sourceIndex].remove(windowID: windowID)
        return true
    }

    @discardableResult
    public mutating func apply(_ action: NavigationAction,
                               widthPresets: [Double] = SpaceState.defaultWidthPresets) -> Bool {
        switch action {
        case .focusPrevious: return navigateWindow(by: -1, reorder: false)
        case .focusNext: return navigateWindow(by: 1, reorder: false)
        case .reorderPrevious: return navigateWindow(by: -1, reorder: true)
        case .reorderNext: return navigateWindow(by: 1, reorder: true)
        case .moveWindowUpSpace:
            return moveFocusedWindow(toSpace: activeSpaceIndex - 1, follow: true)
        case .moveWindowDownSpace:
            guard currentSpace.windowIDs.count > 1 else { return false }
            return moveFocusedWindow(toSpace: activeSpaceIndex + 1, follow: true)
        case .previousSpace:
            guard let index = displayedSpaceIndices.last(where: { $0 < activeSpaceIndex }) else { return false }
            return goToSpace(index: index)
        case .nextSpace:
            guard let index = displayedSpaceIndices.first(where: { $0 > activeSpaceIndex }) else { return false }
            return goToSpace(index: index)
        case .goToSpace(let index): return goToSpace(index: index)
        case .moveToSpace(let index, let follow):
            return moveFocusedWindow(toSpace: index, follow: follow)
        case .shareToSpace(let index):
            guard let focusedWindowID else { return false }
            return share(windowID: focusedWindowID, toSpace: index)
        case .shrinkWidth, .growWidth:
            guard let windowID = focusedWindowID else { return false }
            let adjustment = action == .growWidth ? 0.05 : -0.05
            let width = (currentSpace.widthFraction(for: windowID) * 100 + adjustment * 100).rounded() / 100
            return setWidthFraction(width, for: windowID)
        case .nextWidthPreset, .previousWidthPreset:
            guard let windowID = focusedWindowID else { return false }
            let presets = SpaceState.normalizedWidthPresets(widthPresets)
            let current = currentSpace.widthFraction(for: windowID)
            // Half a percent of slack so a width set by a drag lands on the nearest step.
            let target = action == .nextWidthPreset
                ? presets.first { $0 > current + 0.005 } ?? presets[0]
                : presets.last { $0 < current - 0.005 } ?? presets[presets.count - 1]
            return setWidthFraction(target, for: windowID)
        case .shrinkHeight, .growHeight:
            return false
        case .togglePause:
            isPaused.toggle()
            return true
        case .showSettings, .toggleShortcutHints:
            return false
        case .stackPrevious, .stackNext:
            return moveFocusedWindowAcrossTiles(by: action == .stackNext ? 1 : -1)
        case .focusMemberAbove, .focusMemberBelow:
            return focusMember(by: action == .focusMemberBelow ? 1 : -1)
        }
    }

    /// Steps focus into the adjacent tile's active member, or swaps the focused
    /// tile with it.
    private mutating func navigateWindow(by direction: Int, reorder: Bool) -> Bool {
        guard let index = currentSpace.focusedTileIndex,
              currentSpace.tiles.indices.contains(index + direction) else { return false }
        if reorder {
            spaces[activeSpaceIndex].tiles.swapAt(index, index + direction)
        } else {
            spaces[activeSpaceIndex].setFocus(windowID: currentSpace.tiles[index + direction].activeWindowID)
        }
        return true
    }

    private mutating func goToSpace(index: Int) -> Bool {
        guard spaces.indices.contains(index), index != activeSpaceIndex else { return false }
        activeSpaceIndex = index
        return true
    }

    private mutating func moveFocusedWindow(toSpace index: Int, follow: Bool) -> Bool {
        guard spaces.indices.contains(index), index != activeSpaceIndex,
              let windowID = focusedWindowID else { return false }
        spaces[index].insert(windowID: windowID, width: currentSpace.widthFraction(for: windowID), focus: false)
        spaces[activeSpaceIndex].remove(windowID: windowID)
        if follow {
            activeSpaceIndex = index
            spaces[index].setFocus(windowID: windowID)
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case isPaused, spaces, activeSpaceIndex
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isPaused: try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
            spaces: try values.decodeIfPresent([SpaceState].self, forKey: .spaces) ?? [],
            activeSpaceIndex: try values.decodeIfPresent(Int.self, forKey: .activeSpaceIndex) ?? 0
        )
    }
}

extension Sequence where Element == SpaceState {
    /// The number of spaces that contain the window.
    public func membershipCount(of windowID: String) -> Int {
        count { $0.contains(windowID: windowID) }
    }
}
