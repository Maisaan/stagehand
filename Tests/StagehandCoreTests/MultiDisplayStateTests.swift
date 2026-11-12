import Foundation
import Testing
@testable import StagehandCore

private let builtIn = DisplayID(rawValue: "BUILT-IN")
private let external = DisplayID(rawValue: "EXTERNAL")
private let third = DisplayID(rawValue: "THIRD")

private func workspace(_ spaces: [[String]], active: Int = 0, anchors: [Int: DisplayID] = [:]) -> WorkspaceState {
    let count = max(spaces.count, (anchors.keys.max() ?? -1) + 1)
    return WorkspaceState(spaces: (0..<count).map { index in
        let base = SpaceState(windowIDs: spaces.indices.contains(index) ? spaces[index] : [])
        return SpaceState(tiles: base.tiles, focusedWindowID: base.focusedWindowID, displayAnchor: anchors[index])
    }, activeSpaceIndex: active)
}

private func twoDisplays(_ state: WorkspaceState) -> WorkspaceState {
    var state = state
    state.setDisplays([builtIn, external], fallback: builtIn)
    return state
}

// MARK: - Anchoring

@Test func aNewDisplayTakesTheLowestEmptyUnshownSpaceAndNothingElseMoves() {
    var state = workspace([[], ["b"], [], ["d"]])
    let before = state.spaces.map(\.windowIDs)
    #expect(state.setDisplays([builtIn, external], fallback: builtIn) == [external: 2])
    #expect(state.spaces[2].displayAnchor == external)
    #expect(state.spaces.map(\.windowIDs) == before)
    #expect(state.activeSpaceIndex == 0)
    #expect(state.focusedDisplay == builtIn)
    #expect(state.shownSpaceIndex(on: external) == 2)
    #expect([0, 1, 3].allSatisfy { state.display(ofSpace: $0) == builtIn })
    #expect(state.setDisplays([builtIn, external], fallback: builtIn).isEmpty)
}

@Test func aDisplayWithoutAFreeSpaceStaysUnmanaged() {
    var state = workspace((0..<WorkspaceState.spaceCount).map { ["w\($0)"] })
    #expect(state.setDisplays([builtIn, external], fallback: builtIn).isEmpty)
    #expect(state.shownSpaceIndex(on: external) == nil)
    #expect(state.displayedSpaceIndices(on: external).isEmpty)
    #expect(state.displayedSpaceIndices == Array(0..<WorkspaceState.spaceCount))
}

@Test func unpluggingAndRepluggingKeepsAnchorsAndReturnsTheShownSpace() {
    var state = twoDisplays(workspace([["a"], ["b"], ["c"], ["d"]], anchors: [2: external, 3: external]))
    #expect(state.apply(.goToSpace(index: 3)) == true)
    #expect(state.apply(.goToSpace(index: 0)) == true)
    #expect(state.shownSpaceIndex(on: external) == 3)

    state.setDisplays([builtIn], fallback: builtIn)
    #expect(state.spaces[2].displayAnchor == external && state.spaces[3].displayAnchor == external)
    #expect(state.spaces.indices.allSatisfy { state.display(ofSpace: $0) == builtIn })
    #expect(state.displayedSpaceIndices == [0, 1, 2, 3])
    #expect(state.apply(.nextSpace) == true)
    #expect(state.activeSpaceIndex == 1)

    #expect(state.setDisplays([builtIn, external], fallback: builtIn).isEmpty)
    #expect(state.display(ofSpace: 2) == external && state.display(ofSpace: 3) == external)
    #expect(state.shownSpaceIndex(on: external) == 3)
    #expect(state.displayedSpaceIndices == [0, 1])
    #expect(state.displayedSpaceIndices(on: external) == [2, 3])
}

@Test func withTheLidClosedEverySpaceIsOnTheExternalDisplay() {
    var state = twoDisplays(workspace([["a"], ["b"], ["c"], ["d"]], anchors: [2: external, 3: builtIn]))
    state.setDisplays([external], fallback: nil)
    #expect(state.spaces.indices.allSatisfy { state.display(ofSpace: $0) == external })
    #expect(state.focusedDisplay == external)
    #expect(state.displayedSpaceIndices == [0, 1, 2, 3])
    #expect(state.spaces[2].displayAnchor == external && state.spaces[3].displayAnchor == builtIn)

    state.setDisplays([builtIn, external], fallback: builtIn)
    #expect(state.display(ofSpace: 0) == builtIn && state.display(ofSpace: 3) == builtIn)
    #expect(state.display(ofSpace: 2) == external)
}

