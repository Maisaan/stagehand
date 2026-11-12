import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

private func space(_ tiles: [Tile], focus: String? = nil) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(tiles: tiles, focusedWindowID: focus)])
}

private func lone(_ ids: [String], focus: String? = nil, width: Double = 0.5) -> WorkspaceState {
    space(ids.map { Tile(windowID: $0, widthFraction: width) }, focus: focus)
}

private func trees(_ state: WorkspaceState) -> [PaneTree] {
    state.currentSpace.tiles.map(\.panes)
}

private let grid = PaneTree.v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")))
private let wideOverTwo = PaneTree.v(.p("a"), .h(.p("b"), .p("c")))

// MARK: - Canonical trees

@Test func layoutsBuildTheirTrees() {
    #expect(PaneLayout.single.tree(["a"]) == .p("a"))
    #expect(PaneLayout.sideBySide.tree(["a", "b"]) == .h(.p("a"), .p("b")))
    #expect(PaneLayout.stacked.tree(["a", "b"]) == .v(.p("a"), .p("b")))
    #expect(PaneLayout.grid.tree(["a", "b", "c", "d"]) == grid)
    #expect(PaneLayout.wideOverTwo.tree(["a", "b", "c"]) == wideOverTwo)
    #expect(PaneLayout.allCases.map(\.paneCount) == [1, 2, 2, 4, 3])
    #expect(PaneLayout.grid.tree(["a", "b"]) == nil)
    #expect(Tile(panes: grid).windowIDs == ["a", "b", "c", "d"])
}

@Test func aNestedSplitAlongItsParentsAxisFlattensAndKeepsEveryPanesSize() {
    let tile = Tile(panes: .h(.p("a"), .h(.p("b"), .p("c"), weights: [1, 3]), weights: [2, 2]))
    #expect(tile.panes == .h(.p("a"), .p("b"), .p("c"), weights: [2, 0.5, 1.5]))
    #expect(Tile(panes: .v(.p("a"))).panes == .p("a"))
}

@Test func removingAPaneCollapsesTheTreeAndItsSiblingsGrow() {
    var state = space([Tile(panes: grid, widthFraction: 1)], focus: "d")
    state.reconcile(windowIDs: ["a", "b", "c"])
    #expect(trees(state) == [.v(.h(.p("a"), .p("b")), .p("c"))])
    // Focus goes to the pane that absorbed the space: the previous sibling here.
    #expect(state.focusedWindowID == "c")
    state.reconcile(windowIDs: ["a", "c"])
    #expect(trees(state) == [.v(.p("a"), .p("c"))])

    var top = space([Tile(panes: wideOverTwo)], focus: "a")
    top.reconcile(windowIDs: ["b", "c"])
    // The next sibling absorbs the space; focus takes its first pane.
    #expect(trees(top) == [.h(.p("b"), .p("c"))])
    #expect(top.focusedWindowID == "b")
}

// MARK: - Spatial neighbors

@Test func panesFindTheirNeighborsInAGrid() {
    let neighbors = { (id: String, direction: PaneDirection) in grid.neighbor(of: id, toward: direction) }
    #expect(neighbors("a", .right) == "b")
    #expect(neighbors("a", .down) == "c")
    #expect(neighbors("d", .left) == "c")
    #expect(neighbors("d", .up) == "b")
    #expect(neighbors("a", .left) == nil)
    #expect(neighbors("a", .up) == nil)
    #expect(neighbors("d", .right) == nil)
}

@Test func aWidePaneHasTheLeftmostPaneBelowItAsNeighbor() {
    #expect(wideOverTwo.neighbor(of: "a", toward: .down) == "b")
    #expect(wideOverTwo.neighbor(of: "c", toward: .up) == "a")
    #expect(wideOverTwo.neighbor(of: "b", toward: .right) == "c")
    #expect(wideOverTwo.neighbor(of: "b", toward: .left) == nil)
    // The greatest overlap wins over the leftmost.
    let skewed = PaneTree.v(.p("a"), .h(.p("b"), .p("c"), weights: [1, 3]))
    #expect(skewed.neighbor(of: "a", toward: .down) == "c")
}

