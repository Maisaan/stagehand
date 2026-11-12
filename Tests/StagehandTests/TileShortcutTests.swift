import AppKit
@testable import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

// Slice T4 of tiles: the shortcuts, the refusal notes, the pane gap, the app bar
// and the shortcut ribbon that make tiles reachable.

private func tiles(_ members: [[String]], focus: String? = nil, width: Double = 0.25) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(tiles: members.map {
        Tile(stacking: $0, widthFraction: width)
    }, focusedWindowID: focus)])
}

private func layout(_ state: WorkspaceState) -> [[String]] {
    state.currentSpace.tiles.map(\.windowIDs)
}

private func record(_ id: String) -> WindowRecord {
    WindowRecord(id: id, appName: id, title: "", bundleIdentifier: "test.\(id)", pid: 1,
                 frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
}

private func panes(_ state: WorkspaceState) -> [PaneTree] {
    state.currentSpace.tiles.map(\.panes)
}

@Test func theTileActionsChangeTilesInTheWorkspace() {
    var state = tiles([["a"], ["b"], ["c"]], focus: "b")
    #expect(state.apply(.moveWindowRightInTile) == true)
    #expect(panes(state) == [.p("a"), .h(.p("b"), .p("c"))])
    #expect(state.apply(.moveWindowRightInTile) == true)
    #expect(panes(state) == [.p("a"), .h(.p("c"), .p("b"))])
    #expect(state.apply(.moveWindowRightInTile) == true)
    #expect(layout(state) == [["a"], ["c"], ["b"]])
    #expect(state.apply(.moveWindowRightInTile) == false)
    #expect(state.apply(.moveWindowLeftInTile) == true)
    #expect(panes(state) == [.p("a"), .h(.p("c"), .p("b"))])
    #expect(state.apply(.focusPaneAbove) == false)

    #expect(state.apply(.arrangeTile(.stacked)) == true)
    #expect(panes(state) == [.p("a"), .v(.p("c"), .p("b"))])
    #expect(state.apply(.focusPaneAbove) == true)
    #expect(state.focusedWindowID == "c")
    #expect(state.apply(.focusPaneAbove) == false)
    #expect(state.apply(.focusPaneBelow) == true)
    #expect(state.apply(.focusPaneBelow) == false)
    #expect(state.apply(.moveWindowUpInTile) == true)
    #expect(panes(state) == [.p("a"), .v(.p("b"), .p("c"))])
    #expect(state.apply(.moveWindowUpInTile) == false)
    #expect(state.apply(.moveWindowDownInTile) == true)
    #expect(panes(state) == [.p("a"), .v(.p("c"), .p("b"))])
    #expect(state.focusedWindowID == "b")

    #expect(state.apply(.arrangeTile(.grid)) == false)
    #expect(state.apply(.arrangeTile(.single)) == true)
    #expect(layout(state) == [["a"], ["c"], ["b"]])
    #expect(state.apply(.arrangeTile(.single)) == false)
    #expect(state.focusedWindowID == "b")
}

@Test func everyLayoutCanBeMadeFromLoneWindows() {
    let lone = tiles([["a"], ["b"], ["c"], ["d"]], focus: "b", width: 0.5)
    let expected: [(PaneLayout, [PaneTree], Double)] = [
        (.sideBySide, [.p("a"), .h(.p("b"), .p("c")), .p("d")], 1),
        (.stacked, [.p("a"), .v(.p("b"), .p("c")), .p("d")], 0.5),
        (.grid, [.v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")))], 1),
        (.wideOverTwo, [.p("a"), .v(.p("b"), .h(.p("c"), .p("d")))], 1),
    ]
    for (layout, trees, width) in expected {
        var state = lone
        #expect(state.apply(.arrangeTile(layout)) == true, "\(layout)")
        #expect(panes(state) == trees, "\(layout)")
        #expect(state.focusedWindowID == "b", "\(layout)")
        #expect(state.currentSpace.tileWidthFraction(containing: "b") == width, "\(layout)")
    }
    var single = lone
    #expect(single.apply(.arrangeTile(.single)) == false)
}

@Test func spatialFocusCrossesAGridAndReturnsToThePaneItLeft() {
    var state = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(windowID: "x"),
        Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")))),
        Tile(windowID: "y")
    ], focusedWindowID: "x")])
    let steps: [(NavigationAction, String)] = [
        (.focusNext, "a"), (.focusNext, "b"), (.focusNext, "y"), (.focusPrevious, "b"),
        (.focusPaneBelow, "d"), (.focusPrevious, "c"), (.focusPrevious, "x"), (.focusNext, "c"),
        (.focusNext, "d"), (.focusNext, "y"), (.focusPrevious, "d"), (.focusPaneAbove, "b"),
    ]
    for (action, focus) in steps {
        #expect(state.apply(action) == true, "\(action)")
        #expect(state.focusedWindowID == focus, "\(action) -> \(focus)")
    }
    #expect(state.apply(.focusPaneAbove) == false)
}

