import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

/// Deterministic generator so a failing sequence reproduces from its seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let pool = (0..<8).map { "w\($0)" }
private let widthSamples: [Double] = [0.1, 0.25, 0.3, 0.5, 0.62, 0.75, 0.95, 1, 1.4, .nan, -2]

private func randomSpaces(_ rng: inout SplitMix64) -> (ids: [[String]], focus: [String?], widths: [[String: Double]]) {
    var ids: [[String]] = []
    var focus: [String?] = []
    var widths: [[String: Double]] = []
    for _ in 0..<Int.random(in: 0...4, using: &rng) {
        // Duplicates and empty IDs exercise the initializer's cleanup.
        let members = (0..<Int.random(in: 0...5, using: &rng)).map { _ in
            Int.random(in: 0..<20, using: &rng) == 0 ? "" : pool.randomElement(using: &rng)!
        }
        ids.append(members)
        focus.append(Bool.random(using: &rng) ? pool.randomElement(using: &rng) : nil)
        widths.append(Dictionary(members.filter { _ in Bool.random(using: &rng) }
            .map { ($0, widthSamples.randomElement(using: &rng)!) }, uniquingKeysWith: { first, _ in first }))
    }
    return (ids, focus, widths)
}

private func makeStates(_ rng: inout SplitMix64) -> (WorkspaceState, LegacyWorkspace) {
    let spaces = randomSpaces(&rng)
    let paused = Int.random(in: 0..<10, using: &rng) == 0
    let active = Int.random(in: -1...9, using: &rng)
    let current = WorkspaceState(isPaused: paused, spaces: spaces.ids.indices.map {
        SpaceState(windowIDs: spaces.ids[$0], focusedWindowID: spaces.focus[$0], widthFractions: spaces.widths[$0])
    }, activeSpaceIndex: active)
    let legacy = LegacyWorkspace(isPaused: paused, spaces: spaces.ids.indices.map {
        LegacySpace(windowIDs: spaces.ids[$0], focusedWindowID: spaces.focus[$0], widthFractions: spaces.widths[$0])
    }, activeSpaceIndex: active)
    return (current, legacy)
}

private let actions: [NavigationAction] = [
    .focusPrevious, .focusNext, .previousSpace, .nextSpace, .reorderPrevious, .reorderNext,
    .moveWindowUpSpace, .moveWindowDownSpace, .goToSpace(index: 0), .goToSpace(index: 2), .goToSpace(index: 8),
    .goToSpace(index: 12), .moveToSpace(index: 1, follow: true), .moveToSpace(index: 3, follow: false),
    .shareToSpace(index: 0), .shareToSpace(index: 2), .shrinkWidth, .growWidth, .nextWidthPreset,
    .previousWidthPreset, .shrinkHeight, .growHeight, .togglePause, .showSettings, .toggleShortcutHints
]