@Test func compactionAndOpeningKeepAnchorsWithTheirSpaces() {
    var state = twoDisplays(workspace([["a"], [], ["c"], ["d"]], anchors: [2: external, 3: external]))
    #expect(state.apply(.goToSpace(index: 3)) == true)
    #expect(state.apply(.goToSpace(index: 0)) == true)

    #expect(state.closeEmptySpace(at: 1) == true)
    #expect(state.spaces[1].windowIDs == ["c"] && state.spaces[1].displayAnchor == external)
    #expect(state.spaces[2].windowIDs == ["d"] && state.spaces[2].displayAnchor == external)
    #expect(state.shownSpaceIndices[external] == 2)

    #expect(state.openSpace(at: 1) == true)
    #expect(state.spaces[1].displayAnchor == nil)
    #expect(state.spaces[2].displayAnchor == external && state.spaces[3].displayAnchor == external)
    #expect(state.shownSpaceIndices[external] == 3)
}

@Test func aDisplaysOnlySpaceIsNeitherClosedNorDropped() {
    var state = twoDisplays(workspace([["a"], [], ["c"]], anchors: [1: external]))
    #expect(state.closeEmptySpace(at: 1) == false)

    var lastAnchored = twoDisplays(workspace([["a"]], anchors: [8: external]))
    #expect(lastAnchored.openSpace(at: 1) == false)

    state.discardSpace(at: 1)
    #expect(state.spaces[1].windowIDs == ["c"] && state.spaces[1].displayAnchor == nil)
    #expect(state.spaces[2].displayAnchor == external)
    #expect(state.shownSpaceIndex(on: external) == 2)
}

// MARK: - Focus and navigation

@Test func previousAndNextSpaceStayOnTheFocusedDisplay() {
    var state = twoDisplays(workspace([["a"], ["b"], ["c"], ["d"]], anchors: [1: external, 3: external]))
    #expect(state.displayedSpaceIndices == [0, 2])
    #expect(state.displayedSpaceIndices(on: external) == [1, 3])
    #expect(state.apply(.nextSpace) == true)
    #expect(state.activeSpaceIndex == 2)
    #expect(state.apply(.nextSpace) == false)
    #expect(state.apply(.previousSpace) == true)
    #expect(state.activeSpaceIndex == 0)
    #expect(state.apply(.previousSpace) == false)
}

@Test func goingToASpaceOnAnotherDisplayFocusesThatDisplayAndTheOtherKeepsItsSpace() {
    var state = twoDisplays(workspace([["a"], ["b"], ["c"]], active: 1, anchors: [2: external]))
    #expect(state.apply(.goToSpace(index: 2)) == true)
    #expect(state.focusedDisplay == external)
    #expect(state.shownSpaceIndices == [builtIn: 1])
    #expect(state.shownSpaceIndex(on: builtIn) == 1)

    #expect(state.apply(.goToSpace(index: 0)) == true)
    #expect(state.focusedDisplay == builtIn)
    #expect(state.shownSpaceIndices == [external: 2])

    #expect(state.focus(windowID: "c", inSpace: 2) == true)
    #expect(state.focusedDisplay == external && state.shownSpaceIndices == [builtIn: 0])
}

@Test func movingASpaceReanchorsItAndKeepsFocus() {
    var state = twoDisplays(workspace([["a"], ["b"], ["c"]], active: 1))
    #expect(state.shownSpaceIndex(on: external) == 3)

    #expect(state.apply(.moveSpaceToDisplay(direction: 1)) == true)
    #expect(state.spaces[1].displayAnchor == external)
    #expect(state.activeSpaceIndex == 1 && state.focusedWindowID == "b")
    #expect(state.focusedDisplay == external)
    #expect(state.shownSpaceIndex(on: builtIn) == 0)
    #expect(state.shownSpaceIndices[external] == nil)
    #expect(state.apply(.moveSpaceToDisplay(direction: 1)) == false)

    #expect(state.apply(.moveSpaceToDisplay(direction: -1)) == true)
    #expect(state.spaces[1].displayAnchor == builtIn && state.focusedDisplay == builtIn)
    #expect(state.activeSpaceIndex == 1 && state.focusedWindowID == "b")

    #expect(state.moveSpace(2, toDisplay: external) == true)
    #expect(state.shownSpaceIndex(on: external) == 2 && state.activeSpaceIndex == 1)
    #expect(state.moveSpace(2, toDisplay: external) == false)
    #expect(state.moveSpace(2, toDisplay: third) == false)
}

