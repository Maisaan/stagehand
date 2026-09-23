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
    case shrinkHeight
    case growHeight
    case togglePause
    case showSettings
}

public struct SpaceState: Codable, Equatable, Sendable {
    public static let minimumWidthFraction = 0.25
    public static let maximumWidthFraction = 1.0
    public static let defaultWidthFraction = 0.95

    public fileprivate(set) var windowIDs: [String]
    public fileprivate(set) var focusedWindowID: String?
    public fileprivate(set) var widthFractions: [String: Double]

    public init(
        windowIDs: [String] = [],
        focusedWindowID: String? = nil,
        widthFractions: [String: Double] = [:]
    ) {
        var seen = Set<String>()
        self.windowIDs = windowIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.focusedWindowID = focusedWindowID.flatMap { seen.contains($0) ? $0 : nil }
            ?? self.windowIDs.first
        self.widthFractions = widthFractions.filter { seen.contains($0.key) }
            .mapValues(Self.clampedWidth)
    }

    public func widthFraction(for windowID: String) -> Double {
        widthFractions[windowID] ?? Self.defaultWidthFraction
    }

    fileprivate static func clampedWidth(_ value: Double) -> Double {
        guard value.isFinite else { return defaultWidthFraction }
        return min(max(value, minimumWidthFraction), maximumWidthFraction)
    }

    fileprivate mutating func insert(windowID: String, width: Double, focus: Bool) {
        guard !windowIDs.contains(windowID) else { return }
        let insertionIndex = focusedWindowID.flatMap { windowIDs.firstIndex(of: $0) }
            .map { $0 + 1 } ?? windowIDs.endIndex
        windowIDs.insert(windowID, at: insertionIndex)
        widthFractions[windowID] = Self.clampedWidth(width)
        if focus || focusedWindowID == nil { focusedWindowID = windowID }
    }

    fileprivate mutating func remove(windowID: String) {
        guard let index = windowIDs.firstIndex(of: windowID) else { return }
        windowIDs.remove(at: index)
        widthFractions.removeValue(forKey: windowID)
        if focusedWindowID == windowID {
            focusedWindowID = windowIDs.isEmpty ? nil : windowIDs[min(index, windowIDs.count - 1)]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case windowIDs, focusedWindowID, widthFractions
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowIDs: try values.decodeIfPresent([String].self, forKey: .windowIDs) ?? [],
            focusedWindowID: try values.decodeIfPresent(String.self, forKey: .focusedWindowID),
            widthFractions: try values.decodeIfPresent([String: Double].self, forKey: .widthFractions) ?? [:]
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
                // Insert before the next surviving neighbor, preserving the current
                // order of windows the user has already resumed and rearranged.
                let nextID = savedSpace.windowIDs.dropFirst(offset + 1)
                    .first { spaces[index].windowIDs.contains($0) }
                let insertionIndex = nextID.flatMap { spaces[index].windowIDs.firstIndex(of: $0) }
                    ?? spaces[index].windowIDs.endIndex
                spaces[index].windowIDs.insert(windowID, at: insertionIndex)
                spaces[index].widthFractions[windowID] = savedSpace.widthFractions[windowID]
            }
            if spaces[index].focusedWindowID == nil {
                spaces[index].focusedWindowID = savedSpace.focusedWindowID
                    .flatMap { spaces[index].windowIDs.contains($0) ? $0 : nil }
                    ?? spaces[index].windowIDs.first
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
        guard spaces.indices.contains(index), spaces[index].windowIDs.contains(windowID),
              activeSpaceIndex != index || spaces[index].focusedWindowID != windowID else { return false }
        activeSpaceIndex = index
        spaces[index].focusedWindowID = windowID
        return true
    }

    /// Uses the final index in the current space and preserves focus and per-space widths.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int) -> Bool {
        reorderWindow(windowID: windowID, to: index, inSpace: activeSpaceIndex)
    }

    /// Reorders a space without making it active.
    @discardableResult
    public mutating func reorderWindow(windowID: String, to index: Int, inSpace spaceIndex: Int) -> Bool {
        guard spaces.indices.contains(spaceIndex),
              let originalIndex = spaces[spaceIndex].windowIDs.firstIndex(of: windowID) else { return false }
        let destination = min(max(index, 0), spaces[spaceIndex].windowIDs.count - 1)
        guard originalIndex != destination else { return false }
        spaces[spaceIndex].windowIDs.remove(at: originalIndex)
        spaces[spaceIndex].windowIDs.insert(windowID, at: destination)
        return true
    }

    @discardableResult
    public mutating func setWidthFraction(_ width: Double, for windowID: String) -> Bool {
        guard currentSpace.windowIDs.contains(windowID) else { return false }
        let value = SpaceState.clampedWidth(width)
        guard currentSpace.widthFraction(for: windowID) != value else { return false }
        spaces[activeSpaceIndex].widthFractions[windowID] = value
        return true
    }

    /// Removing the final membership would orphan a live window, so it is a no-op.
    @discardableResult
    public mutating func removeFromCurrentSpace(windowID: String) -> Bool {
        remove(windowID: windowID, fromSpace: activeSpaceIndex)
    }

    @discardableResult
    public mutating func remove(windowID: String, fromSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].windowIDs.contains(windowID),
              spaces.filter({ $0.windowIDs.contains(windowID) }).count > 1 else { return false }
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
              sourceIndex != destinationIndex, spaces[sourceIndex].windowIDs.contains(windowID),
              !spaces[destinationIndex].windowIDs.contains(windowID) else { return false }
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
              sourceIndex != destinationIndex, spaces[sourceIndex].windowIDs.contains(windowID) else { return false }
        let width = spaces[sourceIndex].widthFraction(for: windowID)
        spaces[destinationIndex].insert(windowID: windowID, width: width, focus: false)
        spaces[sourceIndex].remove(windowID: windowID)
        return true
    }

    @discardableResult
    public mutating func apply(_ action: NavigationAction) -> Bool {
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
        case .shrinkHeight, .growHeight:
            return false
        case .togglePause:
            isPaused.toggle()
            return true
        case .showSettings:
            return false
        }
    }

    private mutating func navigateWindow(by direction: Int, reorder: Bool) -> Bool {
        guard let focusedWindowID,
              let index = currentSpace.windowIDs.firstIndex(of: focusedWindowID),
              currentSpace.windowIDs.indices.contains(index + direction) else { return false }
        if reorder {
            spaces[activeSpaceIndex].windowIDs.swapAt(index, index + direction)
        } else {
            spaces[activeSpaceIndex].focusedWindowID = currentSpace.windowIDs[index + direction]
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
            spaces[index].focusedWindowID = windowID
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

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isPaused, forKey: .isPaused)
        try values.encode(spaces, forKey: .spaces)
        try values.encode(activeSpaceIndex, forKey: .activeSpaceIndex)
    }
}
