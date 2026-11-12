import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

// Slice 2 of tile stacking: the paths that must keep a stack intact while
// nothing in the UI creates one yet.

private func stackedSpace(_ tiles: [[String]], focus: String? = nil, widths: [Double]? = nil,
                          weights: [[Double]]? = nil) -> SpaceState {
    SpaceState(tiles: tiles.enumerated().map { index, members in
        Tile(windowIDs: members, widthFraction: widths?[index] ?? SpaceState.defaultWidthFraction,
             heightWeights: weights?[index] ?? [])
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
    #expect(state.currentSpace.tiles[1].heightWeight(for: "c") == 2.5)
    #expect(state.currentSpace.widthFraction(for: "c") == 0.6)
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
    #expect(state.currentSpace.widthFraction(for: "c") == 0.6)
}

@Test func aStackedWindowWhoseMatesAreGoneReturnsAsItsOwnTile() {
    let saved = stacked([["a"], ["b", "c"], ["d"]], focus: "a")
    var state = saved
    state.reconcile(windowIDs: ["a", "d"])
    state.restoreMemberships(windowIDs: ["c"], from: saved)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["c"], ["d"]])
}

@Test func rejoinPlacesARelaunchedMemberAmongItsMates() {
    var state = stacked([["a"], ["b", "d"]], focus: "a")
    #expect(state.rejoin(windowID: "new", savedMembers: ["b", "new", "d"], heightWeight: 3, inSpace: 0) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b", "new", "d"]])
    #expect(state.currentSpace.tiles[1].heightWeight(for: "new") == 3)
    #expect(state.focusedWindowID == "a")
    #expect(state.rejoin(windowID: "other", savedMembers: ["x", "other"], heightWeight: 1, inSpace: 0) == false)
    #expect(state.rejoin(windowID: "new", savedMembers: ["b", "new"], heightWeight: 1, inSpace: 0) == false)
}

// MARK: - Drops and resizes

@Test func aStackedWindowDroppedOutsideItsTileBecomesItsOwnTileThere() {
    var state = stacked([["a"], ["b", "c"], ["d"]], focus: "c", widths: [0.5, 0.6, 0.7])
    #expect(state.unstack(windowID: "c", toTileAt: 3, inSpace: 0) == true)
    #expect(state.currentSpace.tiles.map(\.windowIDs) == [["a"], ["b"], ["d"], ["c"]])
    #expect(state.focusedWindowID == "c")
    #expect(state.currentSpace.widthFraction(for: "c") == 0.6)

    var front = stacked([["a"], ["b", "c"]], focus: "b")
    #expect(front.unstack(windowID: "b", toTileAt: -4, inSpace: 0) == true)
    #expect(front.currentSpace.tiles.map(\.windowIDs) == [["b"], ["a"], ["c"]])
    #expect(front.focusedWindowID == "b")

    var lone = stacked([["a"], ["b"]], focus: "a")
    #expect(lone.unstack(windowID: "a", toTileAt: 1, inSpace: 0) == false)
}

@Test func heightWeightsAreSetOnlyForStackedMembers() {
    var state = stacked([["a"], ["b", "c"]], focus: "a")
    #expect(state.setHeightWeight(2, for: "b") == true)
    #expect(state.currentSpace.tiles[1].heightWeights == [2, 1])
    #expect(state.setHeightWeight(2, for: "b") == false)
    #expect(state.setHeightWeight(2, for: "a") == false)
    #expect(state.setHeightWeight(0, for: "c") == false)
    #expect(state.setHeightWeight(.nan, for: "c") == false)
    #expect(state.setHeightWeight(3, for: "missing") == false)
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
            case 0: state.unstack(windowID: id, toTileAt: Int.random(in: -1...5, using: &generator), inSpace: 0)
            case 1: state.setHeightWeight([0.5, 1, 3, -1].randomElement(using: &generator)!, for: id)
            case 2: state.reconcile(windowIDs: pool.filter { _ in Bool.random(using: &generator) })
            case 3: state.restoreMemberships(windowIDs: Set(pool.filter { _ in Bool.random(using: &generator) }),
                                             from: saved)
            case 4: state.rejoin(windowID: "n\(Int.random(in: 0..<3, using: &generator))",
                                 savedMembers: ["w1", "n0", "w4", "n1", "n2"], heightWeight: 2, inSpace: 0)
            default: state.moveFocusedWindowAcrossTiles(by: Bool.random(using: &generator) ? 1 : -1)
            }
            for space in state.spaces {
                let flat = space.tiles.flatMap(\.windowIDs)
                #expect(space.windowIDs == flat)
                #expect(Set(flat).count == flat.count)
                #expect(space.tiles.allSatisfy { !$0.windowIDs.isEmpty && $0.windowIDs.contains($0.activeWindowID)
                    && $0.heightWeights.count == $0.windowIDs.count })
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

@Test func aStackThatCannotFitIsCenteredAtItsMinimumsAndReportsItsHeight() throws {
    let state = stacked([["a", "b"]], focus: "a")
    let minimums: [String: CGFloat] = ["a": 500, "b": 400]
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 8, minimumHeights: minimums)
    #expect(try frame(placements, "a").height == 500)
    #expect(try frame(placements, "b").height == 400)
    #expect(try frame(placements, "a").minY == 350 - 454)
    #expect(WindowLayout.minimumStackHeight(windowIDs: ["a", "b"], gap: 8, minimumHeights: minimums) == 908)
    #expect(WindowLayout.minimumStackHeight(windowIDs: ["a", "b", "c"], gap: -20, minimumHeights: minimums) == 900)
    #expect(WindowLayout.minimumStackHeight(windowIDs: ["a", "z"], gap: .nan,
                                            minimumHeights: ["a": 10, "z": .infinity]) == 18)
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

@Test func anObservedHeightStillWinsOverAMinimum() throws {
    let state = stacked([["a", "b"]], focus: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: 0,
                                             observedHeights: ["a": 200], minimumHeights: ["a": 600])
    #expect(try frame(placements, "a").height == 200)
    #expect(try frame(placements, "b").height == 500)
}
