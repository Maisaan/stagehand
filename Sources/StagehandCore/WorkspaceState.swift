import CoreGraphics
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
    /// Focuses the pane above the focused one in its tile; never leaves the tile.
    case focusPaneAbove
    case focusPaneBelow
    /// Swaps the focused window with the pane on that side; at the tile's edge it
    /// leaves as its own tile; alone, it joins the neighboring tile's facing edge.
    case moveWindowLeftInTile
    case moveWindowRightInTile
    /// Swaps the focused window with the pane above or below; nothing at the edge.
    case moveWindowUpInTile
    case moveWindowDownInTile
    /// Gives the focused window's tile a ready-made layout.
    case arrangeTile(PaneLayout)
    /// Anchors the focused space to the display on that side (negative: left); focus follows it.
    case moveSpaceToDisplay(direction: Int)

    /// Commands for Stagehand itself. They never move focus, so their chords pass
    /// through the keyboard tap to Carbon instead of reserving a focus transfer.
    public var isStagehandCommand: Bool {
        switch self {
        case .togglePause, .showSettings, .toggleShortcutHints: true
        default: false
        }
    }
}

/// One place in the ribbon: a width and a layout of panes, each holding one window.
public struct Tile: Codable, Equatable, Sendable {
    /// Stable for the tile's life in its space. A new tile takes the ID of the
    /// window that starts it, made unique within the space; it does not follow
    /// that window when it leaves.
    public let id: String
    public private(set) var panes: PaneTree
    public fileprivate(set) var widthFraction: Double
    /// The pane that horizontal focus enters; the focused window when this tile
    /// holds focus.
    public fileprivate(set) var activeWindowID: String
    /// Reading order, derived from `panes`. Stored because layout reads it on
    /// every gesture frame.
    public private(set) var windowIDs: [String]

    public var isMultiPane: Bool { windowIDs.count > 1 }

    /// Repairs `panes` to canonical form, keeping the first pane of a window
    /// that appears twice. A tile without panes is dropped by `SpaceState`.
    public init(
        id: String? = nil,
        panes: PaneTree,
        widthFraction: Double = SpaceState.defaultWidthFraction,
        activeWindowID: String? = nil
    ) {
        var seen = Set<String>()
        let repaired = panes.restricted { !$0.isEmpty && seen.insert($0).inserted }
        self.panes = repaired ?? Self.emptyPanes
        self.windowIDs = repaired?.windowIDs ?? []
        self.id = id.flatMap { $0.isEmpty ? nil : $0 } ?? windowIDs.first ?? ""
        self.widthFraction = SpaceState.clampedWidth(widthFraction)
        self.activeWindowID = activeWindowID.flatMap { seen.contains($0) ? $0 : nil } ?? windowIDs.first ?? ""
    }

    public init(id: String? = nil, windowID: String, widthFraction: Double = SpaceState.defaultWidthFraction) {
        self.init(id: id, panes: .pane(windowID: windowID), widthFraction: widthFraction)
    }

    private static let emptyPanes = PaneTree.split(axis: .vertical, children: [], weights: [])

    /// The window's share of the tile's width, as a fraction of the display.
    func paneWidthFraction(of windowID: String) -> Double {
        guard isMultiPane else { return widthFraction }
        let share = panes.unitFrame(of: windowID).map { Double($0.width) } ?? 1
        return SpaceState.clampedWidth(widthFraction * share)
    }

    fileprivate mutating func setPanes(_ tree: PaneTree) {
        panes = tree.restricted { _ in true } ?? tree
        windowIDs = panes.windowIDs
        if !tree.contains(activeWindowID) { activeWindowID = windowIDs.first ?? "" }
    }

    /// Removes a pane of a multi-pane tile; the rest grow into its space. A
    /// removed active pane hands that role to the first pane of the sibling that
    /// absorbed its space.
    fileprivate mutating func removePane(_ windowID: String) {
        guard let remaining = panes.removing(windowID) else { return }
        let successor = panes.successor(ofRemoved: windowID)
        let wasActive = windowID == activeWindowID
        setPanes(remaining)
        if wasActive, let successor { activeWindowID = successor }
    }

    private enum CodingKeys: String, CodingKey {
        case id, panes, widthFraction, activeWindowID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(String.self, forKey: .id),
            panes: try values.decodeIfPresent(PaneTree.self, forKey: .panes) ?? Self.emptyPanes,
            widthFraction: try values.decodeIfPresent(Double.self, forKey: .widthFraction)
                ?? SpaceState.defaultWidthFraction,
            activeWindowID: try values.decodeIfPresent(String.self, forKey: .activeWindowID)
        )
    }
}