/// Applies the same random operation to both models and returns its name and
/// whether both reported the same result.
private func applyRandomOperation(_ current: inout WorkspaceState, _ legacy: inout LegacyWorkspace,
                                  _ rng: inout SplitMix64) -> (String, Bool) {
    let id = pool.randomElement(using: &rng)!
    let space = Int.random(in: -1...9, using: &rng)
    let other = Int.random(in: -1...9, using: &rng)
    let position = Int.random(in: -2...8, using: &rng)
    let width = widthSamples.randomElement(using: &rng)!
    switch Int.random(in: 0..<18, using: &rng) {
    case 0:
        let live = pool.filter { _ in Int.random(in: 0..<4, using: &rng) != 0 }.shuffled(using: &rng)
        let initial = Dictionary(live.filter { _ in Bool.random(using: &rng) }
            .map { ($0, widthSamples.randomElement(using: &rng)!) }, uniquingKeysWith: { first, _ in first })
        current.reconcile(windowIDs: live, initialWidthFractions: initial)
        legacy.reconcile(windowIDs: live, initialWidthFractions: initial)
        return ("reconcile \(live) \(initial)", true)
    case 1:
        let (savedCurrent, savedLegacy) = makeStates(&rng)
        let returning = Set(pool.filter { _ in Bool.random(using: &rng) })
        current.restoreMemberships(windowIDs: returning, from: savedCurrent)
        legacy.restoreMemberships(windowIDs: returning, from: savedLegacy)
        return ("restoreMemberships \(returning.sorted()) from \(savedLegacy)", true)
    case 2:
        return ("closeEmptySpace \(space)", current.closeEmptySpace(at: space) == legacy.closeEmptySpace(at: space))
    case 3:
        return ("openSpace \(space)", current.openSpace(at: space) == legacy.openSpace(at: space))
    case 4:
        let inserted = Bool.random(using: &rng) ? id : "n\(Int.random(in: 0..<3, using: &rng))"
        return ("insert \(inserted) space \(space) at \(position) width \(width)",
                current.insert(windowID: inserted, inSpace: space, at: position, width: width)
                    == legacy.insert(windowID: inserted, inSpace: space, at: position, width: width))
    case 5:
        current.discardSpace(at: space)
        legacy.discardSpace(at: space)
        return ("discardSpace \(space)", true)
    case 6:
        return ("focus \(id)", current.focus(windowID: id) == legacy.focus(windowID: id))
    case 7:
        return ("focus \(id) space \(space)",
                current.focus(windowID: id, inSpace: space) == legacy.focus(windowID: id, inSpace: space))
    case 8:
        return ("placeAfterFocused \(id) space \(space)",
                current.placeAfterFocused(windowID: id, inSpace: space)
                    == legacy.placeAfterFocused(windowID: id, inSpace: space))
    case 9:
        return ("reorder \(id) to \(position)",
                current.reorderWindow(windowID: id, to: position) == legacy.reorderWindow(windowID: id, to: position))
    case 10:
        return ("reorder \(id) to \(position) space \(space)",
                current.reorderWindow(windowID: id, to: position, inSpace: space)
                    == legacy.reorderWindow(windowID: id, to: position, inSpace: space))
    case 11:
        return ("setWidth \(width) \(id)",
                current.setWidthFraction(width, for: id) == legacy.setWidthFraction(width, for: id))
    case 12:
        return ("removeFromCurrentSpace \(id)",
                current.removeFromCurrentSpace(windowID: id) == legacy.removeFromCurrentSpace(windowID: id))
    case 13:
        return ("remove \(id) space \(space)",
                current.remove(windowID: id, fromSpace: space) == legacy.remove(windowID: id, fromSpace: space))
    case 14:
        return ("share \(id) to \(space)",
                current.share(windowID: id, toSpace: space) == legacy.share(windowID: id, toSpace: space))
    case 15:
        return ("share \(id) \(space) to \(other)",
                current.share(windowID: id, fromSpace: space, toSpace: other)
                    == legacy.share(windowID: id, fromSpace: space, toSpace: other))
    case 16:
        return ("move \(id) \(space) to \(other)",
                current.move(windowID: id, fromSpace: space, toSpace: other)
                    == legacy.move(windowID: id, fromSpace: space, toSpace: other))
    default:
        let action = actions.randomElement(using: &rng)!
        let presets = Bool.random(using: &rng) ? SpaceState.defaultWidthPresets : [0.4, .nan, 0.9, 0.4]
        return ("apply \(action) presets \(presets)",
                current.apply(action, widthPresets: presets) == legacy.apply(action, widthPresets: presets))
    }
}