@Test func focusCrossesTilesSpatiallyAndReturnsToThePaneItLeft() {
    var state = space([Tile(panes: .p("x")), Tile(panes: grid), Tile(panes: .p("y"))], focus: "x")
    #expect(state.focusPane(direction: .right) == true)
    // Entering at the left edge: the remembered pane a touches it.
    #expect(state.focusedWindowID == "a")
    #expect(state.focusPane(direction: .down) == true)
    #expect(state.focusPane(direction: .right) == true)
    #expect(state.focusedWindowID == "d")
    #expect(state.focusPane(direction: .right) == true)
    #expect(state.focusedWindowID == "y")
    #expect(state.focusPane(direction: .left) == true)
    #expect(state.focusedWindowID == "d")
    #expect(state.focusPane(direction: .left) == true)
    #expect(state.focusPane(direction: .left) == true)
    #expect(state.focusedWindowID == "x")
    // Both a and c touch the left edge; the tile remembers c.
    #expect(state.focusPane(direction: .right) == true)
    #expect(state.focusedWindowID == "c")
    // Up and down never leave the tile.
    #expect(state.focusPane(direction: .down) == false)
    #expect(state.focusPane(direction: .up) == true)
    #expect(state.focusPane(direction: .up) == false)
    #expect(state.focusedWindowID == "a")
}

@Test func enteringATileWhoseRememberedPaneIsAwayFromTheEdgeTakesTheMostOverlap() {
    var state = space([Tile(panes: .v(.p("x"), .p("z"), weights: [1, 3])), Tile(panes: grid)], focus: "z")
    state.focus(windowID: "b")
    state.focus(windowID: "z")
    #expect(state.focusPane(direction: .right) == true)
    // z spans the lower three quarters; c overlaps it more than a.
    #expect(state.focusedWindowID == "c")
}

// MARK: - Moving windows

@Test func joiningAtASideAddsTheWidthsUpToTheWholeDisplay() {
    var state = lone(["a", "b", "c"], focus: "a", width: 0.4)
    #expect(state.join(windowID: "a", intoTileAt: 1, edge: .left, inSpace: 0) == true)
    #expect(trees(state) == [.h(.p("a"), .p("b")), .p("c")])
    #expect(state.currentSpace.tileWidthFraction(containing: "a") == 0.8)
    #expect(state.focusedWindowID == "a")
    #expect(state.currentSpace.tiles[0].id == "b")
    #expect(state.join(windowID: "c", intoTileAt: 0, edge: .right, inSpace: 0) == true)
    #expect(trees(state) == [.h(.p("a"), .p("b"), .p("c"))])
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 1)
    // Joining at the bottom keeps the width.
    var bottom = lone(["a", "b"], focus: "a", width: 0.4)
    #expect(bottom.join(windowID: "a", intoTileAt: 1, edge: .bottom, inSpace: 0) == true)
    #expect(trees(bottom) == [.v(.p("b"), .p("a"))])
    #expect(bottom.currentSpace.tileWidthFraction(containing: "a") == 0.4)
}

@Test func aJoiningPaneTakesTheAverageWeightOfItsSiblings() {
    var state = space([Tile(panes: .h(.p("a"), .p("b"), weights: [1, 3])), Tile(panes: .p("c"))], focus: "c")
    #expect(state.join(windowID: "c", intoTileAt: 0, edge: .right, inSpace: 0) == true)
    #expect(trees(state) == [.h(.p("a"), .p("b"), .p("c"), weights: [1, 3, 2])])
}

@Test func anExpelledWindowKeepsItsPanesWidth() {
    var state = space([Tile(panes: .h(.p("a"), .p("b"), weights: [1, 3]), widthFraction: 1), Tile(panes: .p("c"))],
                      focus: "b")
    #expect(state.expel(windowID: "b", toward: 1, inSpace: 0) == true)
    #expect(trees(state) == [.p("a"), .p("b"), .p("c")])
    #expect(state.currentSpace.tileWidthFraction(containing: "b") == 0.75)
    #expect(state.focusedWindowID == "b")
    // A pane narrower than the least width leaves at the least width.
    var narrow = space([Tile(panes: .h(.p("a"), .p("b"), weights: [1, 9]), widthFraction: 1)], focus: "a")
    #expect(narrow.expel(windowID: "a", toward: -1, inSpace: 0) == true)
    #expect(narrow.currentSpace.tileWidthFraction(containing: "a") == SpaceState.minimumWidthFraction)
    #expect(narrow.expel(windowID: "a", toward: 1, inSpace: 0) == false)
}

@Test func movingSidewaysSwapsThenLeavesThenJoins() {
    var state = space([Tile(panes: .p("x")), Tile(panes: .h(.p("a"), .p("b")), widthFraction: 1)], focus: "a")
    #expect(state.moveFocusedWindowSideways(by: 1) == true)
    #expect(trees(state) == [.p("x"), .h(.p("b"), .p("a"))])
    #expect(state.moveFocusedWindowSideways(by: 1) == true)
    #expect(trees(state) == [.p("x"), .p("b"), .p("a")])
    #expect(state.focusedWindowID == "a")
    #expect(state.moveFocusedWindowSideways(by: 1) == false)
    #expect(state.moveFocusedWindowSideways(by: -1) == true)
    #expect(trees(state) == [.p("x"), .h(.p("b"), .p("a"))])
    #expect(state.focusedWindowID == "a")
}