@Test func everyTileActionMapsToItsTileChangeAndNothingElseDoes() {
    let mapped: [(NavigationAction, TileChange)] = [
        (.moveWindowLeftInTile, .moveWindowSideways(direction: -1)),
        (.moveWindowRightInTile, .moveWindowSideways(direction: 1)),
        (.moveWindowUpInTile, .moveWindowVertically(direction: -1)),
        (.moveWindowDownInTile, .moveWindowVertically(direction: 1)),
        (.focusPaneAbove, .focusPane(.up)),
        (.focusPaneBelow, .focusPane(.down)),
    ] + PaneLayout.allCases.map { (.arrangeTile($0), .arrange($0)) }
    for (action, change) in mapped {
        #expect(TileChange(action) == change)
        #expect(!action.isStagehandCommand)
    }
    for action in ShortcutBinding.defaults.map(\.action) where !mapped.contains(where: { $0.0 == action }) {
        #expect(TileChange(action) == nil)
    }
    // Spatial ⌃⌥←/→ stays a window navigation, with its motion.
    #expect(TileChange(.focusNext) == nil)
    // The benchmark's stack scenario keeps a vertical tile and member steps.
    #expect(NavigationAction.stackNext == .arrangeTile(.stacked))
    #expect(NavigationAction.stackPrevious == .arrangeTile(.stacked))
    #expect(NavigationAction.focusMemberAbove == .focusPaneAbove)
    #expect(NavigationAction.focusMemberBelow == .focusPaneBelow)
}

@MainActor
@Test func thePaneGapIsNeverNegativeAndIsSaved() {
    #expect(GapInput.clamped(-12, to: GapInput.paneGapBounds) == 0)
    #expect(GapInput.clamped(80, to: GapInput.paneGapBounds) == 40)
    let harness = ModelHarness(windowIDs: ["a"], focused: "a")
    defer { harness.cleanUp() }
    #expect(harness.model.paneGap == 8)
    harness.model.paneGap = -30
    #expect(harness.model.paneGap == 0)
    #expect(harness.model.preferences.double(forKey: PreferenceKey.paneGap) == 0)
    harness.model.paneGap = 55
    #expect(harness.model.paneGap == 40)
    harness.model.paneGap = 12
    #expect(harness.model.preferences.double(forKey: PreferenceKey.paneGap) == 12)
}

@MainActor
@Test func theAppBarGroupsWindowsByTile() {
    let space = tiles([["a"], ["b", "c"], ["d"]], focus: "c").currentSpace
    let records = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, record($0)) })
    let groups = NavigationHUDModel.tiles(of: space, records: records)
    #expect(groups.map { $0.windows.map(\.id) } == [["a"], ["b", "c"], ["d"]])
    // A window without a record is left out; a tile left empty disappears.
    let partial = NavigationHUDModel.tiles(of: space, records: records.filter { $0.key != "a" && $0.key != "b" })
    #expect(partial.map { $0.windows.map(\.id) } == [["c"], ["d"]])
}

@Test func theShortcutRibbonListsTheTileShortcuts() {
    let hints = ShortcutHintSection.sections(for: ShortcutBinding.defaults).flatMap(\.hints)
    #expect(hints.contains(ShortcutHint(title: "In tile", modifiers: "⌃ ⌥ ⇧", keys: ["↑", "↓"])))
    #expect(hints.contains(ShortcutHint(title: "Move in tile", modifiers: "⌃ ⌥ ⇧", keys: ["←", "→"])))
    #expect(hints.contains(ShortcutHint(title: "Move in tile", modifiers: "⌃ ⌥ ⇧ ⌘", keys: ["↑", "↓"])))
    #expect(hints.contains(ShortcutHint(title: "Layouts", modifiers: "⌃ ⌥", keys: ["U", "S", "T", "G", "W"])))
}