private func observablyEqual(_ current: WorkspaceState, _ legacy: LegacyWorkspace) -> Bool {
    guard current.isPaused == legacy.isPaused, current.activeSpaceIndex == legacy.activeSpaceIndex,
          current.displayedSpaceIndices == legacy.displayedSpaceIndices,
          current.spaces.count == legacy.spaces.count else { return false }
    return zip(current.spaces, legacy.spaces).allSatisfy { space, old in
        space.windowIDs == old.windowIDs && space.focusedWindowID == old.focusedWindowID
            && space.tiles.allSatisfy { !$0.isMultiPane }
            && old.windowIDs.allSatisfy { space.tileWidthFraction(containing: $0) == old.widthFraction(for: $0) }
    }
}

/// Canonical form: splits of two or more children with usable weights, no
/// split along its parent's axis, no empty window ID.
private func treeViolations(_ tree: PaneTree, parentAxis: SplitAxis?) -> [String] {
    switch tree {
    case .pane(let windowID):
        return windowID.isEmpty ? ["empty window ID"] : []
    case .split(let axis, let children, let weights):
        var problems: [String] = []
        if children.count < 2 { problems.append("split of \(children.count)") }
        if weights.count != children.count { problems.append("weights misaligned") }
        if !weights.allSatisfy({ $0.isFinite && $0 > 0 }) { problems.append("bad weight \(weights)") }
        if axis == parentAxis { problems.append("nested \(axis) split") }
        return problems + children.flatMap { treeViolations($0, parentAxis: axis) }
    }
}

/// The invariants every reachable state keeps.
private func invariantViolations(_ state: WorkspaceState) -> [String] {
    var problems: [String] = []
    for (index, space) in state.spaces.enumerated() {
        let flat = space.tiles.flatMap(\.windowIDs)
        if space.windowIDs != flat { problems.append("space \(index): windowIDs \(space.windowIDs) != \(flat)") }
        if Set(flat).count != flat.count { problems.append("space \(index): duplicate window") }
        if Set(space.tiles.map(\.id)).count != space.tiles.count { problems.append("space \(index): duplicate tile ID") }
        for (tileIndex, tile) in space.tiles.enumerated() {
            if tile.windowIDs.isEmpty { problems.append("space \(index): empty tile") }
            if !tile.windowIDs.contains(tile.activeWindowID) { problems.append("space \(index): active not a member") }
            if tile.windowIDs != tile.panes.windowIDs { problems.append("space \(index): stale reading order") }
            problems += treeViolations(tile.panes, parentAxis: nil).map { "space \(index) tile \(tile.id): \($0)" }
            if !(SpaceState.minimumWidthFraction...SpaceState.maximumWidthFraction).contains(tile.widthFraction) {
                problems.append("space \(index): width \(tile.widthFraction)")
            }
            for windowID in tile.windowIDs where space.tileIndex(of: windowID) != tileIndex {
                problems.append("space \(index): stale tile index for \(windowID)")
            }
        }
        if let focused = space.focusedWindowID {
            if let tile = space.tileIndex(of: focused) {
                if space.tiles[tile].activeWindowID != focused { problems.append("space \(index): focus not active") }
            } else {
                problems.append("space \(index): focus \(focused) not a member")
            }
        } else if !flat.isEmpty {
            problems.append("space \(index): occupied without focus")
        }
    }
    return problems
}

// MARK: - Singleton behavior matches the flat model

@Test func singletonTilesBehaveExactlyLikeTheFlatModel() {
    for seed in UInt64(0)..<400 {
        var rng = SplitMix64(state: seed)
        var (current, legacy) = makeStates(&rng)
        #expect(observablyEqual(current, legacy), "seed \(seed) initial")
        for step in 0..<40 {
            let (operation, sameResult) = applyRandomOperation(&current, &legacy, &rng)
            let equal = observablyEqual(current, legacy)
            #expect(sameResult && equal, "seed \(seed) step \(step): \(operation)\n\(current)\n\(legacy)")
            if !(sameResult && equal) { return }
        }
    }
}