@Test func aDisplayWhoseOnlySpaceMovesAwayTakesAnEmptyOne() {
    var state = twoDisplays(workspace([["a"], ["b"]]))
    #expect(state.shownSpaceIndex(on: external) == 2)
    #expect(state.moveSpace(2, toDisplay: builtIn) == true)
    #expect(state.spaces[3].displayAnchor == external)
    #expect(state.shownSpaceIndex(on: external) == 3)
}

@Test func spacesCannotMoveWithOneDisplay() {
    var state = workspace([["a"], ["b"]])
    #expect(state.apply(.moveSpaceToDisplay(direction: 1)) == false)
    state.setDisplays([builtIn], fallback: builtIn)
    #expect(state.apply(.moveSpaceToDisplay(direction: 1)) == false)
    #expect(state.moveSpace(0, toDisplay: builtIn) == false)
    #expect(state.spaces.allSatisfy { $0.displayAnchor == nil })
}

@Test func newWindowsJoinTheSpaceShownOnTheirDisplay() {
    var state = twoDisplays(workspace([["a"], ["b"]], anchors: [1: external]))
    state.reconcile(windowIDs: ["a", "b", "n1", "n2", "n3"], displayOfWindow: {
        ["n1": external, "n3": third][$0]
    })
    #expect(state.spaces[0].windowIDs == ["a", "n2", "n3"])
    #expect(state.spaces[1].windowIDs == ["b", "n1"])
    #expect(state.spaces[1].focusedWindowID == "n1")
    #expect(state.activeSpaceIndex == 0 && state.focusedWindowID == "n3")

    let settled = state
    state.reconcile(windowIDs: ["a", "b", "n1", "n2", "n3"], displayOfWindow: { _ in builtIn })
    #expect(state == settled)
}

@Test func keyNavigationCrossesToTheNeighboringDisplayAtTheRibbonEnd() {
    var state = twoDisplays(workspace([["a", "b"], ["c", "d", "e"]], anchors: [1: external]))
    state.focus(windowID: "d", inSpace: 1)
    state.focus(windowID: "a", inSpace: 0)

    #expect(state.focusWindowCrossingDisplays(by: -1) == false)
    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.focusedWindowID == "b")
    #expect(state.apply(.focusNext) == false)
    #expect(state.activeSpaceIndex == 0)

    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.activeSpaceIndex == 1 && state.focusedWindowID == "d" && state.focusedDisplay == external)
    #expect(state.shownSpaceIndex(on: builtIn) == 0)
    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.focusedWindowID == "e")

    state.focus(windowID: "c", inSpace: 1)
    #expect(state.focusWindowCrossingDisplays(by: -1, visibleTiles: { _ in 0...1 }) == true)
    #expect(state.activeSpaceIndex == 0 && state.focusedWindowID == "b")

    #expect(state.focusWindowCrossingDisplays(by: 1, visibleTiles: { _ in 1...2 }) == true)
    #expect(state.focusedWindowID == "d")
}

@Test func crossingIntoATileEntersThePaneFacingTheOneLeft() {
    var state = WorkspaceState(spaces: [
        SpaceState(tiles: [Tile(panes: .stack(["a", "b"]))], focusedWindowID: "b"),
        SpaceState(tiles: [Tile(panes: .v(.h(.p("c"), .p("d")), .h(.p("e"), .p("f"))), activeWindowID: "f")],
                   displayAnchor: external)
    ])
    state.setDisplays([builtIn, external], fallback: builtIn)
    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.focusedWindowID == "e")
}

@Test func crossingReachesAnEmptyShownSpaceButNotAnUnmanagedDisplay() {
    var state = twoDisplays(workspace([["a"]]))
    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.focusedDisplay == external && state.focusedWindowID == nil)
    #expect(state.focusWindowCrossingDisplays(by: -1) == true)
    #expect(state.focusedWindowID == "a")

    var full = workspace((0..<WorkspaceState.spaceCount).map { ["w\($0)"] })
    full.setDisplays([builtIn, external], fallback: builtIn)
    #expect(full.focusWindowCrossingDisplays(by: 1) == false)
    #expect(full.activeSpaceIndex == 0)
}

@Test func withOneDisplayKeyNavigationStopsAtTheRibbonEnd() {
    var state = workspace([["a", "b"], ["c"]])
    state.setDisplays([builtIn], fallback: builtIn)
    #expect(state.focusWindowCrossingDisplays(by: 1) == true)
    #expect(state.focusedWindowID == "b")
    #expect(state.focusWindowCrossingDisplays(by: 1) == false)
    #expect(state.activeSpaceIndex == 0 && state.focusedWindowID == "b")
}

// MARK: - Invariants and persistence

