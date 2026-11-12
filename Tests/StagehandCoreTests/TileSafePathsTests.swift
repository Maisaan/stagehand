import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

// The paths that must keep a multi-pane tile intact.

private func stackedSpace(_ tiles: [[String]], focus: String? = nil, widths: [Double]? = nil,
                          weights: [[Double]]? = nil) -> SpaceState {
    SpaceState(tiles: tiles.enumerated().map { index, members in
        Tile(stacking: members, widthFraction: widths?[index] ?? SpaceState.defaultWidthFraction,
             weights: weights?[index] ?? [])
    }, focusedWindowID: focus)
}

private func stacked(_ tiles: [[String]], focus: String? = nil, widths: [Double]? = nil,
                     weights: [[Double]]? = nil) -> WorkspaceState {
    WorkspaceState(spaces: [stackedSpace(tiles, focus: focus, widths: widths, weights: weights)])
}

// MARK: - Returning windows keep their stacks

@Test func aReturningStackedWindowRejoinsItsTileBetweenTheSameNeighbors() {
    let saved = stacked([["a"], ["b", "c", "d"], ["e"]], focus: "c", widths: [0.5, 0.6, 0.7],
                        weights: [[1], [1, 2.5, 1], [1]])
    var state = saved
    // c leaves (minimized, a busy app) and returns.
    state.reconcile(windowIDs: ["a", "b", "d", "e"])
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "d"], ["e"]])

    state.restoreMemberships(windowIDs: ["c"], from: saved)

    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "c", "d"], ["e"]])
    #expect(state.currentSpace.tiles[1].panes.weight(of: "c") == 2.5)
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.6)
}

@Test func aReturningTopMemberJoinsAboveItsRemainingMate() {
    let saved = stacked([["a", "b"], ["c"]], focus: "c")
    var state = saved
    state.reconcile(windowIDs: ["b", "c"])
    state.restoreMemberships(windowIDs: ["a"], from: saved)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a", "b"], ["c"]])
    #expect(state.focusedWindowID == "c")
}

@Test func aWholeStackReturningTogetherIsRebuilt() {
    let saved = stacked([["a"], ["b", "c"], ["d"]], focus: "a", widths: [0.5, 0.6, 0.7])
    var state = saved
    state.reconcile(windowIDs: ["a", "d"])
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["d"]])

    state.restoreMemberships(windowIDs: ["b", "c"], from: saved)

    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "c"], ["d"]])
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.6)
}

@Test func aStackedWindowWhoseMatesAreGoneReturnsAsItsOwnTile() {
    let saved = stacked([["a"], ["b", "c"], ["d"]], focus: "a")
    var state = saved
    state.reconcile(windowIDs: ["a", "d"])
    state.restoreMemberships(windowIDs: ["c"], from: saved)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["c"], ["d"]])
}

@Test func rejoinRestoresTheSavedTreeWhenTheRestIsUnchanged() {
    var state = stacked([["a"], ["b", "d"]], focus: "a", widths: [0.5, 0.6])
    #expect(state.rejoin(windowID: "new", savedTile: Tile(stacking: ["b", "new", "d"], weights: [1, 3, 1]),
                         inSpace: 0) == true)
    #expect(state.currentSpace.tiles[1].panes == .stack(["b", "new", "d"], weights: [1, 3, 1]))
    #expect(state.currentSpace.tileWidthFraction(containing: "new") == 0.6)
    #expect(state.focusedWindowID == "a")
    #expect(state.rejoin(windowID: "other", savedTile: Tile(stacking: ["x", "other"]), inSpace: 0) == false)
    #expect(state.rejoin(windowID: "new", savedTile: Tile(stacking: ["b", "new"]), inSpace: 0) == false)

    // A 2x2 grid that lost its bottom-right pane gets it back in place.
    let grid = Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")), weights: [2, 1]))
    var gridState = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(panes: .v(.h(.p("a"), .p("b")), .p("c"), weights: [2, 1]))
    ])])
    #expect(gridState.rejoin(windowID: "d", savedTile: grid, inSpace: 0) == true)
    #expect(gridState.currentSpace.tiles[0].panes == grid.panes)
}