@Test func singletonPlacementsMatchTheFlatLayoutExactly() {
    let frames = [
        CGRect(x: 0, y: 40, width: 1_000, height: 700),
        CGRect(x: -1_440, y: 25, width: 1_440, height: 875),
        CGRect(x: 12.5, y: 0.25, width: 333.3, height: 222.2),
        CGRect(x: 0, y: 0, width: -500, height: 300)
    ]
    let gaps: [CGFloat] = [8, 0, 30, -200, -1, .nan, .infinity]
    let sizes: [CGFloat] = [0, -1, .nan, .infinity, 1, 120, 480.5, 900, 1_600]
    for seed in UInt64(0)..<400 {
        var rng = SplitMix64(state: seed)
        var (state, legacy) = makeStates(&rng)
        for _ in 0..<Int.random(in: 0...6, using: &rng) { _ = applyRandomOperation(&state, &legacy, &rng) }
        let ids = state.currentSpace.windowIDs + ["stranger"]
        func randomSizes() -> [String: CGFloat] {
            Dictionary(ids.filter { _ in Bool.random(using: &rng) }.map { ($0, sizes.randomElement(using: &rng)!) },
                       uniquingKeysWith: { first, _ in first })
        }
        let frame = frames.randomElement(using: &rng)!
        let gap = gaps.randomElement(using: &rng)!
        let observedWidths = randomSizes()
        let preferredHeights = randomSizes()
        let observedHeights = randomSizes()
        // Minimums and the pane gap apply only to multi-pane tiles, so they change nothing here.
        let minimumWidths = randomSizes()
        let minimumHeights = randomSizes()
        let placements = WindowLayout.placements(
            for: state, availableFrame: frame, gap: gap, observedWidths: observedWidths,
            preferredHeights: preferredHeights, observedHeights: observedHeights,
            minimumHeights: minimumHeights
        )
        let spacePlacements = WindowLayout.placements(
            for: state.currentSpace, availableFrame: frame, tileGap: gap, paneGap: gaps.randomElement(using: &rng)!,
            observedWidths: observedWidths, preferredHeights: preferredHeights, observedHeights: observedHeights,
            minimumWidths: minimumWidths, minimumHeights: minimumHeights
        )
        let expected = LegacyWindowLayout.placements(
            for: state, availableFrame: frame, gap: gap, observedWidths: observedWidths,
            preferredHeights: preferredHeights, observedHeights: observedHeights
        )
        #expect(placements == expected, "seed \(seed)")
        #expect(spacePlacements == expected, "seed \(seed) space")
    }
}

// MARK: - Invariants