@Test func movingVerticallySwapsRowsAndStopsAtTheEdge() {
    var state = space([Tile(panes: wideOverTwo)], focus: "c")
    #expect(state.moveFocusedWindowVertically(by: -1) == true)
    #expect(trees(state) == [.v(.p("c"), .h(.p("b"), .p("a")))])
    #expect(state.moveFocusedWindowVertically(by: -1) == false)
    #expect(state.focusedWindowID == "c")
}

@Test func aPaneDroppedOnAnotherSwapsWithIt() {
    var state = space([Tile(panes: grid)], focus: "a")
    #expect(state.movePane(windowID: "a", to: CGPoint(x: 0.9, y: 0.9), inSpace: 0) == true)
    #expect(trees(state) == [.v(.h(.p("d"), .p("b")), .h(.p("c"), .p("a")))])
    #expect(state.movePane(windowID: "a", to: CGPoint(x: 0.9, y: 0.9), inSpace: 0) == false)
}

// MARK: - Layouts

@Test func aLayoutGathersFromTheFollowingTilesFirst() {
    var state = lone(["x", "a", "b", "c", "d"], focus: "a")
    #expect(state.arrange(tileOf: "a", layout: .wideOverTwo) == .arranged)
    #expect(trees(state) == [.p("x"), .v(.p("a"), .h(.p("b"), .p("c"))), .p("d")])
    #expect(state.currentSpace.tileWidthFraction(containing: "a") == 1)
    #expect(state.focusedWindowID == "a")
    #expect(state.currentSpace.windowIDs == ["x", "a", "b", "c", "d"])
}

@Test func aLayoutGathersFromThePrecedingTilesNearestFirstWhenTheFollowingRunOut() {
    var state = space([Tile(panes: .p("w")), Tile(panes: .v(.p("x"), .p("y"))), Tile(panes: .p("a"), widthFraction: 0.4),
                       Tile(panes: .p("b"))], focus: "a")
    #expect(state.arrange(tileOf: "a", layout: .grid) == .arranged)
    #expect(trees(state) == [.p("w"), .v(.h(.p("x"), .p("y")), .h(.p("a"), .p("b")))])
    #expect(state.focusedWindowID == "a")

    var stacked = lone(["a", "b"], focus: "b", width: 0.4)
    #expect(stacked.arrange(tileOf: "b", layout: .stacked) == .arranged)
    #expect(trees(stacked) == [.v(.p("a"), .p("b"))])
    // Stacked keeps the tile's width.
    #expect(stacked.currentSpace.tileWidthFraction(containing: "a") == 0.4)
}

@Test func aLayoutNeedingMoreWindowsThanTheSpaceHasIsRefusedWithoutAChange() {
    var state = lone(["a", "b", "c"], focus: "a")
    let before = state
    #expect(state.arrange(tileOf: "a", layout: .grid) == .notEnoughWindows(needed: 4, available: 3))
    #expect(state == before)
}

@Test func windowsBeyondALayoutsPanesLeaveAsTilesJustAfterIt() {
    var state = space([Tile(panes: grid, widthFraction: 1), Tile(panes: .p("x"))], focus: "d")
    #expect(state.arrange(tileOf: "a", layout: .sideBySide) == .arranged)
    #expect(trees(state) == [.h(.p("a"), .p("b")), .p("c"), .p("d"), .p("x")])
    #expect(state.focusedWindowID == "d")
    #expect(state.currentSpace.tileWidthFraction(containing: "c") == 0.5)
    #expect(state.arrange(tileOf: "a", layout: .sideBySide) == .unchanged)
}

@Test func theSingleLayoutBreaksATileApartInPlace() {
    var state = space([Tile(panes: .p("x")), Tile(id: "t", panes: wideOverTwo, widthFraction: 1)], focus: "b")
    #expect(state.arrange(tileOf: "b", layout: .single) == .arranged)
    #expect(trees(state) == [.p("x"), .p("a"), .p("b"), .p("c")])
    #expect(state.currentSpace.tiles.map(\.id) == ["x", "t", "b", "c"])
    #expect(state.currentSpace.tiles.map(\.widthFraction) == [SpaceState.defaultWidthFraction, 1, 0.5, 0.5])
    #expect(state.focusedWindowID == "b")
    #expect(state.arrange(tileOf: "b", layout: .single) == .unchanged)
}

// MARK: - Layout math

private let screen = CGRect(x: 0, y: 0, width: 1_000, height: 700)