/// A space's ribbon: ordered tiles. A window appears at most once per space,
/// tiles are never empty, and the focused window is its tile's active pane.
/// A window can belong to several spaces; tile layouts are per space.
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
    /// Every window, tile by tile, in reading order. Derived from `tiles` and
    /// rebuilt on each change, so per-frame readers do not allocate.
    public private(set) var windowIDs: [String] = []
    private var tileIndexByWindowID: [String: Int] = [:]
    public fileprivate(set) var focusedWindowID: String?
    /// The display the space belongs to. Nil means the fallback display.
    public fileprivate(set) var displayAnchor: DisplayID?

    /// A space whose windows each have a tile of their own.
    public init(
        windowIDs: [String] = [],
        focusedWindowID: String? = nil,
        widthFractions: [String: Double] = [:]
    ) {
        self.init(
            tiles: windowIDs.map {
                Tile(windowID: $0, widthFraction: widthFractions[$0] ?? Self.defaultWidthFraction)
            },
            focusedWindowID: focusedWindowID
        )
    }

    /// Drops empty tiles and any window already placed in an earlier tile,
    /// and makes tile IDs unique.
    public init(tiles: [Tile], focusedWindowID: String? = nil, displayAnchor: DisplayID? = nil) {
        var seen = Set<String>()
        var usedIDs = Set<String>()
        var kept: [Tile] = []
        for tile in tiles {
            guard let panes = tile.panes.restricted(to: { !$0.isEmpty && seen.insert($0).inserted }) else { continue }
            let id = Self.uniqueTileID(tile.id.isEmpty ? panes.windowIDs[0] : tile.id, used: usedIDs)
            usedIDs.insert(id)
            kept.append(Tile(id: id, panes: panes, widthFraction: tile.widthFraction,
                             activeWindowID: tile.activeWindowID))
        }
        self.tiles = kept
        self.focusedWindowID = nil
        self.displayAnchor = displayAnchor
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

    /// The width keys, presets and `setWidthFraction` act on this width.
    public func tileWidthFraction(containing windowID: String) -> Double {
        tileIndex(of: windowID).map { tiles[$0].widthFraction } ?? Self.defaultWidthFraction
    }

    /// The width a window takes when it leaves its tile: its pane's share of the
    /// tile's width, so it keeps roughly the width it had.
    public func paneWidthFraction(of windowID: String) -> Double {
        tileIndex(of: windowID).map { tiles[$0].paneWidthFraction(of: windowID) } ?? Self.defaultWidthFraction
    }

    fileprivate static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidthFraction }
        return min(max(value, minimumWidthFraction), maximumWidthFraction)
    }

    fileprivate static func uniqueTileID(_ base: String, used: Set<String>) -> String {
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

    /// Focuses a window and makes it its tile's active pane.
    fileprivate mutating func setFocus(windowID: String) {
        guard let index = tileIndex(of: windowID) else { return }
        if tiles[index].activeWindowID != windowID { tiles[index].activeWindowID = windowID }
        focusedWindowID = windowID
    }

    /// A one-window tile for `windowID` with an ID unused in this space.
    fileprivate func newTile(windowID: String, width: Double) -> Tile {
        Tile(id: Self.uniqueTileID(windowID, used: Set(tiles.map(\.id))), windowID: windowID, widthFraction: width)
    }

    /// Adds a window as its own tile after the focused tile.
    fileprivate mutating func insert(windowID: String, width: Double, focus: Bool) {
        guard !windowID.isEmpty, !contains(windowID: windowID) else { return }
        let insertionIndex = focusedTileIndex.map { $0 + 1 } ?? tiles.endIndex
        tiles.insert(newTile(windowID: windowID, width: width), at: insertionIndex)
        if focus || focusedWindowID == nil { setFocus(windowID: windowID) }
    }

    /// A focused window that leaves a multi-pane tile hands focus to the pane
    /// that absorbs its space; a window alone in its tile hands it to the next
    /// tile's active pane, or the previous tile's.
    fileprivate mutating func remove(windowID: String) {
        guard let index = tileIndex(of: windowID) else { return }
        if tiles[index].isMultiPane {
            tiles[index].removePane(windowID)
            if focusedWindowID == windowID { setFocus(windowID: tiles[index].activeWindowID) }
        } else {
            tiles.remove(at: index)
            if focusedWindowID == windowID {
                focusedWindowID = nil
                if !tiles.isEmpty { setFocus(windowID: tiles[min(index, tiles.count - 1)].activeWindowID) }
            }
        }
    }

    /// Puts a window that is not a member back into the tile holding its nearest
    /// saved tile-mate (in the saved reading order, earlier ones first). When
    /// that tile is the saved one minus this window, the saved layout returns
    /// whole; otherwise the window goes beside that mate, on the side it had.
    /// The tile keeps its current width, which may be a resize made while the
    /// window was away, plus the width the window took beside its saved mates;
    /// above or below them it adds none. False when no mate is here.
    fileprivate mutating func rejoin(windowID: String, savedTile: Tile) -> Bool {
        let savedOrder = savedTile.windowIDs
        guard !contains(windowID: windowID), let position = savedOrder.firstIndex(of: windowID) else { return false }
        let earlier = savedOrder[..<position].reversed().first { contains(windowID: $0) }
        let later = savedOrder[(position + 1)...].first { contains(windowID: $0) }
        guard let mate = earlier ?? later, let tile = tileIndex(of: mate) else { return false }
        let current = tiles[tile].panes
        guard let saved = savedTile.panes.restricted(to: { $0 == windowID || current.contains($0) }) else {
            return false
        }
        if saved.removing(windowID) == current {
            tiles[tile].setPanes(saved)
        } else {
            tiles[tile].setPanes(current.inserting(windowID, beside: mate,
                                                   along: saved.separatingAxis(windowID, mate) ?? .vertical,
                                                   after: earlier != nil))
        }
        let mates = Set(saved.windowIDs).subtracting([windowID])
        let addedSpan = savedTile.panes.horizontalSpan(of: mates.union([windowID]))
            - savedTile.panes.horizontalSpan(of: mates)
        if addedSpan > 0 {
            tiles[tile].widthFraction = Self.clampedWidth(tiles[tile].widthFraction
                + savedTile.widthFraction * Double(addedSpan))
        }
        return true
    }

    /// Takes a window out of its tile and returns it as a tile of its own with
    /// its pane's width. A window alone in its tile takes that tile, ID
    /// included. Focus is the caller's to restore.
    fileprivate mutating func detach(windowID: String) -> Tile? {
        guard let index = tileIndex(of: windowID) else { return nil }
        guard tiles[index].isMultiPane else { return tiles.remove(at: index) }
        let width = tiles[index].paneWidthFraction(of: windowID)
        tiles[index].removePane(windowID)
        return newTile(windowID: windowID, width: width)
    }

    private enum CodingKeys: String, CodingKey {
        case tiles, focusedWindowID, displayAnchor
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tiles: try values.decodeIfPresent([Tile].self, forKey: .tiles) ?? [],
            focusedWindowID: try values.decodeIfPresent(String.self, forKey: .focusedWindowID),
            displayAnchor: try values.decodeIfPresent(DisplayID.self, forKey: .displayAnchor)
        )
    }
}