@Test func rejoinOtherwiseGoesBesideTheNearestSavedSiblingOnItsSide() {
    // The tile changed since: b now sits beside a, not below it.
    var state = WorkspaceState(spaces: [SpaceState(tiles: [Tile(panes: .h(.p("a"), .p("b")))])])
    #expect(state.rejoin(windowID: "c", savedTile: Tile(panes: .v(.p("a"), .p("b"), .p("c"))), inSpace: 0) == true)
    #expect(state.currentSpace.tiles[0].panes == .h(.p("a"), .v(.p("b"), .p("c"))))

    // With no earlier mate present, it goes before the later one, along their saved split.
    var front = WorkspaceState(spaces: [SpaceState(tiles: [Tile(panes: .v(.p("b"), .p("x")))])])
    #expect(front.rejoin(windowID: "a", savedTile: Tile(panes: .h(.p("a"), .p("b"))), inSpace: 0) == true)
    #expect(front.currentSpace.tiles[0].panes == .v(.h(.p("a"), .p("b")), .p("x")))
}

@Test func aWholeSideBySideTileReturnsAtItsWidthWithItsPanesWidths() {
    let saved = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(windowID: "x", widthFraction: 0.5),
        Tile(panes: .h(.p("a"), .p("b"), .p("c"), weights: [2, 1, 1]), widthFraction: 0.8)
    ], focusedWindowID: "x")])
    var state = saved
    state.reconcile(windowIDs: ["x"])
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["x"]])

    state.restoreMemberships(windowIDs: ["a", "b", "c"], from: saved)

    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["x"], ["a", "b", "c"]])
    #expect(state.currentSpace.tiles[1].panes == saved.currentSpace.tiles[1].panes)
    #expect(abs(state.currentSpace.tileWidthFraction(containing: "a") - 0.8) < 1e-9)
    #expect(state.focusedWindowID == "x")
}

@Test func aWindowRejoiningAGridKeepsTheOtherPanesWidths() {
    let grid = Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d"))), widthFraction: 1)
    // d was away and the rest of the tile kept its layout: the tile is as wide as before.
    var whole = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(panes: .v(.h(.p("a"), .p("b")), .p("c")), widthFraction: 1)
    ])])
    #expect(whole.rejoin(windowID: "d", savedTile: grid, inSpace: 0) == true)
    #expect(whole.currentSpace.tiles[0].panes == grid.panes)
    #expect(whole.currentSpace.tileWidthFraction(containing: "d") == 1)

    // Only c is here, alone at its pane's width: d beside it doubles the width.
    var alone = WorkspaceState(spaces: [SpaceState(tiles: [Tile(windowID: "c", widthFraction: 0.5)])])
    #expect(alone.rejoin(windowID: "d", savedTile: grid, inSpace: 0) == true)
    #expect(alone.currentSpace.tiles[0].panes == .h(.p("c"), .p("d")))
    #expect(alone.currentSpace.tileWidthFraction(containing: "d") == 1)

    // Below its mate it adds no width.
    var stacked = WorkspaceState(spaces: [SpaceState(tiles: [Tile(windowID: "b", widthFraction: 0.5)])])
    #expect(stacked.rejoin(windowID: "d", savedTile: grid, inSpace: 0) == true)
    #expect(stacked.currentSpace.tiles[0].panes == .v(.p("b"), .p("d")))
    #expect(stacked.currentSpace.tileWidthFraction(containing: "d") == 0.5)
}

// MARK: - Drops and resizes