@Test func tileOperationsKeepTheInvariants() throws {
    for seed in UInt64(0)..<300 {
        var rng = SplitMix64(state: seed)
        var (state, legacy) = makeStates(&rng)
        for step in 0..<50 {
            let operation: String
            let id = pool.randomElement(using: &rng)!
            let space = Int.random(in: -1...9, using: &rng)
            let direction = [-2, -1, 0, 1].randomElement(using: &rng)!
            let position = Int.random(in: -1...6, using: &rng)
            let paneDirection = PaneDirection.allCases.randomElement(using: &rng)!
            let edge = [TileEdge.left, .right, .top, .bottom].randomElement(using: &rng)!
            switch Int.random(in: 0..<24, using: &rng) {
            case 0, 1:
                state.join(windowID: id, intoTileAt: position, edge: edge, inSpace: space)
                operation = "join \(id) into \(position) at \(edge) space \(space)"
            case 2:
                state.expel(windowID: id, toward: direction, inSpace: space)
                operation = "expel \(id) \(direction) space \(space)"
            case 3:
                state.expel(windowID: id, toTileAt: position, inSpace: space)
                operation = "expel \(id) to \(position) space \(space)"
            case 4:
                state.moveFocusedWindowAcrossTiles(by: direction)
                operation = "across \(direction)"
            case 5, 6:
                state.moveFocusedWindowSideways(by: direction)
                operation = "sideways \(direction)"
            case 7:
                state.moveFocusedWindowVertically(by: direction)
                operation = "vertically \(direction)"
            case 8, 9:
                state.focusPane(direction: paneDirection)
                operation = "focusPane \(paneDirection)"
            case 10, 11:
                state.swapPane(windowID: id, direction: paneDirection, inSpace: space)
                operation = "swapPane \(id) \(paneDirection) space \(space)"
            case 12:
                let point = CGPoint(x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng))
                state.movePane(windowID: id, to: point, inSpace: space)
                operation = "movePane \(id) \(point) space \(space)"
            case 13, 14:
                let layout = PaneLayout.allCases.randomElement(using: &rng)!
                state.arrange(tileOf: id, layout: layout)
                operation = "arrange \(id) \(layout)"
            case 15:
                let neighbor = pool.randomElement(using: &rng)!
                let fraction = [0.1, 0.5, 0.9, 0, 1, .nan].randomElement(using: &rng)!
                state.setSplitShares(windowID: id, neighborID: neighbor, fraction: fraction)
                operation = "shares \(id) \(neighbor) \(fraction)"
            case 16:
                let returning = "n\(Int.random(in: 0..<3, using: &rng))"
                let saved = Tile(panes: .h(.p("w1"), .v(.p(returning), .p("w4"), weights: [2, 1]), .p("w6")))
                state.rejoin(windowID: returning, savedTile: saved, inSpace: space)
                operation = "rejoin \(returning) space \(space)"
            default:
                operation = applyRandomOperation(&state, &legacy, &rng).0
            }
            let problems = invariantViolations(state)
            #expect(problems.isEmpty, "seed \(seed) step \(step) \(operation): \(problems)\n\(state)")
            let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state, "seed \(seed) step \(step) \(operation): round trip")
            let placements = WindowLayout.placements(for: state, availableFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
            #expect(placements.map(\.windowID) == state.currentSpace.windowIDs)
            #expect(placements.filter(\.isFocused).map(\.windowID) == state.focusedWindowID.map { [$0] } ?? [])
            if !problems.isEmpty || decoded != state { return }
        }
    }
}

// MARK: - Tile operations

private func stacked(_ tiles: [[String]], focus: String? = nil, widths: [Double]? = nil) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(tiles: tiles.enumerated().map { index, members in
        Tile(stacking: members, widthFraction: widths?[index] ?? SpaceState.defaultWidthFraction)
    }, focusedWindowID: focus)])
}

@Test func aLoneWindowJoinsTheNeighboringTileAtTheBottomAndKeepsFocus() {
    var state = stacked([["a"], ["b", "c"], ["d"]], focus: "d", widths: [0.5, 0.6, 0.8])
    #expect(state.moveFocusedWindowAcrossTiles(by: -1) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "c", "d"]])
    #expect(state.focusedWindowID == "d")
    #expect(state.currentSpace.tiles[1].activeWindowID == "d")
    #expect(state.currentSpace.tileWidthFraction(containing: "d") == 0.6)

    var edge = stacked([["a"], ["b"]], focus: "a")
    #expect(edge.moveFocusedWindowAcrossTiles(by: -1) == false)
    #expect(edge.moveFocusedWindowAcrossTiles(by: 1) == true)
    #expect(edge.currentSpace.tiles.map(\.windowIDs) == [["b", "a"]])
    #expect(edge.currentSpace.tiles[0].id == "b")
}

@Test func aStackedWindowLeavesAsItsOwnTileOnThatSideWithTheStacksWidth() {
    var state = stacked([["a"], ["b", "c", "d"], ["e"]], focus: "c", widths: [0.5, 0.6, 0.8])
    #expect(state.moveFocusedWindowAcrossTiles(by: 1) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "d"], ["c"], ["e"]])
    #expect(state.focusedWindowID == "c")
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.6)
    // The stack remembers the member that took the leaver's place.
    #expect(state.currentSpace.tiles[1].activeWindowID == "d")

    #expect(state.moveFocusedWindowAcrossTiles(by: -1) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "d", "c"], ["e"]])
    #expect(state.moveFocusedWindowAcrossTiles(by: -1) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["c"], ["b", "d"], ["e"]])
    #expect(state.focusedWindowID == "c")
}