public enum TileArrangement: Equatable, Sendable {
    case arranged
    case unchanged
    case notEnoughWindows(needed: Int, available: Int)
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let spaceCount = 9

    public var isPaused: Bool
    public private(set) var spaces: [SpaceState]
    /// The focused space; its display is the focused display.
    public private(set) var activeSpaceIndex: Int
    /// The space each other display shows.
    public private(set) var shownSpaceIndices: [DisplayID: Int]
    /// Runtime only, never saved.
    public private(set) var displays = DisplayList()

    public var currentSpace: SpaceState { spaces[activeSpaceIndex] }
    public var focusedWindowID: String? { currentSpace.focusedWindowID }
    /// The focused display's picker: its occupied spaces and the active space.
    public var displayedSpaceIndices: [Int] {
        spaces.indices.filter {
            $0 == activeSpaceIndex || (!spaces[$0].windowIDs.isEmpty && display(ofSpace: $0) == focusedDisplay)
        }
    }

    public init(
        isPaused: Bool = false,
        spaces: [SpaceState] = [],
        activeSpaceIndex: Int = 0,
        shownSpaceIndices: [DisplayID: Int] = [:]
    ) {
        self.isPaused = isPaused
        self.spaces = Array(spaces.prefix(Self.spaceCount))
        self.spaces.append(contentsOf: repeatElement(SpaceState(), count: Self.spaceCount - self.spaces.count))
        self.activeSpaceIndex = min(max(activeSpaceIndex, 0), Self.spaceCount - 1)
        self.shownSpaceIndices = shownSpaceIndices.filter { (0..<Self.spaceCount).contains($0.value) }
    }