@Test func aStackedWindowDroppedOutsideItsTileBecomesItsOwnTileThere() {
    var state = stacked([["a"], ["b", "c"], ["d"]], focus: "c", widths: [0.5, 0.6, 0.7])
    #expect(state.expel(windowID: "c", toTileAt: 3, inSpace: 0) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b"], ["d"], ["c"]])
    #expect(state.focusedWindowID == "c")
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.6)

    var front = stacked([["a"], ["b", "c"]], focus: "b")
    #expect(front.expel(windowID: "b", toTileAt: -4, inSpace: 0) == true)
    #expect(front.currentSpace.tiles.map(\.windowIDs) == [["b"], ["a"], ["c"]])
    #expect(front.focusedWindowID == "b")

    var lone = stacked([["a"], ["b"]], focus: "a")
    #expect(lone.expel(windowID: "a", toTileAt: 1, inSpace: 0) == false)
}

@Test func splitSharesTradeBetweenTheTwoSidesOnlyWithinOneTile() {
    var state = stacked([["a"], ["b", "c", "d"]], focus: "a")
    #expect(state.setSplitShares(windowID: "b", neighborID: "c", fraction: 0.75) == true)
    #expect(state.currentSpace.tiles[1].panes == .stack(["b", "c", "d"], weights: [1.5, 0.5, 1]))
    #expect(state.setSplitShares(windowID: "b", neighborID: "c", fraction: 0.75) == false)
    #expect(state.setSplitShares(windowID: "a", neighborID: "b", fraction: 0.5) == false)
    #expect(state.setSplitShares(windowID: "c", neighborID: "d", fraction: 0) == false)
    #expect(state.setSplitShares(windowID: "c", neighborID: "d", fraction: .nan) == false)
    #expect(state.setSplitShares(windowID: "c", neighborID: "c", fraction: 0.5) == false)
    #expect(state.setSplitShares(windowID: "missing", neighborID: "c", fraction: 0.5) == false)

    // Across a grid's rows, the rows trade; each row keeps its own columns.
    var grid = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(panes: .v(.h(.p("a"), .p("b"), weights: [1, 3]), .h(.p("c"), .p("d"))))
    ])])
    #expect(grid.setSplitShares(windowID: "b", neighborID: "d", fraction: 0.25) == true)
    #expect(grid.currentSpace.tiles[0].panes
        == .v(.h(.p("a"), .p("b"), weights: [1, 3]), .h(.p("c"), .p("d")), weights: [0.5, 1.5]))
}

@Test func stackSafeOperationsKeepTheInvariants() throws {
    let pool = (0..<6).map { "w\($0)" }
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        var state = stacked([["w0", "w1"], ["w2"], ["w3", "w4", "w5"]], focus: "w4")
        let saved = state
        for _ in 0..<30 {
            let id = pool.randomElement(using: &generator)!
            switch Int.random(in: 0..<6, using: &generator) {
            case 0: state.expel(windowID: id, toTileAt: Int.random(in: -1...5, using: &generator), inSpace: 0)
            case 1: state.setSplitShares(windowID: id, neighborID: pool.randomElement(using: &generator)!,
                                         fraction: [0.2, 0.5, 0.9, -1].randomElement(using: &generator)!)
            case 2: state.reconcile(windowIDs: pool.filter { _ in Bool.random(using: &generator) })
            case 3: state.restoreMemberships(windowIDs: Set(pool.filter { _ in Bool.random(using: &generator) }),
                                             from: saved)
            case 4:
                let returning = "n\(Int.random(in: 0..<3, using: &generator))"
                state.rejoin(windowID: returning, savedTile: Tile(stacking: ["w1", "n0", "w4", "n1", "n2"]),
                             inSpace: 0)
            default: state.moveFocusedWindowAcrossTiles(by: Bool.random(using: &generator) ? 1 : -1)
            }
            for space in state.spaces {
                let flat = space.tiles.flatMap(\.windowIDs)
                #expect(space.windowIDs == flat)
                #expect(Set(flat).count == flat.count)
                #expect(space.tiles.allSatisfy { !$0.windowIDs.isEmpty && $0.windowIDs.contains($0.activeWindowID)
                    && $0.windowIDs == $0.panes.windowIDs })
                if let focused = space.focusedWindowID, let tile = space.tileIndex(of: focused) {
                    #expect(space.tiles[tile].activeWindowID == focused)
                } else {
                    #expect(flat.isEmpty)
                }
            }
            let decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state)
        }
    }
}