// The 15:46 busy-columns benchmark: three 640-point probe tiles, one stacked, on
// an 1800-point screen with a -140 gap. The whole ribbon (1640 points) fits, so no
// switch slid. The benchmark now widens the tiles first.
@MainActor
@Test func theTileStackBenchmarkSlidesOnEverySwitch() {
    let probes = tiles([["a1"], ["a0"], ["b", "c"]], focus: "c", width: 640.0 / 1800)
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1130)
    #expect(!StagehandModel.everyColumnSwitchScrolls(probes, availableFrame: screen, gap: -140))

    let widened = StagehandModel.widenedForColumnBenchmark(probes)
    #expect(widened.currentSpace.tiles.allSatisfy {
        $0.widthFraction == StagehandModel.columnBenchmarkWidthFraction
    })
    #expect(layout(widened) == layout(probes))
    #expect(widened.focusedWindowID == "c")
    for width in [1024.0, 1280, 1440, 1512, 1728, 1800, 2056, 3008] {
        for gap in stride(from: GapInput.tileGapBounds.lowerBound, through: GapInput.tileGapBounds.upperBound, by: 4) {
            let frame = CGRect(x: 0, y: 25, width: width, height: width * 0.62)
            #expect(StagehandModel.everyColumnSwitchScrolls(widened, availableFrame: frame, gap: gap),
                    "screen \(width), gap \(gap)")
        }
    }
}

@MainActor
@Suite(.serialized)
struct TileShortcutScenarioTests {
    private func harness(_ members: [[String]], focus: String, width: Double = 0.25) async -> ModelHarness {
        let harness = ModelHarness(windowIDs: members.flatMap { $0 }, focused: focus)
        harness.windows.scansReportLiveFrames = true
        harness.model.start()
        await harness.settle()
        harness.model.state = tiles(members, focus: focus, width: width)
        harness.model.enqueue(.refresh)
        await harness.settle()
        return harness
    }

    private func frame(_ harness: ModelHarness, _ id: String) -> CGRect {
        harness.windows.windows[id]!.frame
    }

    private func noPause(_ harness: ModelHarness) -> Bool {
        harness.model.isRunning && harness.events("automatic_pause").isEmpty
    }

    private func harness(_ tiles: [Tile], focus: String) async -> ModelHarness {
        let harness = ModelHarness(windowIDs: tiles.flatMap(\.windowIDs), focused: focus)
        harness.windows.scansReportLiveFrames = true
        harness.model.start()
        await harness.settle()
        harness.model.state = WorkspaceState(spaces: [SpaceState(tiles: tiles, focusedWindowID: focus)])
        harness.model.enqueue(.refresh)
        await harness.settle()
        return harness
    }