    /// Restore returning windows without undoing changes to windows already in the workspace.
    public mutating func restoreMemberships(windowIDs: Set<String>, from savedState: WorkspaceState) {
        let returningIDs = windowIDs.subtracting(spaces.flatMap(\.windowIDs))
        for index in spaces.indices {
            let savedSpace = savedState.spaces[index]
            for (offset, windowID) in savedSpace.windowIDs.enumerated() where returningIDs.contains(windowID) {
                if let savedTile = savedSpace.tileIndex(of: windowID).map({ savedSpace.tiles[$0] }),
                   savedTile.isMultiPane, spaces[index].rejoin(windowID: windowID, savedTile: savedTile) {
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
                    spaces[index].newTile(windowID: windowID, width: savedSpace.paneWidthFraction(of: windowID)),
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
    /// Only globally unknown windows are added: to the space shown on the display
    /// `displayOfWindow` names, else to the active space.
    public mutating func reconcile(
        windowIDs: [String],
        initialWidthFractions: [String: Double] = [:],
        displayOfWindow: ((String) -> DisplayID?)? = nil
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
            let space = displayOfWindow?(windowID).flatMap(shownSpaceIndex(on:)) ?? activeSpaceIndex
            spaces[space].insert(
                windowID: windowID,
                width: initialWidthFractions[windowID] ?? SpaceState.defaultWidthFraction,
                focus: true
            )
        }
        if wasOccupied && currentSpace.windowIDs.isEmpty {
            // Keep numbered shortcuts stable; empty spaces disappear from the picker.
            activate(spaceAt: spaces.indices.last(where: { $0 < activeSpaceIndex && !spaces[$0].windowIDs.isEmpty })
                ?? spaces.indices.first(where: { !spaces[$0].windowIDs.isEmpty }) ?? 0)
        }
    }

    /// Remove an empty numbered space so later spaces move down together. A
    /// display's only space stays, so the display keeps its number.
    @discardableResult
    public mutating func closeEmptySpace(at index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].windowIDs.isEmpty,
              spaces[(index + 1)...].contains(where: { !$0.windowIDs.isEmpty }),
              !isOnlySpaceOfItsDisplay(index) else { return false }
        discardSpace(at: index)
        return true
    }

    /// Opens an empty numbered space at `index`; it and later spaces move up one.
    /// Fails when the last space is occupied, active or a display's only space,
    /// since it would be dropped.
    @discardableResult
    public mutating func openSpace(at index: Int) -> Bool {
        let last = Self.spaceCount - 1
        guard spaces.indices.contains(index), spaces[last].windowIDs.isEmpty,
              activeSpaceIndex != last, !isOnlySpaceOfItsDisplay(last) else { return false }
        spaces.removeLast()
        spaces.insert(SpaceState(), at: index)
        if activeSpaceIndex >= index { activeSpaceIndex += 1 }
        shownSpaceIndices = shownSpaceIndices.compactMapValues { shown in
            let moved = shown >= index ? shown + 1 : shown
            return moved < Self.spaceCount ? moved : nil
        }
        dropFocusedDisplayFromShownSpaces()
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
    /// its nearest saved tile-mate, as a relaunched window returning to its tile.
    /// `savedTile` holds this window's ID in its own pane. Keeps the space's focus
    /// and the tile's width. False when none of its mates is in the space.
    @discardableResult
    public mutating func rejoin(windowID: String, savedTile: Tile, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty else { return false }
        return spaces[index].rejoin(windowID: windowID, savedTile: savedTile)
    }

    /// Keep a saved membership snapshot aligned after the corresponding live space closes.
    /// A display left without a space takes the lowest empty unanchored one.
    public mutating func discardSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        spaces.remove(at: index)
        spaces.append(SpaceState())
        if activeSpaceIndex > index { activeSpaceIndex -= 1 }
        shownSpaceIndices = shownSpaceIndices.compactMapValues { shown in
            shown == index ? nil : shown > index ? shown - 1 : shown
        }
        anchorDisplaysWithoutSpaces()
        dropFocusedDisplayFromShownSpaces()
    }

    @discardableResult
    public mutating func focus(windowID: String) -> Bool {
        focus(windowID: windowID, inSpace: activeSpaceIndex)
    }

    @discardableResult
    public mutating func focus(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID),
              activeSpaceIndex != index || spaces[index].focusedWindowID != windowID else { return false }
        activate(spaceAt: index)
        spaces[index].setFocus(windowID: windowID)
        return true
    }

    /// Moves a member, as a tile of its own, directly after the space's focused
    /// tile, then focuses it there, as macOS does when the user reopens a window.
    /// A window in a multi-pane tile leaves it.
    @discardableResult
    public mutating func placeAfterFocused(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID) else { return false }
        if let anchor = spaces[index].focusedWindowID, anchor != windowID,
           let tile = spaces[index].detach(windowID: windowID) {
            let anchorIndex = spaces[index].tileIndex(of: anchor) ?? spaces[index].tiles.endIndex - 1
            spaces[index].tiles.insert(tile, at: anchorIndex + 1)
        }
        activate(spaceAt: index)
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

    // MARK: - Panes

    /// Adds a window as a pane spanning the `edge` of the tile at `tileIndex`,
    /// taking it out of its own tile. Joining at a side adds the window's width
    /// to the tile's, up to the whole display; joining at the top or bottom
    /// keeps the tile's width. A focused window keeps focus.
    @discardableResult
    public mutating func join(windowID: String, intoTileAt tileIndex: Int, edge: TileEdge,
                              inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].tiles.indices.contains(tileIndex),
              let source = spaces[index].tileIndex(of: windowID), source != tileIndex else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        let joinerWidth = spaces[index].paneWidthFraction(of: windowID)
        let sourceDisappears = !spaces[index].tiles[source].isMultiPane
        _ = spaces[index].detach(windowID: windowID)
        let target = sourceDisappears && source < tileIndex ? tileIndex - 1 : tileIndex
        var tile = spaces[index].tiles[target]
        tile.setPanes(tile.panes.joining(windowID, at: edge))
        if edge.axis == .horizontal {
            tile.widthFraction = SpaceState.clampedWidth(tile.widthFraction + joinerWidth)
        }
        spaces[index].tiles[target] = tile
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Takes a window out of its multi-pane tile as a tile of its own, directly
    /// before it (`direction` < 0) or after it, with its pane's width. A focused
    /// window keeps focus.
    @discardableResult
    public mutating func expel(windowID: String, toward direction: Int, inSpace index: Int) -> Bool {
        guard direction != 0, spaces.indices.contains(index),
              let source = spaces[index].tileIndex(of: windowID) else { return false }
        return expel(windowID: windowID, toTileAt: direction < 0 ? source : source + 1, inSpace: index)
    }

    /// Takes a window out of its multi-pane tile as a tile of its own at tile
    /// index `position`, counted with its tile still in place, with its pane's
    /// width. A focused window keeps focus.
    @discardableResult
    public mutating func expel(windowID: String, toTileAt position: Int, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index),
              let source = spaces[index].tileIndex(of: windowID),
              spaces[index].tiles[source].isMultiPane else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        guard let tile = spaces[index].detach(windowID: windowID) else { return false }
        spaces[index].tiles.insert(tile, at: min(max(position, 0), spaces[index].tiles.count))
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Exchanges a window's pane with the pane on `direction`'s side in its
    /// tile. The weights stay with the positions; focus stays on the window.
    @discardableResult
    public mutating func swapPane(windowID: String, direction: PaneDirection, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), let tile = spaces[index].tileIndex(of: windowID),
              let other = spaces[index].tiles[tile].panes.neighbor(of: windowID, toward: direction) else { return false }
        spaces[index].tiles[tile].setPanes(spaces[index].tiles[tile].panes.swapping(windowID, other))
        return true
    }