@Test func tileIDsStayWithTheTileAndStayUnique() {
    var state = stacked([["a"], ["b"]], focus: "b")
    #expect(state.moveFocusedWindowAcrossTiles(by: -1) == true)
    #expect(state.currentSpace.tiles.map(\.id) == ["a"])
    state.focus(windowID: "a")
    // The founder leaves; the tile keeps its ID and the leaver gets a new one.
    #expect(state.moveFocusedWindowAcrossTiles(by: 1) == true)
    #expect(state.currentSpace.tiles.map(\.id) == ["a", "a#2"])
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["b"], ["a"]])
}

@Test func memberFocusMovesWithinTheTileWithoutWrapping() {
    var state = stacked([["a"], ["b", "c", "d"]], focus: "c")
    #expect(state.focusPane(direction: .up) == true)
    #expect(state.focusedWindowID == "b")
    #expect(state.focusPane(direction: .up) == false)
    #expect(state.focusPane(direction: .down) == true)
    #expect(state.focusPane(direction: .down) == true)
    #expect(state.focusedWindowID == "d")
    #expect(state.focusPane(direction: .down) == false)
    var single = stacked([["a"], ["b"]], focus: "a")
    #expect(single.focusPane(direction: .down) == false)
}

@Test func horizontalFocusEntersTheRememberedMemberAndReorderMovesWholeTiles() {
    var state = stacked([["a"], ["b", "c", "d"], ["e"]], focus: "c")
    state.apply(.focusPrevious)
    #expect(state.focusedWindowID == "a")
    state.apply(.focusNext)
    #expect(state.focusedWindowID == "c")
    state.apply(.focusNext)
    state.apply(.focusPrevious)
    #expect(state.focusedWindowID == "c")

    #expect(state.apply(.reorderNext) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["e"], ["b", "c", "d"]])
    #expect(state.reorderWindow(windowID: "d", to: 0) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["b", "c", "d"], ["a"], ["e"]])
    #expect(state.focusedWindowID == "c")
}

@Test func widthBelongsToTheTile() {
    var state = stacked([["a", "b"], ["c"]], focus: "b", widths: [0.5, 0.7])
    #expect(state.setWidthFraction(0.8, for: "a") == true)
    #expect(state.currentSpace.tileWidthFraction(containing: "b") == 0.8)
    state.apply(.growWidth)
    #expect(state.currentSpace.tileWidthFraction(containing: "a") == 0.85)
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.7)
}

@Test func aClosedFocusedMemberHandsFocusToATileMate() {
    var state = stacked([["a"], ["b", "c", "d"], ["e"]], focus: "c")
    state.reconcile(windowIDs: ["a", "b", "d", "e"])
    #expect(state.focusedWindowID == "d")
    state.reconcile(windowIDs: ["a", "b", "e"])
    #expect(state.focusedWindowID == "b")
    state.reconcile(windowIDs: ["a", "e"])
    // A window alone in its tile hands focus to the next tile's active member.
    #expect(state.focusedWindowID == "e")
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["e"]])

    // Removing a tile's remembered member moves the memory, not the focus.
    var remembered = stacked([["a"], ["b", "c"]], focus: "a")
    remembered.focus(windowID: "c")
    remembered.focus(windowID: "a")
    remembered.reconcile(windowIDs: ["a", "b"])
    #expect(remembered.focusedWindowID == "a")
    #expect(remembered.currentSpace.tiles[1].activeWindowID == "b")
}

