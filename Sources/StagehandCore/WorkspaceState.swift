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

    /// Commands for Stagehand itself. They never move focus, so their chords pass
    /// through the keyboard tap to Carbon instead of reserving a focus transfer.
    public var isStagehandCommand: Bool {
        switch self {
        case .togglePause, .showSettings, .toggleShortcutHints: true
        default: false
        }
    }
}

/// One ribbon slot: windows stacked top to bottom that share one width.
public struct ColumnState: Codable, Equatable, Sendable {
    public static let defaultHeightWeight = 1.0

    /// Stable for the column's life in its space. A new column takes the ID of the
    /// window that starts it, made unique within the space; it does not follow
    /// that window when it leaves.
    public let id: String
    /// Members top to bottom. Never empty inside a `SpaceState`.
    public fileprivate(set) var windowIDs: [String]
    public fileprivate(set) var widthFraction: Double
    /// The member that horizontal focus enters; the focused window when this
    /// column holds focus.
    public fileprivate(set) var activeWindowID: String
    /// Each member's relative share of a stack's height, parallel to `windowIDs`.
    public fileprivate(set) var heightWeights: [Double]

    public var isStack: Bool { windowIDs.count > 1 }

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

/// A space's ribbon: ordered columns. A window appears at most once per space,
/// columns are never empty, and the focused window is its column's active member.
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

    /// Ribbon slots, left to right.
    public fileprivate(set) var columns: [ColumnState] {
        didSet { indexMembers() }
    }
    /// Every member, column by column, top to bottom. Derived from `columns` and
    /// rebuilt on each change, so per-frame readers do not allocate.
    public private(set) var windowIDs: [String] = []
    private var columnIndexByWindowID: [String: Int] = [:]
    public fileprivate(set) var focusedWindowID: String?

    /// A space whose windows each have a column of their own.
    public init(
        windowIDs: [String] = [],
        focusedWindowID: String? = nil,
        widthFractions: [String: Double] = [:]
    ) {
        self.init(
            columns: windowIDs.map {
                ColumnState(windowIDs: [$0], widthFraction: widthFractions[$0] ?? Self.defaultWidthFraction)
            },
            focusedWindowID: focusedWindowID
        )
    }

    /// Drops empty columns and any window already placed in an earlier column,
    /// and makes column IDs unique.
    public init(columns: [ColumnState], focusedWindowID: String? = nil) {
        var seen = Set<String>()
        var usedIDs = Set<String>()
        var kept: [ColumnState] = []
        for column in columns {
            let indices = column.windowIDs.indices.filter { seen.insert(column.windowIDs[$0]).inserted }
            guard let first = indices.first else { continue }
            let id = Self.uniqueColumnID(column.id.isEmpty ? column.windowIDs[first] : column.id, used: usedIDs)
            usedIDs.insert(id)
            kept.append(ColumnState(
                id: id,
                windowIDs: indices.map { column.windowIDs[$0] },
                widthFraction: column.widthFraction,
                activeWindowID: column.activeWindowID,
                heightWeights: indices.map { column.heightWeights[$0] }
            ))
        }
        self.columns = kept
        self.focusedWindowID = nil
        indexMembers()
        if let focus = focusedWindowID.flatMap({ seen.contains($0) ? $0 : nil }) ?? kept.first?.activeWindowID {
            setFocus(windowID: focus)
        }
    }

    public func contains(windowID: String) -> Bool {
        columnIndexByWindowID[windowID] != nil
    }

    public func columnIndex(of windowID: String) -> Int? {
        columnIndexByWindowID[windowID]
    }

    public var focusedColumnIndex: Int? {
        focusedWindowID.flatMap(columnIndex(of:))
    }

    /// The width of the window's column.
    public func widthFraction(for windowID: String) -> Double {
        columnIndex(of: windowID).map { columns[$0].widthFraction } ?? Self.defaultWidthFraction
    }

