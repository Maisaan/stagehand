import AppKit
@testable import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

// These build multi-pane states directly and drive the paths that must keep them intact.

private func tiles(_ members: [[String]], focus: String? = nil, widths: [Double]? = nil,
                   weights: [[Double]]? = nil) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(tiles: members.enumerated().map { index, ids in
        Tile(stacking: ids, widthFraction: widths?[index] ?? SpaceState.defaultWidthFraction,
             weights: weights?[index] ?? [])
    }, focusedWindowID: focus)])
}

private func layout(_ state: WorkspaceState) -> [[String]] {
    state.currentSpace.tiles.map(\.windowIDs)
}

// MARK: - Ribbon motion

@Test func focusMovingWithinATileDoesNotSlideTheRibbon() {
    let before = tiles([["a"], ["b", "c"]], focus: "b")
    var below = before
    below.focus(windowID: "c")
    #expect(!shouldSlideRibbon(from: before, to: below, source: .managed, hadPreview: false, reduceMotion: false))
    // A gesture preview moved the windows, so they still slide back.
    #expect(shouldSlideRibbon(from: before, to: below, source: .managed, hadPreview: true, reduceMotion: false))
    var across = before
    across.focus(windowID: "a")
    #expect(shouldSlideRibbon(from: before, to: across, source: .managed, hadPreview: false, reduceMotion: false))
    // A join keeps focus on the moved window: it snaps, as any unchanged focus does.
    var joined = tiles([["a"], ["b"]], focus: "a")
    joined.moveFocusedWindowAcrossTiles(by: 1)
    #expect(!shouldSlideRibbon(from: tiles([["a"], ["b"]], focus: "a"), to: joined, source: .managed,
                               hadPreview: false, reduceMotion: false))
    // Leaving a tile and entering another member's tile is not within one tile.
    var split = tiles([["a", "b"], ["c"]], focus: "a")
    split.expel(windowID: "a", toward: 1, inSpace: 0)
    split.focus(windowID: "b")
    #expect(shouldSlideRibbon(from: tiles([["a", "b"], ["c"]], focus: "a"), to: split, source: .managed,
                              hadPreview: false, reduceMotion: false))
}

// MARK: - Drops

@Test func aDropAmongLoneWindowsLandsWhereItAlwaysDid() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
        let ids = (0..<Int.random(in: 1...6, using: &generator)).map { "w\($0)" }
        let space = SpaceState(windowIDs: ids, focusedWindowID: ids.first)
        let placements = (ids + ["gone"]).map { id in
            WindowPlacement(windowID: id, frame: CGRect(x: CGFloat(Int.random(in: -500...2_000, using: &generator)),
                                                        y: 0, width: CGFloat(Int.random(in: 1...900, using: &generator)),
                                                        height: 300),
                            isVisible: true, isFocused: false)
        }
        let dragged = ids.randomElement(using: &generator)!
        let midX = CGFloat(Int.random(in: -500...2_500, using: &generator)) + 0.5
        let old = placements.filter { $0.windowID != dragged && $0.frame.midX < midX }.count
        #expect(dropTileIndex(windowID: dragged, droppedMidX: midX, placements: placements, space: space) == old)
    }
}

@Test func aStackCountsAsOneTileForADrop() {
    let space = tiles([["a"], ["b", "c"], ["d"]], focus: "a").currentSpace
    let placements = [
        WindowPlacement(windowID: "a", frame: CGRect(x: 0, y: 0, width: 100, height: 700), isVisible: true, isFocused: true),
        WindowPlacement(windowID: "b", frame: CGRect(x: 110, y: 0, width: 200, height: 340), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "c", frame: CGRect(x: 110, y: 350, width: 150, height: 350), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "d", frame: CGRect(x: 320, y: 0, width: 100, height: 700), isVisible: true, isFocused: false)
    ]
    // Right of the stack's center (210), left of d's (370).
    #expect(dropTileIndex(windowID: "a", droppedMidX: 300, placements: placements, space: space) == 1)
    #expect(dropTileIndex(windowID: "a", droppedMidX: 200, placements: placements, space: space) == 0)
    #expect(dropTileIndex(windowID: "c", droppedMidX: 500, placements: placements, space: space) == 3)
}

// MARK: - Resizes

private func resize(_ tile: Tile, _ windowID: String, frames: [String: CGRect], to observed: CGRect,
                    minimumHeights: [String: CGFloat] = [:]) -> [PaneResize] {
    paneResize(tile: tile, windowID: windowID, previous: frames[windowID]!, observed: observed,
               frame: { frames[$0] },
               minimumSize: { WindowLayout.minimumTileSize($0, paneGap: 10, minimumWidths: [:],
                                                          minimumHeights: minimumHeights) })
}

private func share(_ resizes: [PaneResize], with neighbor: String) -> Double? {
    for case .shares(let neighborID, let share) in resizes where neighborID == neighbor { return share }
    return nil
}