@Test func displayStateKeepsItsInvariants() throws {
    for seed in UInt64(0)..<300 {
        var generator = SeededGenerator(seed: seed)
        var state = workspace((0..<Int.random(in: 0...5, using: &generator)).map { _ in
            (0..<Int.random(in: 0...2, using: &generator)).map { _ in "w\(Int.random(in: 0..<6, using: &generator))" }
        })
        let displayPool = [builtIn, external, third]
        for step in 0..<60 {
            let space = Int.random(in: -1...9, using: &generator)
            let display = displayPool.randomElement(using: &generator)!
            let direction = [-1, 1].randomElement(using: &generator)!
            let windowID = "w\(Int.random(in: 0..<6, using: &generator))"
            let displayBefore = state.focusedDisplay
            let operation: String
            switch Int.random(in: 0..<14, using: &generator) {
            case 0:
                let connected = Array(displayPool.shuffled(using: &generator)
                    .prefix(Int.random(in: 0...3, using: &generator)))
                state.setDisplays(connected, fallback: connected.randomElement(using: &generator))
                operation = "setDisplays \(connected)"
            case 1: state.apply(.goToSpace(index: space)); operation = "goToSpace \(space)"
            case 2: state.focus(windowID: windowID, inSpace: space); operation = "focus \(windowID) \(space)"
            case 3: state.apply(.moveToSpace(index: space, follow: true)); operation = "moveToSpace \(space)"
            case 4: state.moveSpace(space, toDisplay: display); operation = "moveSpace \(space) \(display)"
            case 5:
                state.apply(.moveSpaceToDisplay(direction: direction))
                operation = "moveSpaceToDisplay \(direction)"
            case 6:
                state.focusWindowCrossingDisplays(by: direction)
                operation = "crossing \(direction)"
            case 7:
                let live = (0..<8).map { "w\($0)" }.filter { _ in Int.random(in: 0..<3, using: &generator) != 0 }
                state.reconcile(windowIDs: live, displayOfWindow: { _ in display })
                operation = "reconcile \(live) on \(display)"
            case 8: state.closeEmptySpace(at: space); operation = "closeEmptySpace \(space)"
            case 9: state.openSpace(at: space); operation = "openSpace \(space)"
            case 10: state.discardSpace(at: space); operation = "discardSpace \(space)"
            case 11:
                let moved = state.apply(.nextSpace)
                if moved { #expect(state.focusedDisplay == displayBefore, "seed \(seed) step \(step) nextSpace") }
                operation = "nextSpace"
            case 12:
                let moved = state.apply(.previousSpace)
                if moved { #expect(state.focusedDisplay == displayBefore, "seed \(seed) step \(step) previousSpace") }
                operation = "previousSpace"
            default:
                state.placeAfterFocused(windowID: windowID, inSpace: space)
                operation = "placeAfterFocused \(windowID) \(space)"
            }
            let problems = displayViolations(state)
            #expect(problems.isEmpty, "seed \(seed) step \(step) \(operation): \(problems)\n\(state)")
            var decoded = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
            #expect(decoded.spaces == state.spaces && decoded.shownSpaceIndices == state.shownSpaceIndices
                && decoded.activeSpaceIndex == state.activeSpaceIndex && decoded.displays.ids.isEmpty)
            decoded.setDisplays(state.displays.ids, fallback: state.displays.fallback)
            #expect(decoded == state, "seed \(seed) step \(step) \(operation): round trip")
            if !problems.isEmpty || decoded != state { return }
        }
    }
}

private func displayViolations(_ state: WorkspaceState) -> [String] {
    var problems: [String] = []
    if let focused = state.focusedDisplay {
        if state.shownSpaceIndices[focused] != nil { problems.append("focused display in shownSpaceIndices") }
        if state.shownSpaceIndex(on: focused) != state.activeSpaceIndex { problems.append("focused shows another") }
    }
    if !state.shownSpaceIndices.values.allSatisfy({ (0..<WorkspaceState.spaceCount).contains($0) }) {
        problems.append("shown index out of range")
    }
    let connected = state.displays.ids
    if !connected.isEmpty, !state.spaces.indices.allSatisfy({ state.display(ofSpace: $0).map(connected.contains) == true }) {
        problems.append("space on a disconnected display")
    }
    let shown = connected.compactMap { display in state.shownSpaceIndex(on: display).map { (display, $0) } }
    if shown.contains(where: { state.display(ofSpace: $0.1) != $0.0 }) { problems.append("shown space elsewhere") }
    if Set(shown.map(\.1)).count != shown.count { problems.append("space shown twice") }
    if connected.count > 1, !state.displayedSpaceIndices.allSatisfy({ state.display(ofSpace: $0) == state.focusedDisplay }) {
        problems.append("picker lists another display's space")
    }
    return problems
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
