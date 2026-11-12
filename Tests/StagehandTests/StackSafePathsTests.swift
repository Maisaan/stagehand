import AppKit
@testable import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

// Slice 2 of column stacking. Nothing in the UI creates a stack yet, so these
// build stacked states directly and drive the paths that must keep them intact.

private func columns(_ members: [[String]], focus: String? = nil, widths: [Double]? = nil,
                     weights: [[Double]]? = nil) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(columns: members.enumerated().map { index, ids in
        ColumnState(windowIDs: ids, widthFraction: widths?[index] ?? SpaceState.defaultWidthFraction,
                    heightWeights: weights?[index] ?? [])
    }, focusedWindowID: focus)])
}

private func layout(_ state: WorkspaceState) -> [[String]] {
    state.currentSpace.columns.map(\.windowIDs)
}

// MARK: - Ribbon motion

@Test func focusMovingWithinAColumnDoesNotSlideTheRibbon() {
    let before = columns([["a"], ["b", "c"]], focus: "b")
    var below = before
    below.focus(windowID: "c")
    #expect(!shouldSlideRibbon(from: before, to: below, source: .managed, hadPreview: false, reduceMotion: false))
    // A gesture preview moved the windows, so they still slide back.
    #expect(shouldSlideRibbon(from: before, to: below, source: .managed, hadPreview: true, reduceMotion: false))
    var across = before
    across.focus(windowID: "a")
    #expect(shouldSlideRibbon(from: before, to: across, source: .managed, hadPreview: false, reduceMotion: false))
    // A join keeps focus on the moved window: it snaps, as any unchanged focus does.
    var joined = columns([["a"], ["b"]], focus: "a")
    joined.moveFocusedWindowAcrossColumns(by: 1)
    #expect(!shouldSlideRibbon(from: columns([["a"], ["b"]], focus: "a"), to: joined, source: .managed,
                               hadPreview: false, reduceMotion: false))
    // Leaving a column and entering another member's column is not within one column.
    var split = columns([["a", "b"], ["c"]], focus: "a")
    split.unstack(windowID: "a", toward: 1, inSpace: 0)
    split.focus(windowID: "b")
    #expect(shouldSlideRibbon(from: columns([["a", "b"], ["c"]], focus: "a"), to: split, source: .managed,
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
        #expect(dropColumnIndex(windowID: dragged, droppedMidX: midX, placements: placements, space: space) == old)
    }
}

@Test func aStackCountsAsOneSlotForADrop() {
    let space = columns([["a"], ["b", "c"], ["d"]], focus: "a").currentSpace
    let placements = [
        WindowPlacement(windowID: "a", frame: CGRect(x: 0, y: 0, width: 100, height: 700), isVisible: true, isFocused: true),
        WindowPlacement(windowID: "b", frame: CGRect(x: 110, y: 0, width: 200, height: 340), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "c", frame: CGRect(x: 110, y: 350, width: 150, height: 350), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "d", frame: CGRect(x: 320, y: 0, width: 100, height: 700), isVisible: true, isFocused: false)
    ]
    // Right of the stack's slot center (210), left of d's (370).
    #expect(dropColumnIndex(windowID: "a", droppedMidX: 300, placements: placements, space: space) == 1)
    #expect(dropColumnIndex(windowID: "a", droppedMidX: 200, placements: placements, space: space) == 0)
    #expect(dropColumnIndex(windowID: "c", droppedMidX: 500, placements: placements, space: space) == 3)
}

// MARK: - Resizes