@Test func aStackedResizeTradesHeightWithTheNeighborOnTheDraggedEdge() throws {
    let tile = Tile(stacking: ["a", "b", "c"])
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 500, height: 200),
        "b": CGRect(x: 0, y: 210, width: 500, height: 300),
        "c": CGRect(x: 0, y: 520, width: 500, height: 200)
    ]
    // Bottom edge down by 100: c gives it.
    let bottom = resize(tile, "b", frames: frames, to: CGRect(x: 0, y: 210, width: 500, height: 400))
    #expect(bottom.count == 1)
    #expect(abs(try #require(share(bottom, with: "c")) - 400.0 / 500) < 1e-9)
    // Top edge up by 100: a gives it.
    let top = resize(tile, "b", frames: frames, to: CGRect(x: 0, y: 110, width: 500, height: 400))
    #expect(abs(try #require(share(top, with: "a")) - 400.0 / 500) < 1e-9)
    // The tile's own top edge is not shared: the tile always fills the height.
    #expect(resize(tile, "a", frames: frames, to: CGRect(x: 0, y: -50, width: 500, height: 250)).isEmpty)
    // The neighbor keeps its known minimum height.
    let floored = resize(tile, "b", frames: frames, to: CGRect(x: 0, y: 210, width: 500, height: 480),
                         minimumHeights: ["c": 150])
    #expect(abs(try #require(share(floored, with: "c")) - 350.0 / 500) < 1e-9)
    // A side edge is the tile's: it sets the tile's width.
    #expect(resize(tile, "b", frames: frames, to: CGRect(x: 0, y: 210, width: 620, height: 300)) == [.tileWidth(620)])
}

@Test func aGridResizeTradesAcrossTheSplitOfTheDraggedEdge() throws {
    let tile = Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d"))), widthFraction: 1)
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 400, height: 300), "b": CGRect(x: 410, y: 0, width: 400, height: 300),
        "c": CGRect(x: 0, y: 310, width: 400, height: 300), "d": CGRect(x: 410, y: 310, width: 400, height: 300)
    ]
    // a's right edge is shared with b: only the top row's split changes.
    let right = resize(tile, "a", frames: frames, to: CGRect(x: 0, y: 0, width: 500, height: 300))
    #expect(right.count == 1)
    #expect(abs(try #require(share(right, with: "b")) - 500.0 / 800) < 1e-9)
    // a's bottom edge is shared with the row below: the rows trade.
    let corner = resize(tile, "a", frames: frames, to: CGRect(x: 0, y: 0, width: 500, height: 350))
    #expect(corner.count == 2)
    #expect(abs(try #require(share(corner, with: "c")) - 350.0 / 600) < 1e-9)
    // b's right edge is the tile's: it sets the width; its top edge changes nothing.
    #expect(resize(tile, "b", frames: frames, to: CGRect(x: 410, y: 0, width: 500, height: 300))
        == [.tileWidth(910)])
    #expect(resize(tile, "b", frames: frames, to: CGRect(x: 410, y: -40, width: 400, height: 340)).isEmpty)
    // A pane whose neighbor's frame is unknown changes nothing on that axis.
    var unknown = frames
    unknown["b"] = nil
    #expect(resize(tile, "a", frames: unknown, to: CGRect(x: 0, y: 0, width: 500, height: 300)).isEmpty)
}

// MARK: - Relaunch places

private func record(_ id: String, app: String, pid: Int32, title: String = "") -> WindowRecord {
    WindowRecord(id: id, appName: app, title: title, bundleIdentifier: "test.\(app)", pid: pid,
                 frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
}

private let start = Date(timeIntervalSince1970: 1_000)

private func quit(_ records: [WindowRecord], pid: Int32, windows: inout [WindowRecord],
                  state: inout WorkspaceState, restoration: inout WorkspaceRestoration,
                  places: inout RelaunchPlaces) {
    for window in records {
        let before = state
        _ = removeDestroyedWindow(windowID: window.id, windows: &windows, state: &state,
                                  restoration: &restoration,
                                  trackedWindowIDs: Set(windows.map(\.id)).subtracting([window.id]))
        places.windowsLeft([window], layout: before, preferredHeights: [:], at: start)
    }
    places.applicationTerminated(pid: pid, at: start)
}

@Test func aRelaunchedStackMemberReturnsIntoItsStack() {
    let gone = record("old", app: "updated", pid: 2)
    var windows = [record("left", app: "left", pid: 1), record("top", app: "top", pid: 3), gone,
                   record("bottom", app: "bottom", pid: 4)]
    var state = tiles([["left"], ["top", "old", "bottom"]], focus: "old", widths: [0.5, 0.6],
                      weights: [[1], [1, 2, 1]])
    var restoration = WorkspaceRestoration()
    var places = RelaunchPlaces()
    quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration, places: &places)
    #expect(layout(state) == [["left"], ["top", "bottom"]])
    state.focus(windowID: "left")

    let placements = places.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                                  restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(placements.map(\.windowID) == ["new"])
    #expect(layout(state) == [["left"], ["top", "new", "bottom"]])
    #expect(state.currentSpace.tiles[1].panes.weight(of: "new") == 2)
    #expect(state.currentSpace.tileWidthFraction(containing: "new") == 0.6)
    #expect(state.focusedWindowID == "left")
}