    @Test func theShortcutsArrangeAGridAndTheBorderFollowsTheFocusedPane() async {
        let harness = await harness([["a"], ["b"], ["c"], ["d"], ["e"]], focus: "a", width: 0.3)
        defer { harness.cleanUp() }

        harness.model.navigate(.arrangeTile(.grid))
        await harness.settle()
        #expect(harness.model.state.currentSpace.tiles.map(\.panes)
            == [.v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d"))), .p("e")])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.windows.focusedWindowID() == "a")
        #expect(harness.overlays.borderFrame == frame(harness, "a"))
        let a = frame(harness, "a")
        let b = frame(harness, "b")
        let c = frame(harness, "c")
        let d = frame(harness, "d")
        let paneGap = CGFloat(harness.model.paneGap)
        #expect(a.minY == b.minY && c.minY == d.minY && a.maxY == b.maxY && c.maxY == d.maxY)
        #expect(a.minX == c.minX && b.maxX == d.maxX)
        #expect(b.minX - a.maxX == paneGap && c.minY - a.maxY == paneGap)

        // Inside the tile focus moves without a slide; the border takes each pane's frame.
        let writes = harness.windows.motionPositionWrites
        for (action, focus) in [(NavigationAction.focusNext, "b"), (.focusPaneBelow, "d"), (.focusPrevious, "c"),
                                (.focusPaneAbove, "a")] {
            harness.model.navigate(action)
            await harness.settle()
            #expect(harness.model.state.focusedWindowID == focus)
            #expect(harness.windows.focusedWindowID() == focus)
            #expect(harness.overlays.borderFrame == frame(harness, focus))
        }
        #expect(harness.windows.motionPositionWrites == writes)
        #expect(frame(harness, "a") == a)

        // Into the next tile and back to the pane it left.
        harness.model.navigate(.focusPaneBelow)
        await harness.settle()
        harness.model.navigate(.focusNext)
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "e")
        harness.model.navigate(.focusPrevious)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "d")
        #expect(harness.events("tile_change_refused").isEmpty)
        #expect(noPause(harness))
    }

    @Test func swapsAndLeavingWorkFromTheKeyboard() async {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }

        harness.model.navigate(.moveWindowRightInTile)
        await harness.settle()
        #expect(harness.model.state.currentSpace.tiles.map(\.panes) == [.h(.p("a"), .p("b"))])
        #expect(frame(harness, "a").maxX <= frame(harness, "b").minX)

        harness.model.navigate(.moveWindowRightInTile)
        await harness.settle()
        #expect(harness.model.state.currentSpace.tiles.map(\.panes) == [.h(.p("b"), .p("a"))])
        #expect(frame(harness, "b").maxX <= frame(harness, "a").minX)
        #expect(harness.overlays.borderFrame == frame(harness, "a"))

        harness.model.navigate(.moveWindowRightInTile)
        await harness.settle()
        #expect(layout(harness.model.state) == [["b"], ["a"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(noPause(harness))
    }

    @Test func closingAPaneCollapsesTheTreeAndFocusGoesToTheSiblingThatGrew() async {
        let harness = await harness([Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d"))))], focus: "a")
        defer { harness.cleanUp() }
        let c = frame(harness, "c")
        let d = frame(harness, "d")

        harness.windows.close("a")
        await harness.settle()

        #expect(harness.model.state.currentSpace.tiles.map(\.panes) == [.v(.p("b"), .h(.p("c"), .p("d")))])
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(frame(harness, "b").minX == c.minX && frame(harness, "b").maxX == d.maxX)
        #expect(noPause(harness))
    }

    @Test func tooFewWindowsForALayoutShowsANoteAndKeepsRunning() async {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let before = harness.model.state
        let writes = harness.windows.setFrameCalls.count

        harness.model.navigate(.arrangeTile(.grid))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.overlays.notices == ["Not arranged: this space needs 4 windows for that layout."])
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect((harness.events("tile_change_refused").first?["details"] as? [String: String])?["reason"]
            == "not_enough_windows")
        #expect(noPause(harness))
    }

    @Test func thePaneGapSeparatesPanesAndZeroMakesThemTouch() async {
        let harness = await harness([Tile(panes: .h(.p("a"), .p("b")), widthFraction: 1)], focus: "a")
        defer { harness.cleanUp() }
        harness.model.gap = -140
        harness.model.paneGap = 20
        await harness.settle()
        #expect(frame(harness, "b").minX - frame(harness, "a").maxX == 20)

        harness.model.paneGap = -5
        await harness.settle()
        #expect(frame(harness, "b").minX == frame(harness, "a").maxX)
        #expect(noPause(harness))
    }

    @Test func aRefusedTileShowsANoteAndKeepsRunning() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        harness.model.learnedMinimumHeights = ["a": available.height * 0.6, "b": available.height * 0.6]
        let before = harness.model.state

        harness.model.navigate(.arrangeTile(.stacked))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.overlays.notices == [StagehandModel.message(for: .tileDoesNotFit(
            windowIDs: [], required: .zero, available: .zero))])
        #expect(harness.overlays.warnings.isEmpty)
        #expect(harness.model.warning == nil)
        #expect(noPause(harness))

        // The next shortcut works as usual.
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(noPause(harness))
    }

    @Test func aStackedTileSlidesInAndOutOfARibbonWiderThanTheScreen() async throws {
        let harness = await harness([["a"], ["b", "c"], ["d"]], focus: "a", width: 0.75)
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)

        // Into the stack: the ribbon slides and both members arrive in one tile.
        var writes = harness.windows.motionPositionWrites
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.motionPositionWrites > writes)
        #expect(frame(harness, "b").minX == frame(harness, "c").minX)
        #expect(frame(harness, "b").intersects(available) && frame(harness, "c").intersects(available))
        #expect(frame(harness, "b").maxY <= frame(harness, "c").minY)

        // Inside the stack: no slide.
        writes = harness.windows.motionPositionWrites
        harness.model.navigate(.focusPaneBelow)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(harness.windows.motionPositionWrites == writes)

        // Out of the stack: the ribbon slides again.
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "d")
        #expect(harness.windows.motionPositionWrites > writes)
        #expect(noPause(harness))
    }

    @Test func paneFocusAtTheEndOfATileDoesNothing() async {
        let harness = await harness([["a", "b"]], focus: "b")
        defer { harness.cleanUp() }
        let writes = harness.windows.setFrameCalls.count

        harness.model.navigate(.focusPaneBelow)
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(harness.overlays.notices.isEmpty)
        #expect(noPause(harness))
    }
}