// MARK: - Minimum heights in a stack

private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 700)

private func frame(_ placements: [WindowPlacement], _ id: String) throws -> CGRect {
    try #require(placements.first { $0.windowID == id }).frame
}

@Test func aStackMemberNeverFallsBelowItsLearnedMinimumHeight() throws {
    let state = stacked([["a", "b", "c"]], focus: "a")
    // Equal shares would be 228; b needs 400, so a and c share the other 284.
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 8,
                                             minimumHeights: ["b": 400, "c": 100, "x": 900])
    #expect(try frame(placements, "b").height == 400)
    #expect(try frame(placements, "a").height == 142)
    #expect(try frame(placements, "c").height == 142)
    #expect(try frame(placements, "a").minY == 0)
    #expect(try frame(placements, "c").maxY == 700)
}

@Test func minimumsHoldOneAfterAnotherUntilEveryShareFits() throws {
    let state = stacked([["a", "b", "c"]], focus: "a")
    // b's minimum leaves 92 each for a and c; then c's 150 holds, leaving a 34.
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 8,
                                             minimumHeights: ["b": 500, "c": 150])
    #expect(try frame(placements, "b").height == 500)
    #expect(try frame(placements, "c").height == 150)
    #expect(try frame(placements, "a").height == 34)
}

@Test func aStackThatCannotFitStartsAtTheTopAtItsMinimumsAndReportsItsSize() throws {
    let state = stacked([["a", "b"]], focus: "a")
    let minimums: [String: CGFloat] = ["a": 500, "b": 400]
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 8, minimumHeights: minimums)
    #expect(try frame(placements, "a").height == 500)
    #expect(try frame(placements, "b").height == 400)
    #expect(try frame(placements, "a").minY == 0)
    #expect(try frame(placements, "b").minY == 508)
    func size(_ tile: Tile, gap: CGFloat, widths: [String: CGFloat] = [:], heights: [String: CGFloat]) -> CGSize {
        WindowLayout.minimumTileSize(tile, paneGap: gap, minimumWidths: widths, minimumHeights: heights)
    }
    #expect(size(Tile(stacking: ["a", "b"]), gap: 8, heights: minimums) == CGSize(width: 0, height: 908))
    #expect(size(Tile(stacking: ["a", "b", "c"]), gap: -20, heights: minimums) == CGSize(width: 0, height: 900))
    #expect(size(Tile(stacking: ["a", "z"]), gap: .nan, heights: ["a": 10, "z": .infinity]) == CGSize(width: 0, height: 18))
}

@Test func minimumHeightsChangeNothingForLoneWindowsOrStacksWithRoom() {
    let lone = stacked([["a"], ["b"], ["c"]], focus: "b")
    let minimums: [String: CGFloat] = ["a": 690, "b": 2_000, "c": 10]
    #expect(WindowLayout.placements(for: lone, availableFrame: screen, preferredHeights: ["a": 300],
                                    minimumHeights: minimums)
        == WindowLayout.placements(for: lone, availableFrame: screen, preferredHeights: ["a": 300]))
    let roomy = stacked([["a", "b"]], focus: "a")
    #expect(WindowLayout.placements(for: roomy, availableFrame: screen, minimumHeights: ["a": 100])
        == WindowLayout.placements(for: roomy, availableFrame: screen))
}

@Test func aMinimumHoldsThePaneWhileASmallerObservedWindowIsCenteredInIt() throws {
    let state = stacked([["a", "b"]], focus: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 0,
                                             observedHeights: ["a": 200], minimumHeights: ["a": 600])
    #expect(try frame(placements, "a") == CGRect(x: 0, y: 200, width: 950, height: 200))
    #expect(try frame(placements, "b") == CGRect(x: 0, y: 600, width: 950, height: 100))
}