/// The insertion index was a window index; next to a stack it is a tile index.
@Test func aRelaunchedLoneWindowReturnsBesideAStackAtItsTile() {
    let gone = record("old", app: "updated", pid: 2)
    var windows = [record("a", app: "a", pid: 1), record("b", app: "b", pid: 3), gone, record("c", app: "c", pid: 4)]
    var state = tiles([["a", "b"], ["old"], ["c"]], focus: "c")
    var restoration = WorkspaceRestoration()
    var places = RelaunchPlaces()
    quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration, places: &places)

    _ = places.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                     restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(layout(state) == [["a", "b"], ["new"], ["c"]])
}

@Test func aRelaunchedAppWhoseWindowsWereAStackRebuildsIt() {
    let first = record("o1", app: "updated", pid: 2)
    let second = record("o2", app: "updated", pid: 2)
    var windows = [record("x", app: "x", pid: 1), first, second]
    var state = tiles([["x"], ["o1", "o2"]], focus: "x", widths: [0.5, 0.7])
    var restoration = WorkspaceRestoration()
    var places = RelaunchPlaces()
    quit([first, second], pid: 2, windows: &windows, state: &state, restoration: &restoration, places: &places)
    #expect(layout(state) == [["x"]])

    _ = places.place(windows + [record("n1", app: "updated", pid: 20), record("n2", app: "updated", pid: 20)],
                     state: &state, restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(layout(state) == [["x"], ["n1", "n2"]])
    #expect(state.currentSpace.tileWidthFraction(containing: "n2") == 0.7)
}

@Test func aRelaunchedGridMemberReturnsToItsPane() {
    let gone = record("old", app: "updated", pid: 2)
    var windows = [record("x", app: "x", pid: 1), record("a", app: "a", pid: 3), gone,
                   record("c", app: "c", pid: 4), record("d", app: "d", pid: 5)]
    let grid = PaneTree.v(.h(.p("a"), .p("old"), weights: [2, 1]), .h(.p("c"), .p("d")))
    var state = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(windowID: "x", widthFraction: 0.3), Tile(panes: grid, widthFraction: 0.9)
    ], focusedWindowID: "x")])
    var restoration = WorkspaceRestoration()
    var places = RelaunchPlaces()
    quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration, places: &places)

    _ = places.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                     restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(state.currentSpace.tiles[1].panes == grid.mapWindowIDs { $0 == "old" ? "new" : $0 })
    #expect(state.currentSpace.tileWidthFraction(containing: "new") == 0.9)
    #expect(state.focusedWindowID == "x")
}

@Test func aRelaunchedAppWhoseWindowsWereSideBySideRebuildsTheTileAtItsWidth() {
    let first = record("o1", app: "updated", pid: 2)
    let second = record("o2", app: "updated", pid: 2)
    var windows = [record("x", app: "x", pid: 1), first, second]
    var state = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(windowID: "x", widthFraction: 0.3), Tile(panes: .h(.p("o1"), .p("o2")), widthFraction: 0.9)
    ], focusedWindowID: "x")])
    var restoration = WorkspaceRestoration()
    var places = RelaunchPlaces()
    quit([first, second], pid: 2, windows: &windows, state: &state, restoration: &restoration, places: &places)

    _ = places.place(windows + [record("n1", app: "updated", pid: 20), record("n2", app: "updated", pid: 20)],
                     state: &state, restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(state.currentSpace.tiles[1].panes == .h(.p("n1"), .p("n2")))
    #expect(abs(state.currentSpace.tileWidthFraction(containing: "n1") - 0.9) < 1e-9)
}

// MARK: - Restoration and rollback

@Test func aRollbackReturnsToTheTilesFromBeforeTheTransition() {
    let stacked = tiles([["a"], ["b", "c"]], focus: "c", weights: [[1], [2, 1]])
    var restoration = WorkspaceRestoration()
    var state = stacked
    restoration.beginTransition(from: state)
    state.expel(windowID: "c", toward: 1, inSpace: 0)
    #expect(layout(state) == [["a"], ["b"], ["c"]])

    #expect(restoration.rollBack(state: &state, windowIDs: ["a", "b", "c"], trackedWindowIDs: ["a", "b", "c"]))

    #expect(state == stacked)
}

@Test func aStackedWindowThatWasUnavailableRejoinsItsStack() {
    var restoration = WorkspaceRestoration()
    var state = tiles([["a"], ["b", "c", "d"]], focus: "a", weights: [[1], [1, 3, 1]])
    // c is still tracked but not live, as a busy or hidden app's window.
    restoration.reconcile(state: &state, windowIDs: ["a", "b", "d"], trackedWindowIDs: ["a", "b", "c", "d"])
    #expect(layout(state) == [["a"], ["b", "d"]])

    restoration.reconcile(state: &state, windowIDs: ["a", "b", "c", "d"], trackedWindowIDs: ["a", "b", "c", "d"])

    #expect(layout(state) == [["a"], ["b", "c", "d"]])
    #expect(state.currentSpace.tiles[1].panes.weight(of: "c") == 3)
}