private func frames(_ state: WorkspaceState, paneGap: CGFloat = 0, tileGap: CGFloat = 0,
                    observedWidths: [String: CGFloat] = [:], observedHeights: [String: CGFloat] = [:],
                    minimumWidths: [String: CGFloat] = [:],
                    minimumHeights: [String: CGFloat] = [:]) -> [String: CGRect] {
    Dictionary(uniqueKeysWithValues: WindowLayout.placements(
        for: state.currentSpace, availableFrame: screen, tileGap: tileGap, paneGap: paneGap,
        observedWidths: observedWidths, observedHeights: observedHeights,
        minimumWidths: minimumWidths, minimumHeights: minimumHeights
    ).map { ($0.windowID, $0.frame) })
}

@Test func aGridsRowsAndColumnsShareTheirEdges() {
    let placed = frames(space([Tile(panes: grid, widthFraction: 1)], focus: "a"), paneGap: 10)
    #expect(placed["a"] == CGRect(x: 0, y: 0, width: 495, height: 345))
    #expect(placed["b"] == CGRect(x: 505, y: 0, width: 495, height: 345))
    #expect(placed["c"] == CGRect(x: 0, y: 355, width: 495, height: 345))
    #expect(placed["d"] == CGRect(x: 505, y: 355, width: 495, height: 345))
}

@Test func aMinimumHeightInOneRowSizesThatRowAndTheOtherTakesTheRest() {
    let placed = frames(space([Tile(panes: grid, widthFraction: 1)], focus: "a"), paneGap: 8,
                        minimumHeights: ["b": 660, "zz": 900])
    #expect(placed["a"]?.height == 660 && placed["b"]?.height == 660)
    #expect(placed["c"]?.minY == 668 && placed["d"]?.minY == 668)
    #expect(placed["c"]?.height == 32 && placed["d"]?.height == 32)
    // An observed size counts as a minimum the same way.
    let observed = frames(space([Tile(panes: grid, widthFraction: 1)], focus: "a"), paneGap: 8,
                          observedHeights: ["b": 660])
    #expect(observed == placed)
}

@Test func aWindowSmallerThanItsPaneIsCenteredAndALargerOneStartsAtItsOrigin() {
    let placed = frames(space([Tile(panes: .h(.p("a"), .p("b")), widthFraction: 1)], focus: "a"),
                        observedWidths: ["a": 300], observedHeights: ["a": 500, "b": 900])
    #expect(placed["a"] == CGRect(x: 100, y: 100, width: 300, height: 500))
    #expect(placed["b"] == CGRect(x: 500, y: 0, width: 500, height: 900))
}

@Test func panesNeverOverlapWithoutAPaneGap() {
    let tiles = [Tile(panes: grid, widthFraction: 1), Tile(panes: .v(.p("e"), .h(.p("f"), .p("g"), .p("h"))))]
    let placed = frames(space(tiles, focus: "a"), paneGap: 0, minimumWidths: ["f": 400], minimumHeights: ["a": 300])
    for tile in tiles {
        let ids = tile.windowIDs
        for (index, first) in ids.enumerated() {
            for second in ids[(index + 1)...] {
                let overlap = placed[first]!.intersection(placed[second]!)
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-6, "\(first) \(second)")
            }
        }
    }
}

@Test func aNegativeTileGapOverlapsTilesButNeverPanes() {
    let state = space([Tile(panes: .h(.p("a"), .p("b")), widthFraction: 0.6), Tile(panes: .v(.p("c"), .p("d")),
                                                                                  widthFraction: 0.6)], focus: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: -140, paneGap: 0)
    let placed = Dictionary(uniqueKeysWithValues: placements.map { ($0.windowID, $0.frame) })
    #expect(placed["c"]!.minX == placed["b"]!.maxX - 140)
    #expect(placed["b"]!.minX == placed["a"]!.maxX)
    #expect(placed["d"]!.minY == placed["c"]!.maxY)
}

@Test func aMultiPaneTileWidensToItsMinimumUpToTheDisplay() {
    let state = space([Tile(panes: .h(.p("a"), .p("b")), widthFraction: 0.5), Tile(panes: .p("c"), widthFraction: 0.5)],
                      focus: "a")
    let placed = frames(state, minimumWidths: ["a": 400, "b": 300])
    #expect(placed["a"]?.width == 400 && placed["b"]?.width == 300)
    #expect(placed["c"]?.minX == 700)
    let capped = frames(state, minimumWidths: ["a": 800, "b": 300])
    #expect(capped["a"]?.width == 800 && capped["b"]?.maxX == 1_100)
    #expect(capped["c"]?.minX == 1_000)
    #expect(WindowLayout.minimumTileSize(Tile(panes: wideOverTwo), paneGap: 8, minimumWidths: ["b": 400, "c": 300],
                                         minimumHeights: ["a": 200, "c": 100])
        == CGSize(width: 708, height: 308))
}