@Test func newAndRestoredWindowsBecomeTheirOwnTileAfterTheFocusedTile() {
    var state = stacked([["a", "b"], ["c"]], focus: "a")
    state.reconcile(windowIDs: ["a", "b", "c", "new"])
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a", "b"], ["new"], ["c"]])
    #expect(state.focusedWindowID == "new")

    var restored = stacked([["a", "b"], ["c"]], focus: "c")
    #expect(restored.placeAfterFocused(windowID: "a", inSpace: 0) == true)
    #expect(restored.currentSpace.tiles.map(\.windowIDs) == [["b"], ["c"], ["a"]])
    #expect(restored.focusedWindowID == "a")

    var sameStack = stacked([["a", "b", "c"]], focus: "a")
    #expect(sameStack.placeAfterFocused(windowID: "c", inSpace: 0) == true)
    #expect(sameStack.currentSpace.tiles.map(\.windowIDs) == [["a", "b"], ["c"]])
    #expect(sameStack.currentSpace.tiles[0].activeWindowID == "a")
}

@Test func stackCompositionIsPerSpace() {
    var state = stacked([["a", "b"]], focus: "a")
    #expect(state.apply(.shareToSpace(index: 1)) == true)
    #expect(state.spaces[1].tiles.map(\.windowIDs) == [["a"]])
    #expect(state.apply(.moveToSpace(index: 2, follow: false)) == true)
    #expect(state.spaces[0].tiles.map(\.windowIDs) == [["b"]])
    #expect(state.spaces[2].tiles.map(\.windowIDs) == [["a"]])
    #expect(state.focusedWindowID == "b")
}

