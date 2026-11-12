// The flat, one-window-per-slot model and layout as they were before columns
// (git show ec902a5:Sources/StagehandCore/WorkspaceState.swift and WindowLayout.swift),
// kept verbatim apart from renaming, as the reference that column-based runtime
// behaviour must match while every column holds one window.
import CoreGraphics
import Foundation
@testable import StagehandCore

public struct LegacySpace: Codable, Equatable, Sendable {
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

public struct LegacyWorkspace: Codable, Equatable, Sendable {
    public static let spaceCount = 9

    public var isPaused: Bool
    public private(set) var spaces: [LegacySpace]
    public private(set) var activeSpaceIndex: Int

    public var currentSpace: LegacySpace { spaces[activeSpaceIndex] }
    public var focusedWindowID: String? { currentSpace.focusedWindowID }
    public var displayedSpaceIndices: [Int] {
        spaces.indices.filter { $0 == activeSpaceIndex || !spaces[$0].windowIDs.isEmpty }
    }

    public init(
        isPaused: Bool = false,
        spaces: [LegacySpace] = [],
        activeSpaceIndex: Int = 0
    ) {
        self.isPaused = isPaused
        self.spaces = Array(spaces.prefix(Self.spaceCount))
        self.spaces.append(contentsOf: repeatElement(LegacySpace(), count: Self.spaceCount - self.spaces.count))
        self.activeSpaceIndex = min(max(activeSpaceIndex, 0), Self.spaceCount - 1)
    }

    /// Restore returning windows without undoing changes to windows already in the workspace.
    public mutating func restoreMemberships(windowIDs: Set<String>, from savedState: LegacyWorkspace) {
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
                width: initialWidthFractions[windowID] ?? LegacySpace.defaultWidthFraction,
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
        spaces.insert(LegacySpace(), at: index)
        if activeSpaceIndex >= index { activeSpaceIndex += 1 }
        return true
    }

    /// Adds a window that is not yet a member of the space at `position`, keeping
    /// the space's focus, as a relaunched window returning to its slot.
    @discardableResult
    public mutating func insert(windowID: String, inSpace index: Int, at position: Int, width: Double) -> Bool {
        guard spaces.indices.contains(index), !windowID.isEmpty,
              !spaces[index].windowIDs.contains(windowID) else { return false }
        let clamped = min(max(position, 0), spaces[index].windowIDs.count)
        spaces[index].windowIDs.insert(windowID, at: clamped)
        spaces[index].widthFractions[windowID] = LegacySpace.clampedWidth(width)
        if spaces[index].focusedWindowID == nil { spaces[index].focusedWindowID = windowID }
        return true
    }

    /// Keep a saved membership snapshot aligned after the corresponding live slot closes.
    public mutating func discardSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        spaces.remove(at: index)
        spaces.append(LegacySpace())
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

    /// Moves a member directly after the space's focused window, then focuses it
    /// there, as macOS does when the user reopens a window.
    @discardableResult
    public mutating func placeAfterFocused(windowID: String, inSpace index: Int) -> Bool {
        guard spaces.indices.contains(index), spaces[index].windowIDs.contains(windowID) else { return false }
        if let anchor = spaces[index].focusedWindowID, anchor != windowID {
            spaces[index].windowIDs.removeAll { $0 == windowID }
            let anchorIndex = spaces[index].windowIDs.firstIndex(of: anchor) ?? spaces[index].windowIDs.endIndex - 1
            spaces[index].windowIDs.insert(windowID, at: anchorIndex + 1)
        }
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
        let value = LegacySpace.clampedWidth(width)
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
              spaces.legacyMembershipCount(of: windowID) > 1 else { return false }
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
    public mutating func apply(_ action: NavigationAction,
                               widthPresets: [Double] = LegacySpace.defaultWidthPresets) -> Bool {
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
            let presets = LegacySpace.normalizedWidthPresets(widthPresets)
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
            spaces: try values.decodeIfPresent([LegacySpace].self, forKey: .spaces) ?? [],
            activeSpaceIndex: try values.decodeIfPresent(Int.self, forKey: .activeSpaceIndex) ?? 0
        )
    }
}

extension Sequence where Element == LegacySpace {
    /// The number of spaces that contain the window.
    public func legacyMembershipCount(of windowID: String) -> Int {
        count { $0.windowIDs.contains(windowID) }
    }
}

enum LegacyWindowLayout {
    /// Uses the caller's coordinate system without converting between AppKit and Accessibility.
    public static func placements(
        for state: WorkspaceState,
        availableFrame: CGRect,
        gap: CGFloat = 8,
        observedWidths: [String: CGFloat] = [:],
        preferredHeights: [String: CGFloat] = [:],
        observedHeights: [String: CGFloat] = [:]
    ) -> [WindowPlacement] {
        guard !availableFrame.isEmpty, !availableFrame.isInfinite,
              availableFrame.origin.x.isFinite, availableFrame.origin.y.isFinite,
              availableFrame.width.isFinite, availableFrame.height.isFinite else { return [] }
        let space = state.currentSpace
        let gap: CGFloat = gap.isFinite ? gap : 8

        var cursor: CGFloat = 0
        var focusedStart: CGFloat = 0
        var focusedWidth: CGFloat = 0
        var totalWidth: CGFloat = 0
        var ribbon: [(windowID: String, frame: CGRect)] = []
        ribbon.reserveCapacity(space.windowIDs.count)
        for windowID in space.windowIDs {
            let requestedWidth = availableFrame.width * space.widthFraction(for: windowID)
            let width: CGFloat
            if let observedWidth = observedWidths[windowID], observedWidth.isFinite, observedWidth > 0 {
                width = observedWidth
            } else {
                width = requestedWidth
            }
            // Accepted app constraints take precedence over either requested size.
            let preferredHeight = preferredHeights[windowID] ?? availableFrame.height
            let requestedHeight = preferredHeight.isFinite && preferredHeight > 0
                ? preferredHeight : availableFrame.height
            let height: CGFloat
            if let observedHeight = observedHeights[windowID], observedHeight.isFinite, observedHeight > 0 {
                height = observedHeight
            } else {
                height = requestedHeight
            }
            let frame = CGRect(x: cursor, y: availableFrame.midY - height / 2, width: width, height: height)
            if windowID == space.focusedWindowID {
                focusedStart = cursor
                focusedWidth = width
            }
            totalWidth = max(totalWidth, frame.maxX)
            cursor += max(1, width + gap)
            ribbon.append((windowID: windowID, frame: frame))
        }
        let desiredOffset = gap < 0 ? focusedStart - (availableFrame.width - focusedWidth) / 2 : focusedStart
        let offset = min(max(0, desiredOffset), max(0, totalWidth - availableFrame.width))

        var placements: [WindowPlacement] = []
        placements.reserveCapacity(ribbon.count)
        for item in ribbon {
            let frame = item.frame.offsetBy(dx: availableFrame.minX - offset, dy: 0)
            placements.append(WindowPlacement(
                windowID: item.windowID,
                frame: frame,
                isVisible: frame.intersects(availableFrame),
                isFocused: item.windowID == space.focusedWindowID
            ))
        }
        return placements
    }
}