@Test func aStackedResizeTradesHeightWithTheNeighborOnTheDraggedEdge() throws {
    let column = ColumnState(windowIDs: ["a", "b", "c"])
    let heights: [String: CGFloat] = ["a": 200, "b": 300, "c": 200]
    let previous = CGRect(x: 0, y: 210, width: 500, height: 300)
    // Bottom edge down by 100: c gives it.
    let bottom = try #require(stackResize(column: column, windowID: "b", previous: previous,
                                          observed: CGRect(x: 0, y: 210, width: 500, height: 400),
                                          height: { heights[$0] }, minimumHeight: { _ in nil }))
    #expect(bottom.neighborID == "c")
    #expect(abs(bottom.weight - 2 * 400 / 500) < 1e-9 && abs(bottom.neighborWeight - 2 * 100 / 500) < 1e-9)
    // Top edge up by 100: a gives it.
    let top = try #require(stackResize(column: column, windowID: "b", previous: previous,
                                       observed: CGRect(x: 0, y: 110, width: 500, height: 400),
                                       height: { heights[$0] }, minimumHeight: { _ in nil }))
    #expect(top.neighborID == "a")
    // The stack's own top edge has no neighbor above, so the one below trades.
    let first = try #require(stackResize(column: column, windowID: "a", previous: CGRect(x: 0, y: 0, width: 500, height: 200),
                                         observed: CGRect(x: 0, y: -50, width: 500, height: 250),
                                         height: { heights[$0] }, minimumHeight: { _ in nil }))
    #expect(first.neighborID == "b")
    // The neighbor keeps its known minimum height.
    let floored = try #require(stackResize(column: column, windowID: "b", previous: previous,
                                           observed: CGRect(x: 0, y: 210, width: 500, height: 480),
                                           height: { heights[$0] }, minimumHeight: { $0 == "c" ? 150 : nil }))
    #expect(abs(floored.neighborWeight - 2 * 150 / 500) < 1e-9)
    #expect(stackResize(column: ColumnState(windowIDs: ["a"]), windowID: "a", previous: previous,
                        observed: CGRect(x: 0, y: 210, width: 500, height: 400),
                        height: { heights[$0] }, minimumHeight: { _ in nil }) == nil)
}

// MARK: - Relaunch slots

private func record(_ id: String, app: String, pid: Int32, title: String = "") -> WindowRecord {
    WindowRecord(id: id, appName: app, title: title, bundleIdentifier: "test.\(app)", pid: pid,
                 frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
}

private let start = Date(timeIntervalSince1970: 1_000)

private func quit(_ records: [WindowRecord], pid: Int32, windows: inout [WindowRecord],
                  state: inout WorkspaceState, restoration: inout WorkspaceRestoration,
                  slots: inout RelaunchSlots) {
    for window in records {
        let before = state
        _ = removeDestroyedWindow(windowID: window.id, windows: &windows, state: &state,
                                  restoration: &restoration,
                                  trackedWindowIDs: Set(windows.map(\.id)).subtracting([window.id]))
        slots.windowsLeft([window], layout: before, preferredHeights: [:], at: start)
    }
    slots.applicationTerminated(pid: pid, at: start)
}

@Test func aRelaunchedStackMemberReturnsIntoItsStack() {
    let gone = record("old", app: "updated", pid: 2)
    var windows = [record("left", app: "left", pid: 1), record("top", app: "top", pid: 3), gone,
                   record("bottom", app: "bottom", pid: 4)]
    var state = columns([["left"], ["top", "old", "bottom"]], focus: "old", widths: [0.5, 0.6],
                        weights: [[1], [1, 2, 1]])
    var restoration = WorkspaceRestoration()
    var slots = RelaunchSlots()
    quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration, slots: &slots)
    #expect(layout(state) == [["left"], ["top", "bottom"]])
    state.focus(windowID: "left")

    let placements = slots.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                                 restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(placements.map(\.windowID) == ["new"])
    #expect(layout(state) == [["left"], ["top", "new", "bottom"]])
    #expect(state.currentSpace.columns[1].heightWeight(for: "new") == 2)
    #expect(state.currentSpace.widthFraction(for: "new") == 0.6)
    #expect(state.focusedWindowID == "left")
}

/// The slot index was a window index; next to a stack it is a column index.
@Test func aRelaunchedLoneWindowReturnsBesideAStackAtItsColumn() {
    let gone = record("old", app: "updated", pid: 2)
    var windows = [record("a", app: "a", pid: 1), record("b", app: "b", pid: 3), gone, record("c", app: "c", pid: 4)]
    var state = columns([["a", "b"], ["old"], ["c"]], focus: "c")
    var restoration = WorkspaceRestoration()
    var slots = RelaunchSlots()
    quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration, slots: &slots)

    _ = slots.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                    restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(layout(state) == [["a", "b"], ["new"], ["c"]])
}

@Test func aRelaunchedAppWhoseWindowsWereAStackRebuildsIt() {
    let first = record("o1", app: "updated", pid: 2)
    let second = record("o2", app: "updated", pid: 2)
    var windows = [record("x", app: "x", pid: 1), first, second]
    var state = columns([["x"], ["o1", "o2"]], focus: "x", widths: [0.5, 0.7])
    var restoration = WorkspaceRestoration()
    var slots = RelaunchSlots()
    quit([first, second], pid: 2, windows: &windows, state: &state, restoration: &restoration, slots: &slots)
    #expect(layout(state) == [["x"]])

    _ = slots.place(windows + [record("n1", app: "updated", pid: 20), record("n2", app: "updated", pid: 20)],
                    state: &state, restoration: &restoration, at: start.addingTimeInterval(5))

    #expect(layout(state) == [["x"], ["n1", "n2"]])
    #expect(state.currentSpace.widthFraction(for: "n2") == 0.7)
}

