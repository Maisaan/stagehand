import AppKit
@testable import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

// Slice 3 of column stacking: the shortcuts, the refusal note, the app bar and
// the shortcut ribbon that make stacks reachable.

private func columns(_ members: [[String]], focus: String? = nil, width: Double = 0.25) -> WorkspaceState {
    WorkspaceState(spaces: [SpaceState(columns: members.map {
        ColumnState(windowIDs: $0, widthFraction: width)
    }, focusedWindowID: focus)])
}

private func layout(_ state: WorkspaceState) -> [[String]] {
    state.currentSpace.columns.map(\.windowIDs)
}

private func record(_ id: String) -> WindowRecord {
    WindowRecord(id: id, appName: id, title: "", bundleIdentifier: "test.\(id)", pid: 1,
                 frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
}

@Test func theStackingActionsChangeColumnsInTheWorkspace() {
    var state = columns([["a"], ["b"], ["c"]], focus: "b")
    #expect(state.apply(.stackNext) == true)
    #expect(layout(state) == [["a"], ["c", "b"]])
    #expect(state.focusedWindowID == "b")
    #expect(state.apply(.focusMemberAbove) == true)
    #expect(state.focusedWindowID == "c")
    #expect(state.apply(.focusMemberAbove) == false)
    #expect(state.apply(.focusMemberBelow) == true)
    #expect(state.focusedWindowID == "b")
    #expect(state.apply(.focusMemberBelow) == false)
    #expect(state.apply(.stackPrevious) == true)
    #expect(layout(state) == [["a"], ["b"], ["c"]])
    #expect(state.focusedWindowID == "b")
    // A lone window at the end has no neighbor to join on that side.
    var end = columns([["a"], ["b"]], focus: "b")
    #expect(end.apply(.stackNext) == false)
}

@Test func everyStackingActionMapsToItsColumnChangeAndNothingElseDoes() {
    #expect(ColumnChange(.stackPrevious) == .moveFocusedWindowAcrossColumns(direction: -1))
    #expect(ColumnChange(.stackNext) == .moveFocusedWindowAcrossColumns(direction: 1))
    #expect(ColumnChange(.focusMemberAbove) == .focusMember(direction: -1))
    #expect(ColumnChange(.focusMemberBelow) == .focusMember(direction: 1))
    for action in ShortcutBinding.defaults.map(\.action)
    where ![.stackPrevious, .stackNext, .focusMemberAbove, .focusMemberBelow].contains(action) {
        #expect(ColumnChange(action) == nil)
    }
    #expect(!NavigationAction.stackNext.isStagehandCommand)
    #expect(!NavigationAction.focusMemberBelow.isStagehandCommand)
}

@MainActor
@Test func theAppBarGroupsWindowsByColumn() {
    let space = columns([["a"], ["b", "c"], ["d"]], focus: "c").currentSpace
    let records = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, record($0)) })
    let groups = NavigationHUDModel.columns(of: space, records: records)
    #expect(groups.map { $0.windows.map(\.id) } == [["a"], ["b", "c"], ["d"]])
    // A window without a record is left out; a column left empty disappears.
    let partial = NavigationHUDModel.columns(of: space, records: records.filter { $0.key != "a" && $0.key != "b" })
    #expect(partial.map { $0.windows.map(\.id) } == [["c"], ["d"]])
}

@Test func theShortcutRibbonListsTheStackingShortcuts() {
    let hints = ShortcutHintSection.sections(for: ShortcutBinding.defaults).flatMap(\.hints)
    #expect(hints.contains(ShortcutHint(title: "In stack", modifiers: "⌃ ⌥ ⇧", keys: ["↑", "↓"])))
    #expect(hints.contains(ShortcutHint(title: "Stack or unstack", modifiers: "⌃ ⌥ ⇧", keys: ["←", "→"])))
}

@MainActor
@Suite(.serialized)
struct StackShortcutScenarioTests {
    private func harness(_ members: [[String]], focus: String) async -> ModelHarness {
        let harness = ModelHarness(windowIDs: members.flatMap { $0 }, focused: focus)
        harness.windows.scansReportLiveFrames = true
        harness.model.start()
        await harness.settle()
        harness.model.state = columns(members, focus: focus)
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

    @Test func theShortcutsStackThreeWindowsAndTheBorderFollowsTheFocusedMember() async {
        let harness = await harness([["a"], ["b"], ["c"]], focus: "b")
        defer { harness.cleanUp() }

        harness.model.navigate(.stackPrevious)
        await harness.settle()
        #expect(layout(harness.model.state) == [["a", "b"], ["c"]])
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")
        #expect(harness.overlays.borderFrame == frame(harness, "b"))

        harness.model.navigate(.focusNext)
        await harness.settle()
        harness.model.navigate(.stackPrevious)
        await harness.settle()
        #expect(layout(harness.model.state) == [["a", "b", "c"]])
        #expect(harness.model.state.focusedWindowID == "c")
        #expect(harness.overlays.borderFrame == frame(harness, "c"))
        let a = frame(harness, "a")
        let b = frame(harness, "b")
        let c = frame(harness, "c")
        #expect(a.minX == b.minX && b.minX == c.minX)
        #expect(a.maxY <= b.minY && b.maxY <= c.minY)

        // Member focus walks the column without wrapping; the border takes each
        // member's own frame, not the column's.
        harness.model.navigate(.focusMemberAbove)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")
        #expect(harness.overlays.borderFrame == frame(harness, "b"))
        harness.model.navigate(.focusMemberAbove)
        harness.model.navigate(.focusMemberAbove)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.overlays.borderFrame == frame(harness, "a"))
        #expect(frame(harness, "a") == a)

        // Leaving a stack makes the window its own column on that side.
        harness.model.navigate(.stackNext)
        await harness.settle()
        #expect(layout(harness.model.state) == [["b", "c"], ["a"]])
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.overlays.borderFrame == frame(harness, "a"))
        #expect(harness.events("column_change_refused").isEmpty)
        #expect(noPause(harness))
    }

    @Test func aRefusedStackShowsANoteAndKeepsRunning() async throws {
        let harness = await harness([["a"], ["b"]], focus: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        harness.model.learnedMinimumHeights = ["a": available.height * 0.6, "b": available.height * 0.6]
        let before = harness.model.state

        harness.model.navigate(.stackNext)
        await harness.settle()

        #expect(harness.model.state == before)
        #expect(harness.overlays.notices == [StagehandModel.message(for: .stackDoesNotFit(
            windowIDs: [], requiredHeight: 0, availableHeight: 0))])
        #expect(harness.overlays.warnings.isEmpty)
        #expect(harness.model.warning == nil)
        #expect(noPause(harness))

        // The next shortcut works as usual.
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(noPause(harness))
    }

    @Test func memberFocusAtTheEndOfAColumnDoesNothing() async {
        let harness = await harness([["a", "b"]], focus: "b")
        defer { harness.cleanUp() }
        let writes = harness.windows.setFrameCalls.count

        harness.model.navigate(.focusMemberBelow)
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.setFrameCalls.count == writes)
        #expect(harness.overlays.notices.isEmpty)
        #expect(noPause(harness))
    }
}