@Test func tilesRoundTripAndMalformedTilesAreRepaired() throws {
    let state = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(id: "left", stacking: ["a", "b"], widthFraction: 0.6, activeWindowID: "b", weights: [2, 1]),
        Tile(stacking: ["c"])
    ], focusedWindowID: "c")])
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(WorkspaceState.self, from: data) == state)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let space = try #require((payload["spaces"] as? [[String: Any]])?.first)
    #expect(space["windowIDs"] == nil)

    let tile = try #require((space["tiles"] as? [[String: Any]])?.first)
    #expect(tile["windowIDs"] == nil)
    #expect(tile["panes"] != nil)

    // Two tiles with ID x; the first repeats b, has an empty ID, a bad weight, a
    // one-child split and a nested split along its parent's axis; the second
    // repeats b from the first.
    let repairable = Data(#"""
        {"spaces":[{"tiles":[
          {"id":"x","activeWindowID":"z","panes":{"split":{"axis":"vertical","weights":[-1,2,1],"children":[
            {"pane":{"windowID":"a"}},
            {"split":{"axis":"vertical","weights":[1,3],"children":[{"pane":{"windowID":"b"}},{"pane":{"windowID":"b"}}]}},
            {"split":{"axis":"horizontal","weights":[5],"children":[{"pane":{"windowID":""}}]}}]}}},
          {"id":"x","panes":{"split":{"axis":"horizontal","weights":[1,4],"children":[
            {"pane":{"windowID":"b"}},{"pane":{"windowID":"c"}}]}}}],
          "focusedWindowID":"c","displayAnchor":"UUID-1"}],
         "shownSpaceIndices":{"UUID-2":3,"UUID-3":12}}
        """#.utf8)
    let decoded = try JSONDecoder().decode(WorkspaceState.self, from: repairable)
    let repaired = decoded.currentSpace
    #expect(repaired.tiles.map(\.id) == ["x", "x#2"])
    #expect(repaired.tiles.map(\.panes) == [.v(.p("a"), .p("b"), weights: [1, 2]), .p("c")])
    #expect(repaired.tiles[0].activeWindowID == "a")
    #expect(repaired.focusedWindowID == "c")
    #expect(repaired.displayAnchor == DisplayID(rawValue: "UUID-1"))
    #expect(decoded.shownSpaceIndices == [DisplayID(rawValue: "UUID-2"): 3])
}

// MARK: - Stack layout

private let viewport = CGRect(x: 0, y: 40, width: 1_000, height: 700)

private func frame(_ placements: [WindowPlacement], _ id: String) throws -> CGRect {
    try #require(placements.first { $0.windowID == id }).frame
}

@Test func aStackFillsTheHeightSplitByWeightWithAVerticalGap() throws {
    let equal = stacked([["a", "b"]], focus: "a", widths: [0.5])
    let placements = WindowLayout.placements(for: equal, availableFrame: viewport, gap: 10)
    #expect(try frame(placements, "a") == CGRect(x: 0, y: 40, width: 500, height: 345))
    #expect(try frame(placements, "b") == CGRect(x: 0, y: 395, width: 500, height: 345))

    let weighted = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(stacking: ["a", "b", "c"], widthFraction: 0.5, weights: [2, 1, 1])
    ])])
    let thirds = WindowLayout.placements(for: weighted, availableFrame: viewport, gap: 20)
    #expect(try frame(thirds, "a").height == 330)
    #expect(try frame(thirds, "b") == CGRect(x: 0, y: 390, width: 500, height: 165))
    #expect(try frame(thirds, "c").maxY == viewport.maxY)
}

@Test func aNegativeGapOverlapsTilesButNotStackMembers() throws {
    let state = stacked([["a"], ["b", "c"]], focus: "b", widths: [0.5, 0.5])
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: -100)
    #expect(try frame(placements, "b").minX == frame(placements, "a").maxX - 100)
    #expect(try frame(placements, "b").height == 350)
    #expect(try frame(placements, "c").minY == frame(placements, "b").maxY)
}

@Test func anObservedMemberHeightIsKeptAndTheOthersShareTheRest() throws {
    let state = stacked([["a", "b", "c"]], focus: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: 10,
                                             observedHeights: ["b": 380])
    #expect(try frame(placements, "a").height == 150)
    #expect(try frame(placements, "b").height == 380)
    #expect(try frame(placements, "c").maxY == viewport.maxY)

    // Windows shorter than their panes are centered in them.
    let short = WindowLayout.placements(for: stacked([["a", "b"]]), availableFrame: viewport, gap: 10,
                                        observedHeights: ["a": 200, "b": 200])
    #expect(try frame(short, "a") == CGRect(x: 0, y: viewport.minY + 72.5, width: 950, height: 200))
    #expect(try frame(short, "b").midY == viewport.maxY - 172.5)
}

@Test func aStackIsAsWideAsItsWidestPaneAndNarrowerWindowsAreCentered() throws {
    let state = stacked([["a", "b"], ["c"]], focus: "a", widths: [0.5, 0.5])
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: 10,
                                             observedWidths: ["a": 420, "b": 610])
    #expect(try frame(placements, "a").midX == frame(placements, "b").midX)
    #expect(try frame(placements, "a").width == 420)
    #expect(try frame(placements, "b").minX == 0)
    #expect(try frame(placements, "c").minX == frame(placements, "b").maxX + 10)
}

@Test func focusInsideATileDoesNotScrollTheRibbon() throws {
    var state = stacked([["a"], ["b", "c"], ["d"]], focus: "c", widths: [0.8, 0.8, 0.8])
    let lower = WindowLayout.placements(for: state, availableFrame: viewport)
    state.focusPane(direction: .up)
    let upper = WindowLayout.placements(for: state, availableFrame: viewport)
    #expect(lower.map(\.frame) == upper.map(\.frame))
    #expect(upper.filter(\.isFocused).map(\.windowID) == ["b"])
    #expect(try frame(upper, "b").minX == viewport.minX)
}

@Test func preferredHeightsApplyOnlyToALoneWindow() throws {
    let state = stacked([["a", "b"], ["c"]], focus: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: 0,
                                             preferredHeights: ["a": 300, "c": 300])
    #expect(try frame(placements, "a").height == 350)
    #expect(try frame(placements, "c").height == 300)
}