// MARK: - Restoration and rollback

@Test func aRollbackReturnsToTheColumnsFromBeforeTheTransition() {
    let stacked = columns([["a"], ["b", "c"]], focus: "c", weights: [[1], [2, 1]])
    var restoration = WorkspaceRestoration()
    var state = stacked
    restoration.beginTransition(from: state)
    state.unstack(windowID: "c", toward: 1, inSpace: 0)
    #expect(layout(state) == [["a"], ["b"], ["c"]])

    #expect(restoration.rollBack(state: &state, windowIDs: ["a", "b", "c"], trackedWindowIDs: ["a", "b", "c"]))

    #expect(state == stacked)
}

@Test func aStackedWindowThatWasUnavailableRejoinsItsStack() {
    var restoration = WorkspaceRestoration()
    var state = columns([["a"], ["b", "c", "d"]], focus: "a", weights: [[1], [1, 3, 1]])
    // c is still tracked but not live, as a busy or hidden app's window.
    restoration.reconcile(state: &state, windowIDs: ["a", "b", "d"], trackedWindowIDs: ["a", "b", "c", "d"])
    #expect(layout(state) == [["a"], ["b", "d"]])

    restoration.reconcile(state: &state, windowIDs: ["a", "b", "c", "d"], trackedWindowIDs: ["a", "b", "c", "d"])

    #expect(layout(state) == [["a"], ["b", "c", "d"]])
    #expect(state.currentSpace.columns[1].heightWeight(for: "c") == 3)
}

@Test func pausingKeepsStacksInTheRememberedLayout() {
    var restoration = WorkspaceRestoration()
    let stacked = columns([["a"], ["b", "c"]], focus: "b")
    let paused = restoration.pause(state: stacked, windowIDs: ["a", "b", "c"], trackedWindowIDs: ["a", "b", "c"])
    #expect(layout(paused) == [["a"], ["b", "c"]])
    #expect(paused.isPaused)
}

// MARK: - The model, against in-memory windows