    fileprivate static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidthFraction }
        return min(max(value, minimumWidthFraction), maximumWidthFraction)
    }

    private static func uniqueColumnID(_ base: String, used: Set<String>) -> String {
        guard used.contains(base) else { return base }
        var suffix = 2
        while used.contains("\(base)#\(suffix)") { suffix += 1 }
        return "\(base)#\(suffix)"
    }

    private mutating func indexMembers() {
        var flat: [String] = []
        var index: [String: Int] = [:]
        for (columnIndex, column) in columns.enumerated() {
            for windowID in column.windowIDs {
                flat.append(windowID)
                index[windowID] = columnIndex
            }
        }
        windowIDs = flat
        columnIndexByWindowID = index
    }

    /// Focuses a member and makes it its column's active member.
    fileprivate mutating func setFocus(windowID: String) {
        guard let index = columnIndex(of: windowID) else { return }
        if columns[index].activeWindowID != windowID { columns[index].activeWindowID = windowID }
        focusedWindowID = windowID
    }

    /// A one-window column for `windowID` with an ID unused in this space.
    fileprivate func newColumn(windowID: String, width: Double) -> ColumnState {
        ColumnState(id: Self.uniqueColumnID(windowID, used: Set(columns.map(\.id))),
                    windowIDs: [windowID], widthFraction: width)
    }

    /// Adds a window as its own column after the focused column.
    fileprivate mutating func insert(windowID: String, width: Double, focus: Bool) {
        guard !windowID.isEmpty, !contains(windowID: windowID) else { return }
        let insertionIndex = focusedColumnIndex.map { $0 + 1 } ?? columns.endIndex
        columns.insert(newColumn(windowID: windowID, width: width), at: insertionIndex)
        if focus || focusedWindowID == nil { setFocus(windowID: windowID) }
    }

    /// A focused window that leaves hands focus to a column-mate (the one below,
    /// or above when it was the bottom member); a window alone in its column
    /// hands it to the next column's active member, or the previous column's.
    fileprivate mutating func remove(windowID: String) {
        guard let index = columnIndex(of: windowID),
              let member = columns[index].windowIDs.firstIndex(of: windowID) else { return }
        if columns[index].isStack {
            columns[index].removeMember(at: member)
            if focusedWindowID == windowID { setFocus(windowID: columns[index].activeWindowID) }
        } else {
            columns.remove(at: index)
            if focusedWindowID == windowID {
                focusedWindowID = nil
                if !columns.isEmpty { setFocus(windowID: columns[min(index, columns.count - 1)].activeWindowID) }
            }
        }
    }

    /// Puts a window that is not a member back between the column-mates it had.
    /// `savedMembers` is its saved column top to bottom, itself included. It joins
    /// the column of its nearest saved mate above (just below that mate), else of
    /// its nearest saved mate below (just above it). False when no mate is here.
    fileprivate mutating func rejoin(windowID: String, savedMembers: [String], heightWeight: Double) -> Bool {
        guard !contains(windowID: windowID), let position = savedMembers.firstIndex(of: windowID) else { return false }
        let above = savedMembers[..<position].reversed().first { contains(windowID: $0) }
        let below = savedMembers[(position + 1)...].first { contains(windowID: $0) }
        guard let mate = above ?? below, let column = columnIndex(of: mate),
              let mateIndex = columns[column].windowIDs.firstIndex(of: mate) else { return false }
        columns[column].insertMember(windowID, at: above != nil ? mateIndex + 1 : mateIndex,
                                     heightWeight: heightWeight)
        return true
    }

    /// Takes a window out of its column and returns it as a column of its own.
    /// A window alone in its column takes that column, ID included. Focus is the
    /// caller's to restore.
    fileprivate mutating func detach(windowID: String) -> ColumnState? {
        guard let index = columnIndex(of: windowID),
              let member = columns[index].windowIDs.firstIndex(of: windowID) else { return nil }
        guard columns[index].isStack else { return columns.remove(at: index) }
        let width = columns[index].widthFraction
        columns[index].removeMember(at: member)
        return newColumn(windowID: windowID, width: width)
    }

    private enum CodingKeys: String, CodingKey {
        case columns, focusedWindowID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            columns: try values.decodeIfPresent([ColumnState].self, forKey: .columns) ?? [],
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
                // A window that was stacked rejoins the column holding its saved
                // column-mates, between the same neighbors, with its saved share.
                if let savedColumn = savedSpace.columnIndex(of: windowID).map({ savedSpace.columns[$0] }),
                   savedColumn.isStack,
                   spaces[index].rejoin(windowID: windowID, savedMembers: savedColumn.windowIDs,
                                        heightWeight: savedColumn.heightWeight(for: windowID)) {
                    continue
                }
                // Insert before the next surviving neighbor's column, preserving the
                // current order of windows the user has already resumed and rearranged.
                // Otherwise a returning window comes back as a column of its own.
                let nextID = savedSpace.windowIDs.dropFirst(offset + 1)
                    .first { spaces[index].contains(windowID: $0) }
                let insertionIndex = nextID.flatMap { spaces[index].columnIndex(of: $0) }
                    ?? spaces[index].columns.endIndex
                spaces[index].columns.insert(
                    spaces[index].newColumn(windowID: windowID, width: savedSpace.widthFraction(for: windowID)),
                    at: insertionIndex
                )
            }
            if spaces[index].focusedWindowID == nil,
               let focus = savedSpace.focusedWindowID.flatMap({ spaces[index].contains(windowID: $0) ? $0 : nil })
                ?? spaces[index].columns.first?.activeWindowID {
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
            // Keep numbered shortcuts stable; empty slots disappear from the picker.
            activeSpaceIndex = spaces.indices.last(where: { $0 < activeSpaceIndex && !spaces[$0].windowIDs.isEmpty })
                ?? spaces.indices.first(where: { !spaces[$0].windowIDs.isEmpty }) ?? 0
        }
    }

    /// Remove an empty numbered slot so later spaces move down together.
    @discardableResult
    public mutating func closeEmptySpace(at index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].windowIDs.isEmpty,
              spaces[(index + 1)...].contains(where: { !$0.windowIDs.isEmpty }) else { return false }
        discardSpace(at: index)
        return true
    }

    /// Opens an empty numbered slot at `index`; it and later spaces move up one.
    /// Fails when the last slot is occupied or active, since it would be dropped.
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

    /// Adds a window that is not yet a member of the space as its own column at
    /// column index `position`, keeping the space's focus, as a relaunched window
    /// returning to its slot.
    @discardableResult
    public mutating func insert(windowID: String, inSpace index: Int, at position: Int, width: Double) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty,
              !spaces[index].contains(windowID: windowID) else { return false }
        let clamped = min(max(position, 0), spaces[index].columns.count)
        spaces[index].columns.insert(spaces[index].newColumn(windowID: windowID, width: width), at: clamped)
        if spaces[index].focusedWindowID == nil { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Adds a window that is not yet a member of the space into the column holding
    /// its nearest saved column-mate, as a relaunched stack member returning to its
    /// stack. `savedMembers` is its saved column top to bottom, with this window's
    /// ID in its own place. Keeps the space's focus and the column's width. False
    /// when none of its mates is in the space.
    @discardableResult
    public mutating func rejoin(windowID: String, savedMembers: [String], heightWeight: Double,
                                inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty else { return false }
        return spaces[index].rejoin(windowID: windowID, savedMembers: savedMembers, heightWeight: heightWeight)
    }

    /// Keep a saved membership snapshot aligned after the corresponding live slot closes.
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

    /// Moves a member, as a column of its own, directly after the space's focused
    /// column, then focuses it there, as macOS does when the user reopens a window.
    /// A stacked window leaves its stack.
    @discardableResult
    public mutating func placeAfterFocused(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].contains(windowID: windowID) else { return false }
        if let anchor = spaces[index].focusedWindowID, anchor != windowID,
           let column = spaces[index].detach(windowID: windowID) {
            let anchorIndex = spaces[index].columnIndex(of: anchor) ?? spaces[index].columns.endIndex - 1
            spaces[index].columns.insert(column, at: anchorIndex + 1)
        }
        activeSpaceIndex = index
        spaces[index].setFocus(windowID: windowID)
        return true
    }

    /// Moves the window's whole column to column index `index` in the current
    /// space, preserving focus and per-space widths.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int) -> Bool {
        reorderWindow(windowID: windowID, to: index, inSpace: activeSpaceIndex)
    }

    /// Moves the window's whole column to column index `index` without making the
    /// space active. While every column holds one window, a column index is a
    /// window index.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int, inSpace spaceIndex: Int) -> Bool {
        guard spaces.indices.contains(spaceIndex),
              let originalIndex = spaces[spaceIndex].columnIndex(of: windowID) else { return false }
        let destination = min(max(index, 0), spaces[spaceIndex].columns.count - 1)
        guard originalIndex != destination else { return false }
        var columns = spaces[spaceIndex].columns
        columns.insert(columns.remove(at: originalIndex), at: destination)
        spaces[spaceIndex].columns = columns
        return true
    }

    /// Moves a member to `position` within its own column, top to bottom. Its
    /// height weight moves with it; focus and width do not change.
    @discardableResult
    public mutating func reorderMember(windowID: String, to position: Int, inSpace spaceIndex: Int) -> Bool {
        guard spaces.indices.contains(spaceIndex),
              let column = spaces[spaceIndex].columnIndex(of: windowID),
              let member = spaces[spaceIndex].columns[column].windowIDs.firstIndex(of: windowID) else { return false }
        let destination = min(max(position, 0), spaces[spaceIndex].columns[column].windowIDs.count - 1)
        guard member != destination else { return false }
        spaces[spaceIndex].columns[column].moveMember(from: member, to: destination)
        return true
    }

    /// Adds a window at the bottom of the column at `columnIndex` in the space,
    /// taking that column's width. A focused window keeps focus.
    @discardableResult
    public mutating func stack(windowID: String, intoColumnAt columnIndex: Int, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].columns.indices.contains(columnIndex),
              let source = spaces[index].columnIndex(of: windowID), source != columnIndex else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        let sourceDisappears = !spaces[index].columns[source].isStack
        _ = spaces[index].detach(windowID: windowID)
        let target = sourceDisappears && source < columnIndex ? columnIndex - 1 : columnIndex
        spaces[index].columns[target].append(windowID: windowID)
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Takes a stacked window out of its column as a column of its own, directly
    /// before it (`direction` < 0) or after it, with the stack's width. A focused
    /// window keeps focus.
    @discardableResult
    public mutating func unstack(windowID: String, toward direction: Int, inSpace index: Int) -> Bool {
        guard direction != 0, spaces.indices.contains(index),
              let source = spaces[index].columnIndex(of: windowID),
              spaces[index].columns[source].isStack else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        guard let column = spaces[index].detach(windowID: windowID) else { return false }
        spaces[index].columns.insert(column, at: direction < 0 ? source : source + 1)
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Takes a stacked window out of its column as a column of its own at column
    /// index `position`, counted with its stack still in place, with the stack's
    /// width, as a member dropped outside its column. A focused window keeps focus.
    @discardableResult
    public mutating func unstack(windowID: String, toColumnAt position: Int, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index),
              let source = spaces[index].columnIndex(of: windowID),
              spaces[index].columns[source].isStack else { return false }
        let wasFocused = spaces[index].focusedWindowID == windowID
        guard let column = spaces[index].detach(windowID: windowID) else { return false }
        spaces[index].columns.insert(column, at: min(max(position, 0), spaces[index].columns.count))
        if wasFocused { spaces[index].setFocus(windowID: windowID) }
        return true
    }

    /// Sets a stacked member's relative share of its column's height in the
    /// current space. A window alone in its column has no share to set.
    @discardableResult
    public mutating func setHeightWeight(_ weight: Double, for windowID: String) -> Bool {
        guard weight.isFinite, weight > 0,
              let column = currentSpace.columnIndex(of: windowID), currentSpace.columns[column].isStack,
              let member = currentSpace.columns[column].windowIDs.firstIndex(of: windowID),
              currentSpace.columns[column].heightWeights[member] != weight else { return false }
        spaces[activeSpaceIndex].columns[column].heightWeights[member] = weight
        return true
    }

    /// The sideways stacking move for the focused window: alone in its column, it
    /// joins the neighboring column on that side at the bottom; in a stack, it
    /// leaves as its own column on that side. Focus stays on it.
    @discardableResult
    public mutating func moveFocusedWindowAcrossColumns(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID,
              let column = currentSpace.columnIndex(of: windowID) else { return false }
        if currentSpace.columns[column].isStack {
            return unstack(windowID: windowID, toward: direction, inSpace: activeSpaceIndex)
        }
        let target = column + direction.signum()
        guard currentSpace.columns.indices.contains(target) else { return false }
        return stack(windowID: windowID, intoColumnAt: target, inSpace: activeSpaceIndex)
    }

    /// Focuses the window above (`direction` < 0) or below the focused window in
    /// its column. Stops at the ends.
    @discardableResult
    public mutating func focusMember(by direction: Int) -> Bool {
        guard direction != 0, let windowID = focusedWindowID,
              let column = currentSpace.columnIndex(of: windowID) else { return false }
        let members = currentSpace.columns[column].windowIDs
        guard let member = members.firstIndex(of: windowID),
              members.indices.contains(member + direction.signum()) else { return false }
        spaces[activeSpaceIndex].setFocus(windowID: members[member + direction.signum()])
        return true
    }

    /// Sets the width of the window's column in the current space.
    @discardableResult
    public mutating func setWidthFraction(_ width: Double, for windowID: String) -> Bool {
        guard let column = currentSpace.columnIndex(of: windowID) else { return false }
        let value = SpaceState.clampedWidth(width)
        guard currentSpace.columns[column].widthFraction != value else { return false }
        spaces[activeSpaceIndex].columns[column].widthFraction = value
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
        }
    }

    /// Steps focus into the adjacent column's active member, or swaps the focused
    /// column with it.
    private mutating func navigateWindow(by direction: Int, reorder: Bool) -> Bool {
        guard let index = currentSpace.focusedColumnIndex,
              currentSpace.columns.indices.contains(index + direction) else { return false }
        if reorder {
            spaces[activeSpaceIndex].columns.swapAt(index, index + direction)
        } else {
            spaces[activeSpaceIndex].setFocus(windowID: currentSpace.columns[index + direction].activeWindowID)
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