@Test func pausingKeepsStacksInTheRememberedLayout() {
    var restoration = WorkspaceRestoration()
    let stacked = tiles([["a"], ["b", "c"]], focus: "b")
    let paused = restoration.pause(state: stacked, windowIDs: ["a", "b", "c"], trackedWindowIDs: ["a", "b", "c"])
    #expect(layout(paused) == [["a"], ["b", "c"]])
    #expect(paused.isPaused)
}

@Test func aRollbackAndAPauseKeepAGrid() {
    let grid = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(windowID: "x", widthFraction: 0.3),
        Tile(panes: .v(.h(.p("a"), .p("b"), weights: [1, 2]), .h(.p("c"), .p("d"))), widthFraction: 0.8)
    ], focusedWindowID: "b")])
    let ids = ["x", "a", "b", "c", "d"]
    var restoration = WorkspaceRestoration()
    var state = grid
    restoration.beginTransition(from: state)
    state.expel(windowID: "b", toward: 1, inSpace: 0)
    #expect(restoration.rollBack(state: &state, windowIDs: ids, trackedWindowIDs: Set(ids)))
    #expect(state == grid)

    let paused = restoration.pause(state: grid, windowIDs: ids, trackedWindowIDs: Set(ids))
    #expect(paused.currentSpace.tiles == grid.currentSpace.tiles)
}