@MainActor
@Suite(.serialized)
struct StackScenarioTests {
    /// A started model whose active space is `members`, laid out. Columns are narrow
    /// so the whole ribbon stays on screen.
    private func harness(_ members: [[String]], focus: String, width: Double = 0.25,
                         prepare: (FakeWindowSystem) -> Void = { _ in }) async -> ModelHarness {
        let harness = ModelHarness(windowIDs: members.flatMap { $0 }, focused: focus)
        harness.windows.scansReportLiveFrames = true
        prepare(harness.windows)
        harness.model.start()
        await harness.settle()
        harness.model.state = columns(members, focus: focus, widths: members.map { _ in width })
        harness.model.enqueue(.refresh)
        await harness.settle()
        return harness
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

    @Test func focusWithinAColumnDoesNotSlideTheRibbon() async {
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

    @Test func aMemberDroppedWithinItsColumnMovesUpOrDown() async {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        let b = frame(harness, "b")

        await userChanged(harness, "c", to: frame(harness, "c").offsetBy(dx: 30, dy: b.minY - 20 - frame(harness, "c").minY))

        #expect(layout(harness.model.state) == [["a"], ["c", "b"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(abs(frame(harness, "c").minY - b.minY) <= 1)
        #expect(noPause(harness))
    }

    @Test func aMemberDroppedOutsideItsColumnBecomesItsOwnColumnThere() async throws {
        let harness = await harness([["a"], ["b", "c"]], focus: "c")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        let c = frame(harness, "c")

        await userChanged(harness, "c", to: CGRect(x: available.maxX - c.width / 2, y: c.minY,
                                                    width: c.width, height: c.height))

        #expect(layout(harness.model.state) == [["a"], ["b"], ["c"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(abs(harness.model.state.currentSpace.widthFraction(for: "c") - 0.25) < 0.001)
        #expect(noPause(harness))
    }

    /// A lone window's drop counted windows; beside a stack it counts slots.
    @Test func aLoneWindowDroppedPastAStackLandsAfterIt() async {
        let harness = await harness([["a"], ["b", "c"], ["d"]], focus: "a")
        defer { harness.cleanUp() }
        let stackSlot = frame(harness, "b")
        let d = frame(harness, "d")
        let a = frame(harness, "a")
        // Between the stack's slot center and d's center.
        let midX = (stackSlot.midX + d.midX) / 2

        await userChanged(harness, "a", to: CGRect(x: midX - a.width / 2, y: a.minY, width: a.width, height: a.height))

        #expect(layout(harness.model.state) == [["b", "c"], ["a"], ["d"]])
        #expect(noPause(harness))
    }

    @Test func resizingAStackedWindowTradesHeightWithItsNeighborAndSetsTheColumnWidth() async throws {
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

        // A wider c widens the column, both members with it.
        let c3 = frame(harness, "c")
        await userChanged(harness, "c", to: CGRect(x: c3.minX, y: c3.minY, width: c3.width + 120, height: c3.height))
        #expect(abs(frame(harness, "c").width - (c3.width + 120)) <= 1)
        #expect(abs(frame(harness, "b").width - (c3.width + 120)) <= 1)
        #expect(abs(harness.model.state.currentSpace.widthFraction(for: "b") - Double((c3.width + 120) / available.width)) < 0.001)
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

    /// Each refused width was written back to the column, so two members with
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
        #expect(abs(space.widthFraction(for: "b") - 0.5) < 0.001)
        #expect(abs(space.widthFraction(for: "a") - 0.3) < 0.001)
        #expect(abs(frame(harness, "b").width - available.width * 0.5) <= 1)
        #expect(abs(frame(harness, "c").width - available.width * 0.4) <= 1)
        #expect(frame(harness, "b").minX == frame(harness, "c").minX)
        #expect(noPause(harness))
    }

    @Test func aJoinThatFitsSnapsIntoTheStackAndMemberFocusFollows() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)

        harness.model.changeColumns(.moveFocusedWindowAcrossColumns(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["b", "a"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(frame(harness, "a").minY > frame(harness, "b").maxY)
        #expect(abs(frame(harness, "a").maxY - available.maxY) <= 1)

        harness.model.changeColumns(.focusMember(direction: -1))
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")
        #expect(details(harness, "navigation_motion_planned").last?["slideEnabled"] == "false")
        #expect(harness.events("column_change_refused").isEmpty)
        #expect(noPause(harness))
    }

    @Test func aStackKnownNotToFitIsRefusedBeforeItIsMadeWithoutPausing() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [ColumnRefusal] = []
        harness.model.onColumnChangeRefused = { refusals.append($0) }
        harness.model.learnedMinimumHeights = ["a": available.height * 0.6, "b": available.height * 0.6]
        let before = harness.model.state
        let writes = harness.windows.setFrameCalls.count

        harness.model.changeColumns(.moveFocusedWindowAcrossColumns(direction: 1))
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(refusals.count == 1)
        let event = try #require(details(harness, "column_change_refused").last)
        #expect(event["decided"] == "before_change")
        #expect(event["reason"] == "stack_does_not_fit")
        #expect(details(harness, "change_queued").last?["operation"] == "columns.stackRight")
        #expect(noPause(harness))
        #expect(harness.model.warning == nil)
    }

    @Test func aStackFoundNotToFitByItsLayoutIsUndoneWithoutPausingAndRefusedNextTime() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        var refusals: [ColumnRefusal] = []
        harness.model.onColumnChangeRefused = { refusals.append($0) }
        harness.windows.minimumSizes = [
            "a": CGSize(width: 1, height: available.height * 0.6),
            "b": CGSize(width: 1, height: available.height * 0.6)
        ]
        let a = frame(harness, "a")

        harness.model.changeColumns(.moveFocusedWindowAcrossColumns(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(details(harness, "column_change_refused").map { $0["decided"] } == ["after_layout"])
        #expect(refusals.count == 1)
        #expect(frame(harness, "a").minX == a.minX)
        #expect(harness.model.learnedMinimumHeights.keys.sorted() == ["a", "b"])
        #expect(noPause(harness))

        harness.model.changeColumns(.moveFocusedWindowAcrossColumns(direction: 1))
        await harness.settle()

        #expect(layout(harness.model.state) == [["a"], ["b"]])
        #expect(details(harness, "column_change_refused").map { $0["decided"] }
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

    @Test func aFailedSwitchRollsBackToTheStackedColumns() async {
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