    /// Swaps a window's pane with the pane under `point`, in the tile's unit square.
    @discardableResult
    public mutating func movePane(windowID: String, to point: CGPoint, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), let tile = spaces[index].tileIndex(of: windowID),
              let other = spaces[index].tiles[tile].panes.pane(at: point), other != windowID else { return false }
        spaces[index].tiles[tile].setPanes(spaces[index].tiles[tile].panes.swapping(windowID, other))
        return true
    }

    /// Moves focus to the neighboring pane on that side. Left and right go on
    /// into the adjacent tile, entering at its facing edge; up and down stay in
    /// the tile. Nothing happens at an end.
    @discardableResult
    public mutating func focusPane(direction: PaneDirection) -> Bool {
        guard let windowID = focusedWindowID, let index = currentSpace.tileIndex(of: windowID) else { return false }
        let tile = currentSpace.tiles[index]
        if let neighbor = tile.panes.neighbor(of: windowID, toward: direction) {
            spaces[activeSpaceIndex].setFocus(windowID: neighbor)
            return true
        }
        let target = index + (direction.isForward ? 1 : -1)
        guard direction.axis == .horizontal, currentSpace.tiles.indices.contains(target),
              let origin = tile.panes.unitFrame(of: windowID) else { return false }
        let entered = currentSpace.tiles[target]
        let entry = entered.panes.entryPane(movingToward: direction, verticalRange: origin.minY...origin.maxY,
                                            active: entered.activeWindowID) ?? entered.activeWindowID
        spaces[activeSpaceIndex].setFocus(windowID: entry)
        return true
    }

    /// The focused window swaps with the pane on that side; at its tile's edge
    /// it leaves as its own tile on that side; alone in its tile, it joins the
    /// neighboring tile at the facing edge. Focus stays on it.
    @discardableResult
    public mutating func moveFocusedWindowSideways(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID,
              let tile = currentSpace.tileIndex(of: windowID) else { return false }
        if swapPane(windowID: windowID, direction: direction > 0 ? .right : .left, inSpace: activeSpaceIndex) {
            return true
        }
        if currentSpace.tiles[tile].isMultiPane {
            return expel(windowID: windowID, toward: direction, inSpace: activeSpaceIndex)
        }
        let target = tile + direction.signum()
        guard currentSpace.tiles.indices.contains(target) else { return false }
        return join(windowID: windowID, intoTileAt: target, edge: direction > 0 ? .left : .right,
                    inSpace: activeSpaceIndex)
    }

    /// The focused window swaps with the pane above (`direction` < 0) or below.
    @discardableResult
    public mutating func moveFocusedWindowVertically(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID else { return false }
        return swapPane(windowID: windowID, direction: direction > 0 ? .down : .up, inSpace: activeSpaceIndex)
    }

    /// Gives `windowID`'s side of the split that separates it from `neighborID`
    /// `fraction` of the two sides' combined share, in the current space. The
    /// rest of the tile keeps its sizes.
    @discardableResult
    public mutating func setSplitShares(windowID: String, neighborID: String, fraction: Double) -> Bool {
        guard fraction.isFinite, fraction > 0, fraction < 1, windowID != neighborID,
              let tile = currentSpace.tileIndex(of: windowID), currentSpace.tileIndex(of: neighborID) == tile,
              let panes = currentSpace.tiles[tile].panes.settingShares(windowID, neighborID, fraction: fraction)
        else { return false }
        spaces[activeSpaceIndex].tiles[tile].setPanes(panes)
        return true
    }

    /// Lays out the current space's tile holding `windowID` as `layout`. `single`
    /// breaks it into one tile per window, in place. Other layouts take the
    /// windows they lack from the following tiles, then the preceding ones,
    /// nearest first, and expel windows beyond the layout's panes as tiles of
    /// their own just after it. Every window keeps its reading-order rank in the
    /// space, and the focused window keeps focus.
    @discardableResult
    public mutating func arrange(tileOf windowID: String, layout: PaneLayout) -> TileArrangement {
        guard let tileIndex = currentSpace.tileIndex(of: windowID) else { return .unchanged }
        var space = currentSpace
        let tile = space.tiles[tileIndex]
        let focused = space.focusedWindowID
        if layout == .single {
            guard tile.isMultiPane else { return .unchanged }
            var usedIDs = Set(space.tiles.map(\.id))
            let parts = tile.windowIDs.enumerated().map { offset, id in
                let tileID = offset == 0 ? tile.id : SpaceState.uniqueTileID(id, used: usedIDs)
                usedIDs.insert(tileID)
                return Tile(id: tileID, windowID: id, widthFraction: tile.paneWidthFraction(of: id))
            }
            space.tiles.replaceSubrange(tileIndex...tileIndex, with: parts)
        } else {
            let needed = layout.paneCount
            guard space.windowIDs.count >= needed else {
                return .notEnoughWindows(needed: needed, available: space.windowIDs.count)
            }
            var following: [String] = []
            var preceding: [String] = []
            if tile.windowIDs.count < needed {
                for id in space.tiles[(tileIndex + 1)...].flatMap(\.windowIDs)
                where tile.windowIDs.count + following.count < needed {
                    following.append(id)
                }
                for id in space.tiles[..<tileIndex].flatMap(\.windowIDs).reversed()
                where tile.windowIDs.count + following.count + preceding.count < needed {
                    preceding.append(id)
                }
            }
            let ordered = preceding.reversed() + tile.windowIDs + following
            let kept = Array(ordered.prefix(needed))
            let extras = ordered.dropFirst(needed).map { ($0, tile.paneWidthFraction(of: $0)) }
            guard let panes = layout.tree(kept) else { return .unchanged }
            let active = focused.flatMap { kept.contains($0) ? $0 : nil }
                ?? (kept.contains(tile.activeWindowID) ? tile.activeWindowID : kept[0])
            let arranged = Tile(id: tile.id, panes: panes,
                                widthFraction: layout.spansTwoColumns ? SpaceState.maximumWidthFraction
                                    : tile.widthFraction,
                                activeWindowID: active)
            guard arranged != tile else { return .unchanged }
            for id in preceding + following { space.remove(windowID: id) }
            guard let position = space.tiles.firstIndex(where: { $0.id == tile.id }) else { return .unchanged }
            space.tiles[position] = arranged
            for (offset, extra) in extras.enumerated() {
                space.tiles.insert(space.newTile(windowID: extra.0, width: extra.1), at: position + 1 + offset)
            }
        }
        if let focused { space.setFocus(windowID: focused) }
        spaces[activeSpaceIndex] = space
        return .arranged
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
            width: spaces[sourceIndex].paneWidthFraction(of: windowID),
            focus: false
        )
        return true
    }

    @discardableResult
    public mutating func move(windowID: String, fromSpace sourceIndex: Int, toSpace destinationIndex: Int) -> Bool {
        guard spaces.indices.contains(sourceIndex), spaces.indices.contains(destinationIndex),
              sourceIndex != destinationIndex, spaces[sourceIndex].contains(windowID: windowID) else { return false }
        let width = spaces[sourceIndex].paneWidthFraction(of: windowID)
        spaces[destinationIndex].insert(windowID: windowID, width: width, focus: false)
        spaces[sourceIndex].remove(windowID: windowID)
        return true
    }

    @discardableResult
    public mutating func apply(_ action: NavigationAction,
                               widthPresets: [Double] = SpaceState.defaultWidthPresets) -> Bool {
        switch action {
        case .focusPrevious: return focusPane(direction: .left)
        case .focusNext: return focusPane(direction: .right)
        case .reorderPrevious: return reorderFocusedTile(by: -1)
        case .reorderNext: return reorderFocusedTile(by: 1)
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
            let width = (currentSpace.tileWidthFraction(containing: windowID) * 100 + adjustment * 100).rounded() / 100
            return setWidthFraction(width, for: windowID)
        case .nextWidthPreset, .previousWidthPreset:
            guard let windowID = focusedWindowID else { return false }
            let presets = SpaceState.normalizedWidthPresets(widthPresets)
            let current = currentSpace.tileWidthFraction(containing: windowID)
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
        case .focusPaneAbove: return focusPane(direction: .up)
        case .focusPaneBelow: return focusPane(direction: .down)
        case .moveWindowLeftInTile: return moveFocusedWindowSideways(by: -1)
        case .moveWindowRightInTile: return moveFocusedWindowSideways(by: 1)
        case .moveWindowUpInTile: return moveFocusedWindowVertically(by: -1)
        case .moveWindowDownInTile: return moveFocusedWindowVertically(by: 1)
        case .arrangeTile(let layout):
            guard let focusedWindowID else { return false }
            return arrange(tileOf: focusedWindowID, layout: layout) == .arranged
        case .moveSpaceToDisplay(let direction):
            guard let display = displayBesideFocused(by: direction) else { return false }
            return moveSpace(activeSpaceIndex, toDisplay: display)
        }
    }

    private mutating func reorderFocusedTile(by direction: Int) -> Bool {
        guard let index = currentSpace.focusedTileIndex,
              currentSpace.tiles.indices.contains(index + direction) else { return false }
        spaces[activeSpaceIndex].tiles.swapAt(index, index + direction)
        return true
    }

    private mutating func goToSpace(index: Int) -> Bool {
        guard spaces.indices.contains(index), index != activeSpaceIndex else { return false }
        activate(spaceAt: index)
        return true
    }

    private mutating func moveFocusedWindow(toSpace index: Int, follow: Bool) -> Bool {
        guard spaces.indices.contains(index), index != activeSpaceIndex,
              let windowID = focusedWindowID else { return false }
        spaces[index].insert(windowID: windowID, width: currentSpace.paneWidthFraction(of: windowID), focus: false)
        spaces[activeSpaceIndex].remove(windowID: windowID)
        if follow {
            activate(spaceAt: index)
            spaces[index].setFocus(windowID: windowID)
        }
        return true
    }

    // MARK: - Displays

    /// The display that holds the focused space; nil while displays are not modeled.
    public var focusedDisplay: DisplayID? { display(ofSpace: activeSpaceIndex) }

    /// Sets the connected displays, left to right. A display with no space takes
    /// the lowest-numbered empty space that has no anchor and is not shown,
    /// which is returned; without one it stays unmanaged. Anchors are never
    /// cleared here, so a display's spaces return when it reconnects.
    @discardableResult
    public mutating func setDisplays(_ ids: [DisplayID], fallback: DisplayID?) -> [DisplayID: Int] {
        var connected: [DisplayID] = []
        for id in ids where !connected.contains(id) { connected.append(id) }
        displays = DisplayList(ids: connected,
                               fallback: fallback.flatMap { connected.contains($0) ? $0 : nil } ?? connected.first)
        let anchored = anchorDisplaysWithoutSpaces()
        dropFocusedDisplayFromShownSpaces()
        return anchored
    }

    /// The space's anchor while that display is connected, else the fallback.
    public func display(ofSpace index: Int) -> DisplayID? {
        guard spaces.indices.contains(index), let fallback = displays.fallback else { return nil }
        guard let anchor = spaces[index].displayAnchor, displays.ids.contains(anchor) else { return fallback }
        return anchor
    }

    /// The focused display shows the active space. Another shows the space it
    /// last showed while that space is still on it, else its lowest-numbered
    /// occupied space, else its lowest-numbered space; nil when it has none.
    public func shownSpaceIndex(on display: DisplayID) -> Int? {
        guard displays.ids.contains(display) else { return nil }
        if display == focusedDisplay { return activeSpaceIndex }
        if let shown = shownSpaceIndices[display], self.display(ofSpace: shown) == display { return shown }
        let onDisplay = spaces.indices.filter { self.display(ofSpace: $0) == display }
        return onDisplay.first { !spaces[$0].windowIDs.isEmpty } ?? onDisplay.first
    }

    /// A display's picker: its occupied spaces and the space it shows.
    public func displayedSpaceIndices(on display: DisplayID) -> [Int] {
        guard let shown = shownSpaceIndex(on: display) else { return [] }
        return spaces.indices.filter {
            $0 == shown || (!spaces[$0].windowIDs.isEmpty && self.display(ofSpace: $0) == display)
        }
    }

    /// Anchors a space to a connected display. The active space keeps focus,
    /// so the focused display becomes `display`; another space is shown there.
    @discardableResult
    public mutating func moveSpace(_ index: Int, toDisplay display: DisplayID) -> Bool {
        guard displays.ids.count > 1, displays.ids.contains(display), let source = self.display(ofSpace: index),
              source != display else { return false }
        spaces[index].displayAnchor = display
        if shownSpaceIndices[source] == index { shownSpaceIndices[source] = nil }
        if index != activeSpaceIndex { shownSpaceIndices[display] = index }
        anchorDisplaysWithoutSpaces()
        dropFocusedDisplayFromShownSpaces()
        return true
    }

    /// ⌃⌥←/→ from the keyboard: the ribbon step, and at the ribbon's end, the
    /// space shown on the neighboring display that way. Focus enters it at the
    /// facing edge of `visibleTiles(space)` (its tile indices on screen; nil
    /// means its focused tile), then by the pane entry rule. Swipes never cross.
    @discardableResult
    public mutating func focusWindowCrossingDisplays(
        by direction: Int,
        visibleTiles: (Int) -> ClosedRange<Int>? = { _ in nil }
    ) -> Bool {
        guard direction != 0 else { return false }
        if apply(direction > 0 ? .focusNext : .focusPrevious) { return true }
        guard let display = displayBesideFocused(by: direction),
              let target = shownSpaceIndex(on: display) else { return false }
        let origin = focusedWindowID.flatMap { id in
            currentSpace.tileIndex(of: id).flatMap { currentSpace.tiles[$0].panes.unitFrame(of: id) }
        }
        let space = spaces[target]
        let entryTile = space.tiles.isEmpty ? nil : visibleTiles(target)
            .map { min(max(direction > 0 ? $0.lowerBound : $0.upperBound, 0), space.tiles.count - 1) }
            ?? space.focusedTileIndex
        activate(spaceAt: target)
        if let entryTile {
            let tile = space.tiles[entryTile]
            let entry = tile.panes.entryPane(movingToward: direction > 0 ? .right : .left,
                                             verticalRange: origin.map { $0.minY...$0.maxY } ?? 0...1,
                                             active: tile.activeWindowID) ?? tile.activeWindowID
            spaces[target].setFocus(windowID: entry)
        }
        return true
    }

    private func displayBesideFocused(by direction: Int) -> DisplayID? {
        guard direction != 0, displays.ids.count > 1, let focused = focusedDisplay,
              let position = displays.ids.firstIndex(of: focused) else { return nil }
        let neighbor = position + direction.signum()
        return displays.ids.indices.contains(neighbor) ? displays.ids[neighbor] : nil
    }

    /// Makes `index` the active space. The display focus leaves keeps showing
    /// the space it had.
    private mutating func activate(spaceAt index: Int) {
        let previous = activeSpaceIndex
        let previousDisplay = focusedDisplay
        activeSpaceIndex = index
        if let previousDisplay, previousDisplay != focusedDisplay { shownSpaceIndices[previousDisplay] = previous }
        dropFocusedDisplayFromShownSpaces()
    }

    private mutating func dropFocusedDisplayFromShownSpaces() {
        if let focusedDisplay { shownSpaceIndices[focusedDisplay] = nil }
    }

    private func isOnlySpaceOfItsDisplay(_ index: Int) -> Bool {
        guard displays.ids.count > 1, let display = display(ofSpace: index) else { return false }
        return !spaces.indices.contains { $0 != index && self.display(ofSpace: $0) == display }
    }

    @discardableResult
    private mutating func anchorDisplaysWithoutSpaces() -> [DisplayID: Int] {
        guard displays.ids.count > 1 else { return [:] }
        var anchored: [DisplayID: Int] = [:]
        for display in displays.ids where !spaces.indices.contains(where: { self.display(ofSpace: $0) == display }) {
            let shown = Set(displays.ids.compactMap(shownSpaceIndex(on:)))
            guard let free = spaces.indices.first(where: {
                spaces[$0].windowIDs.isEmpty && spaces[$0].displayAnchor == nil && !shown.contains($0)
            }) else { continue }
            spaces[free].displayAnchor = display
            anchored[display] = free
        }
        return anchored
    }

    private enum CodingKeys: String, CodingKey {
        case isPaused, spaces, activeSpaceIndex, shownSpaceIndices
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isPaused: try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
            spaces: try values.decodeIfPresent([SpaceState].self, forKey: .spaces) ?? [],
            activeSpaceIndex: try values.decodeIfPresent(Int.self, forKey: .activeSpaceIndex) ?? 0,
            shownSpaceIndices: try values.decodeIfPresent([DisplayID: Int].self, forKey: .shownSpaceIndices) ?? [:]
        )
    }
}

extension Sequence where Element == SpaceState {
    /// The number of spaces that contain the window.
    public func membershipCount(of windowID: String) -> Int {
        count { $0.contains(windowID: windowID) }
    }
}