@Test func aGridWindowThatWasUnavailableReturnsToItsPane() {
    var restoration = WorkspaceRestoration()
    let grid = WorkspaceState(spaces: [SpaceState(tiles: [
        Tile(panes: .v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")), weights: [2, 1]), widthFraction: 0.8)
    ], focusedWindowID: "a")])
    var state = grid
    restoration.reconcile(state: &state, windowIDs: ["a", "b", "d"], trackedWindowIDs: ["a", "b", "c", "d"])
    #expect(state.currentSpace.tiles[0].panes == .v(.h(.p("a"), .p("b")), .p("d"), weights: [2, 1]))

    restoration.reconcile(state: &state, windowIDs: ["a", "b", "c", "d"], trackedWindowIDs: ["a", "b", "c", "d"])

    #expect(state.currentSpace.tiles == grid.currentSpace.tiles)
}

// MARK: - The model, against in-memory windows

@MainActor
@Suite(.serialized)
struct TileScenarioTests {
    /// A started model whose active space is `members`, laid out. Tiles are narrow
    /// so the whole ribbon stays on screen.
    private func harness(_ members: [[String]], focus: String, width: Double = 0.25,
                         prepare: (FakeWindowSystem) -> Void = { _ in }) async -> ModelHarness {
        await harness(members.map { Tile(stacking: $0, widthFraction: width) }, focus: focus, prepare: prepare)
    }

    private func harness(_ tiles: [Tile], focus: String,
                         prepare: (FakeWindowSystem) -> Void = { _ in }) async -> ModelHarness {
        let harness = ModelHarness(windowIDs: tiles.flatMap(\.windowIDs), focused: focus)
        harness.windows.scansReportLiveFrames = true
        prepare(harness.windows)
        harness.model.start()
        await harness.settle()
        harness.model.state = WorkspaceState(spaces: [SpaceState(tiles: tiles, focusedWindowID: focus)])
        harness.model.enqueue(.refresh)
        await harness.settle()
        return harness
    }

    private static let grid = PaneTree.v(.h(.p("a"), .p("b")), .h(.p("c"), .p("d")))

    private func paneGap(_ harness: ModelHarness) -> CGFloat {
        CGFloat(max(0, harness.model.gap))
    }

    private func screenWidth() -> CGFloat {
        NSScreen.screens.first?.visibleFrame.width ?? 1_440
    }

    private func frame(_ harness: ModelHarness, _ id: String) -> CGRect {
        harness.windows.windows[id]!.frame
    }

    /// The user moved or resized the focused window and released it.
    private func userChanged(_ harness: ModelHarness, _ id: String, to frame: CGRect) async {
        harness.model.lastTransition = .distantPast
        harness.windows.userSetFrame(id, frame)
        harness.model.refreshWindows()
        await harness.settle()
    }

    private func details(_ harness: ModelHarness, _ event: String) -> [[String: String]] {
        harness.events(event).map { $0["details"] as? [String: String] ?? [:] }
    }

    private func noPause(_ harness: ModelHarness) -> Bool {
        harness.model.isRunning && harness.events("automatic_pause").isEmpty
    }

    @Test func aStackFillsTheHeightAndRefreshesKeepIt() async throws {
        let harness = await harness([["a"], ["b", "c"]], focus: "b")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let gap = CGFloat(max(0, harness.model.gap))
        let b = frame(harness, "b")
        let c = frame(harness, "c")
        #expect(b.minX == c.minX)
        #expect(abs(b.minY - available.minY) <= 1 && abs(c.maxY - available.maxY) <= 1)
        #expect(abs(c.minY - b.maxY - gap) <= 1)
        #expect(abs(b.height - c.height) <= 1)

        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b", "c"]])
        #expect(frame(harness, "c") == c)
        #expect(noPause(harness))
    }

    @Test func focusWithinATileDoesNotSlideTheRibbon() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "b")
        defer { harness.cleanUp() }

        harness.model.focusWindow("c")
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "c")
        #expect(harness.windows.focusedWindowID() == "c")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(layout(harness.model.state) == [["a"], ["b", "c"]])
        #expect(noPause(harness))
    }

    @Test func aMemberDroppedWithinItsTileMovesUpOrDown() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        let b = frame(harness, "b")

        await userChanged(harness, "c", to: frame(harness, "c").offsetBy(dx: 30, dy: b.minY - 20 - frame(harness, "c").minY))

        #expect(layout(harness.model.state) == [["a"], ["c", "b"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(abs(frame(harness, "c").minY - b.minY) <= 1)
        #expect(noPause(harness))
    }

    @Test func aMemberDroppedOutsideItsTileBecomesItsOwnTileThere() async throws {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let c = frame(harness, "c")

        await userChanged(harness, "c", to: CGRect(x: available.maxX - c.width / 2, y: c.minY,
                                                    width: c.width, height: c.height))

        #expect(layout(harness.model.state) == [["a"], ["b"], ["c"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(abs(harness.model.state.currentSpace.tileWidthFraction(containing: "c") - 0.25) < 0.001)
        #expect(noPause(harness))
    }

    /// A lone window's drop counted windows; beside a stack it counts tiles.
    @Test func aLoneWindowDroppedPastAStackLandsAfterIt() async {
        let harness = await harness([["a"], ["b", "c"], ["d"]], focus: "a")
        defer { harness.cleanUp() }
        let stackFrame = frame(harness, "b")
        let d = frame(harness, "d")
        let a = frame(harness, "a")
        // Between the stack's center and d's center.
        let midX = (stackFrame.midX + d.midX) / 2

        await userChanged(harness, "a", to: CGRect(x: midX - a.width / 2, y: a.minY, width: a.width, height: a.height))

        #expect(layout(harness.model.state) == [["b", "c"], ["a"], ["d"]])
        #expect(noPause(harness))
    }

    @Test func resizingAStackedWindowTradesHeightWithItsNeighborAndSetsTheTileWidth() async throws {
        let harness = await harness([["a"], ["b", "c"]], focus: "b")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let preferred = harness.model.preferredHeights["b"]
        let b = frame(harness, "b")
        let c = frame(harness, "c")

        // b's bottom edge down 80: c gives the height.
        await userChanged(harness, "b", to: CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height + 80))
        #expect(abs(frame(harness, "b").height - (b.height + 80)) <= 1)
        #expect(abs(frame(harness, "c").height - (c.height - 80)) <= 1)
        #expect(abs(frame(harness, "b").minY - b.minY) <= 1)
        #expect(harness.model.preferredHeights["b"] == preferred)

        // c's top edge up 40: b, above it, gives the height.
        harness.model.focusWindow("c")
        await harness.settle()
        let c2 = frame(harness, "c")
        await userChanged(harness, "c", to: CGRect(x: c2.minX, y: c2.minY - 40, width: c2.width, height: c2.height + 40))
        #expect(abs(frame(harness, "c").height - (c2.height + 40)) <= 1)
        #expect(abs(frame(harness, "b").height - (b.height + 40)) <= 1)

        // A wider c widens the tile, both members with it.
        let c3 = frame(harness, "c")
        await userChanged(harness, "c", to: CGRect(x: c3.minX, y: c3.minY, width: c3.width + 120, height: c3.height))
        #expect(abs(frame(harness, "c").width - (c3.width + 120)) <= 1)
        #expect(abs(frame(harness, "b").width - (c3.width + 120)) <= 1)
        #expect(abs(harness.model.state.currentSpace.tileWidthFraction(containing: "b") - Double((c3.width + 120) / available.width)) < 0.001)
        #expect(layout(harness.model.state) == [["a"], ["b", "c"]])
        #expect(noPause(harness))
    }

    @Test func theHeightShortcutsLeaveAStackedWindowsPreferenceAlone() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "b")
        defer { harness.cleanUp() }
        let preferred = harness.model.preferredHeights["b"]
        let b = frame(harness, "b")

        harness.model.navigate(.shrinkHeight)
        await harness.settle()

        #expect(harness.model.preferredHeights["b"] == preferred)
        #expect(frame(harness, "b") == b)
    }

    /// Each refused width was written back to the tile, so two members with
    /// different minimum widths overwrote each other's in one pass.
    @Test func stackMembersRefusingTheWidthNeverOverwriteEachOther() async throws {
        let width = NSScreen.screens.first?.visibleFrame.width ?? 1_440
        let harness = await harness([["a"], ["b", "c"]], focus: "b") { windows in
            windows.minimumSizes = [
                "a": CGSize(width: width * 0.3, height: 1),
                "b": CGSize(width: width * 0.5, height: 1),
                "c": CGSize(width: width * 0.4, height: 1)
            ]
        }
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        #expect(Set(harness.windows.clampedFrameWrites).isSuperset(of: ["a", "b", "c"]))

        let space = harness.model.state.currentSpace
        #expect(abs(space.tileWidthFraction(containing: "b") - 0.5) < 0.001)
        #expect(abs(space.tileWidthFraction(containing: "a") - 0.3) < 0.001)
        #expect(abs(frame(harness, "b").width - available.width * 0.5) <= 1)
        #expect(abs(frame(harness, "c").width - available.width * 0.4) <= 1)
        // The narrower window is centered in the tile's width.
        #expect(abs(frame(harness, "b").midX - frame(harness, "c").midX) <= 1)
        #expect(noPause(harness))
    }

    @Test func aJoinThatFitsSnapsIntoTheStackAndMemberFocusFollows() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)

        harness.model.changeTiles(.moveFocusedWindowAcrossTiles(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["b", "a"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(frame(harness, "a").minY > frame(harness, "b").maxY)
        #expect(abs(frame(harness, "a").maxY - available.maxY) <= 1)

        harness.model.changeTiles(.focusMember(direction: -1))
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(harness.events("tile_change_refused").isEmpty)
        #expect(noPause(harness))
    }

    @Test func aStackKnownNotToFitIsRefusedBeforeItIsMadeWithoutPausing() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [TileRefusal] = []
        harness.model.onTileChangeRefused = { refusals.append($0) }
        harness.model.learnedMinimumHeights = ["a": available.height * 0.6, "b": available.height * 0.6]
        let before = harness.model.state
        let writes = harness.windows.setFrameCalls.count

        harness.model.changeTiles(.moveFocusedWindowAcrossTiles(direction: 1))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(refusals.count == 1)
        let event = try #require(details(harness, "tile_change_refused").last)
        #expect(event["decided"] == "before_change")
        #expect(event["reason"] == "tile_does_not_fit")
        #expect(details(harness, "change_queued").last?["operation"] == "tiles.stackRight")
        #expect(noPause(harness))
        #expect(harness.model.warning == nil)
    }

    @Test func aStackFoundNotToFitByItsLayoutIsUndoneWithoutPausingAndRefusedNextTime() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [TileRefusal] = []
        harness.model.onTileChangeRefused = { refusals.append($0) }
        harness.windows.minimumSizes = [
            "a": CGSize(width: 1, height: available.height * 0.6),
            "b": CGSize(width: 1, height: available.height * 0.6)
        ]
        let a = frame(harness, "a")

        harness.model.changeTiles(.moveFocusedWindowAcrossTiles(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(details(harness, "tile_change_refused").map { $0["decided"] } == ["after_layout"])
        #expect(refusals.count == 1)
        #expect(frame(harness, "a").minX == a.minX)
        #expect(harness.model.learnedMinimumHeights.keys.sorted() == ["a", "b"])
        #expect(noPause(harness))

        harness.model.changeTiles(.moveFocusedWindowAcrossTiles(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(details(harness, "tile_change_refused").map { $0["decided"] }
            == ["after_layout", "before_change"])
        #expect(refusals.count == 2)
        #expect(noPause(harness))
    }

    /// observedHeights lived only inside one layout, so every layout asked for the
    /// refused height again and needed a second pass to correct it.
    @Test func aLearnedMinimumHeightSizesTheNextLayoutAtOnce() async throws {
        // More than half the screen, so an equal share is refused, but less than the
        // preferred height a lone window takes in the harness.
        let tall = ((NSScreen.screens.first?.visibleFrame.height ?? 900) * 0.7).rounded()
        let harness = await harness([["a"], ["b", "c"]], focus: "b") { windows in
            windows.minimumSizes = ["c": CGSize(width: 1, height: tall)]
        }
        defer { harness.cleanUp() }
        #expect(harness.model.learnedMinimumHeights["c"] == tall)
        #expect(abs(frame(harness, "c").height - tall) <= 1)
        let refused = harness.windows.clampedFrameWrites.count
        let writes = harness.windows.setFrameCalls.count

        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()

        #expect(harness.windows.clampedFrameWrites.count == refused)
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(noPause(harness))
    }

    @Test func aGridBuiltInStateLaysOutFlush() async throws {
        let harness = await harness([Tile(panes: Self.grid, widthFraction: 1)], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let gap = paneGap(harness)
        let (a, b, c, d) = (frame(harness, "a"), frame(harness, "b"), frame(harness, "c"), frame(harness, "d"))
        #expect(abs(a.minX - available.minX) <= 1 && abs(b.maxX - available.maxX) <= 1)
        #expect(abs(a.minY - available.minY) <= 1 && abs(c.maxY - available.maxY) <= 1)
        // Rows share their top and bottom edges, columns their left and right edges.
        #expect(a.minY == b.minY && a.maxY == b.maxY && c.minY == d.minY && c.maxY == d.maxY)
        #expect(a.minX == c.minX && a.maxX == c.maxX && b.minX == d.minX && b.maxX == d.maxX)
        #expect(abs(b.minX - a.maxX - gap) <= 1 && abs(c.minY - a.maxY - gap) <= 1)
        #expect(harness.windows.clampedFrameWrites.isEmpty)
        #expect(noPause(harness))
    }

    /// Minimum widths lived only inside one layout, so every layout of a
    /// side-by-side tile asked for the refused width again and corrected it.
    @Test func aLearnedMinimumWidthSizesTheNextLayoutAtOnce() async throws {
        let wide = (screenWidth() * 0.6).rounded()
        let harness = await harness([Tile(panes: .h(.p("a"), .p("b")), widthFraction: 1)], focus: "a") { windows in
            windows.minimumSizes = ["a": CGSize(width: wide, height: 1)]
        }
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        #expect(harness.model.learnedMinimumWidths["a"] == wide)
        #expect(abs(frame(harness, "a").width - wide) <= 1)
        #expect(abs(frame(harness, "b").minX - frame(harness, "a").maxX - paneGap(harness)) <= 1)
        #expect(abs(frame(harness, "b").maxX - available.maxX) <= 1)
        let refused = harness.windows.clampedFrameWrites.count
        let writes = harness.windows.setFrameCalls.count

        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()

        #expect(harness.windows.clampedFrameWrites.count == refused)
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(noPause(harness))
    }

    @Test func aSideBySideTileWidensToItsPanesLearnedMinimums() async throws {
        let width = screenWidth()
        let harness = await harness([Tile(windowID: "x", widthFraction: 0.25),
                                     Tile(panes: .h(.p("a"), .p("b")), widthFraction: 0.5)], focus: "a") { windows in
            windows.minimumSizes = ["a": CGSize(width: width * 0.4, height: 1),
                                    "b": CGSize(width: width * 0.3, height: 1)]
        }
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let required = (width * 0.7 + paneGap(harness)) / available.width
        #expect(abs(harness.model.state.currentSpace.tileWidthFraction(containing: "a") - Double(required)) < 0.001)
        #expect(abs(frame(harness, "a").width - width * 0.4) <= 1)
        #expect(abs(frame(harness, "b").width - width * 0.3) <= 1)
        #expect(frame(harness, "b").minX > frame(harness, "a").maxX)
        #expect(abs(harness.model.state.currentSpace.tileWidthFraction(containing: "x") - 0.25) < 0.001)
        #expect(noPause(harness))
    }

    @Test func aTileKnownTooWideIsRefusedBeforeItIsMadeWithoutPausing() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [TileRefusal] = []
        harness.model.onTileChangeRefused = { refusals.append($0) }
        harness.model.learnedMinimumWidths = ["a": available.width * 0.6, "b": available.width * 0.6]
        let before = harness.model.state
        let writes = harness.windows.setFrameCalls.count

        harness.model.changeTiles(.arrange(.sideBySide))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(refusals.count == 1)
        let event = try #require(details(harness, "tile_change_refused").last)
        #expect(event["decided"] == "before_change")
        #expect(event["reason"] == "tile_does_not_fit")
        #expect(event["operation"] == "tiles.arrange.sideBySide")
        #expect(Double(event["requiredWidth"] ?? "") ?? 0 > Double(available.width))
        #expect(noPause(harness))
        #expect(harness.model.warning == nil)
    }

    @Test func aTileFoundTooWideByItsLayoutIsUndoneWithoutPausingAndRefusedNextTime() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [TileRefusal] = []
        harness.model.onTileChangeRefused = { refusals.append($0) }
        harness.windows.minimumSizes = [
            "a": CGSize(width: available.width * 0.6, height: 1),
            "b": CGSize(width: available.width * 0.6, height: 1)
        ]

        harness.model.changeTiles(.arrange(.sideBySide))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(details(harness, "tile_change_refused").map { $0["decided"] } == ["after_layout"])
        #expect(refusals.count == 1)
        #expect(harness.model.learnedMinimumWidths.keys.sorted() == ["a", "b"])
        #expect(noPause(harness))

        harness.model.changeTiles(.arrange(.sideBySide))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(details(harness, "tile_change_refused").map { $0["decided"] }
            == ["after_layout", "before_change"])
        #expect(refusals.count == 2)
        #expect(noPause(harness))
    }

    /// Leaving a tile only shrinks what it needs, so it is never refused, even
    /// when the tile left behind is still too tall.
    @Test func leavingATileThatDoesNotFitIsNotRefused() async throws {
        let harness = await harness([["a", "b", "c"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        harness.model.learnedMinimumHeights = ["b": available.height * 0.6, "c": available.height * 0.6]

        harness.model.changeTiles(.moveFocusedWindowAcrossTiles(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["b", "c"], ["a"]])
        #expect(harness.events("tile_change_refused").isEmpty)
        #expect(noPause(harness))
    }

    @Test func aLayoutNeedingMoreWindowsThanTheSpaceHasIsRefused() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let before = harness.model.state
        let writes = harness.windows.setFrameCalls.count

        harness.model.changeTiles(.arrange(.grid))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.windows.setFrameCalls.count == writes)
        let event = try #require(details(harness, "tile_change_refused").last)
        #expect(event["reason"] == "not_enough_windows")
        #expect(event["neededWindows"] == "4" && event["availableWindows"] == "2")
        #expect(harness.overlays.notices == ["Not arranged: this space needs 4 windows for that layout."])
        #expect(noPause(harness))
    }

    @Test func aWindowDroppedOnAnotherPaneOfItsGridSwapsWithIt() async {
        let harness = await harness([Tile(panes: Self.grid, widthFraction: 1)], focus: "a")
        defer { harness.cleanUp() }
        let a = frame(harness, "a")
        let d = frame(harness, "d")

        await userChanged(harness, "a", to: a.offsetBy(dx: d.midX - a.midX - 20, dy: d.midY - a.midY + 15))

        #expect(harness.model.state.currentSpace.tiles[0].panes == .v(.h(.p("d"), .p("b")), .h(.p("c"), .p("a"))))
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(frame(harness, "a") == d)
        #expect(frame(harness, "d") == a)
        #expect(noPause(harness))
    }

    @Test func resizingAGridPaneTradesAtSharedEdgesAndSetsTheWidthAtTheTilesSide() async throws {
        let harness = await harness([Tile(panes: Self.grid, widthFraction: 0.75)], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let (a, b, c, d) = (frame(harness, "a"), frame(harness, "b"), frame(harness, "c"), frame(harness, "d"))

        // a's right edge, shared with b, moves 80 right: only the top row changes.
        await userChanged(harness, "a", to: CGRect(x: a.minX, y: a.minY, width: a.width + 80, height: a.height))
        #expect(abs(frame(harness, "a").width - (a.width + 80)) <= 1)
        #expect(abs(frame(harness, "b").width - (b.width - 80)) <= 1)
        #expect(abs(frame(harness, "b").maxX - b.maxX) <= 1)
        #expect(frame(harness, "c") == c && frame(harness, "d") == d)

        // a's bottom edge, shared with the row below, moves 40 down: the rows trade.
        let a2 = frame(harness, "a")
        await userChanged(harness, "a", to: CGRect(x: a2.minX, y: a2.minY, width: a2.width, height: a2.height + 40))
        #expect(abs(frame(harness, "a").height - (a.height + 40)) <= 1)
        #expect(abs(frame(harness, "b").height - (b.height + 40)) <= 1)
        #expect(abs(frame(harness, "c").height - (c.height - 40)) <= 1)

        // a's top edge is the tile's: the next layout restores the full height.
        let a3 = frame(harness, "a")
        await userChanged(harness, "a", to: CGRect(x: a3.minX, y: a3.minY + 30, width: a3.width, height: a3.height - 30))
        #expect(frame(harness, "a") == a3)

        // b's right edge is the tile's: it sets the tile's width.
        harness.model.focusWindow("b")
        await harness.settle()
        let b2 = frame(harness, "b")
        let tileWidth = b2.maxX - a3.minX
        await userChanged(harness, "b", to: CGRect(x: b2.minX, y: b2.minY, width: b2.width + 100, height: b2.height))
        #expect(abs(harness.model.state.currentSpace.tileWidthFraction(containing: "b")
            - Double((tileWidth + 100) / available.width)) < 0.001)
        #expect(harness.model.state.currentSpace.tiles[0].panes.windowIDs == ["a", "b", "c", "d"])
        #expect(noPause(harness))
    }

    @Test func focusWithinAGridDoesNotSlideTheRibbon() async {
        let harness = await harness([Tile(windowID: "x", widthFraction: 0.25),
                                     Tile(panes: Self.grid, widthFraction: 0.7)], focus: "a")
        defer { harness.cleanUp() }
        let a = frame(harness, "a")

        harness.model.focusWindow("d")
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "d")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(frame(harness, "a") == a)
        #expect(noPause(harness))
    }

    @Test func aFailedSwitchAndAPauseKeepAGrid() async {
        let harness = await harness([Tile(windowID: "x", widthFraction: 0.25),
                                     Tile(panes: Self.grid, widthFraction: 0.7)], focus: "d")
        defer { harness.cleanUp() }
        let tiles = harness.model.state.currentSpace.tiles
        harness.windows.refusesFocus = ["x"]

        harness.model.focusWindow("x")
        await harness.settle()

        #expect(harness.events("automatic_pause").count == 1)
        #expect(harness.model.state.currentSpace.tiles == tiles)
        #expect(harness.model.state.focusedWindowID == "d")

        harness.windows.refusesFocus = []
        harness.model.start()
        await harness.settle()
        #expect(harness.model.state.currentSpace.tiles == tiles)
    }

    @Test func aFailedSwitchRollsBackToTheStackedTiles() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        harness.windows.refusesFocus = ["a"]

        harness.model.focusWindow("a")
        await harness.settle()

        #expect(harness.events("automatic_pause").count == 1)
        #expect(layout(harness.model.state) == [["a"], ["b", "c"]])
        #expect(harness.model.state.focusedWindowID == "c")
    }

    @Test func pausingAndResumingKeepsStacks() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        let c = frame(harness, "c")

        harness.model.pause()
        harness.model.start()
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b", "c"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(frame(harness, "c") == c)
        #expect(noPause(harness))
    }
}
