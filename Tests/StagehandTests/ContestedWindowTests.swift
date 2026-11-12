import AppKit
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

@MainActor
private final class PointerFixture {
    var location: CGPoint = .zero
}

@MainActor
@Suite(.serialized)
struct ContestedWindowTests {
    /// The built-in display shows space 0 ("a" focused, "s"); the external display, to
    /// its right, shows space 1 ("s", "f"). "s" is shown on both. The pointer starts on
    /// the built-in display.
    private func contestedHarness() async -> (ModelHarness, DisplayArrangement, PointerFixture) {
        let builtIn = ScreenDescription.testBuiltIn
        let externalScreen = ScreenDescription.external(
            number: 2,
            frame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1080),
            visibleFrame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1055))
        let arrangement = DisplayArrangement(screens: [builtIn, externalScreen])
        let pointer = PointerFixture()
        pointer.location = CGPoint(x: arrangement.displays[0].frame.midX, y: arrangement.displays[0].frame.midY)
        let harness = ModelHarness(windowIDs: ["a", "s", "f"], focused: "a")
        harness.windows.scansReportLiveFrames = true
        harness.model.displayArrangementProvider = { arrangement }
        harness.model.pointerLocationProvider = { pointer.location }
        harness.model.start()
        await harness.settle()
        let external = arrangement.displays[1].id
        func space(_ ids: [String], anchor: DisplayID? = nil) -> SpaceState {
            SpaceState(tiles: ids.map { Tile(windowID: $0, widthFraction: 0.4) }, focusedWindowID: ids.first,
                       displayAnchor: anchor)
        }
        var state = WorkspaceState(spaces: [space(["a", "s"]), space(["s", "f"], anchor: external)],
                                   shownSpaceIndices: [external: 1])
        state.setDisplays(arrangement.ids, fallback: arrangement.fallback)
        harness.model.state = state
        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()
        return (harness, arrangement, pointer)
    }

    private func placement(_ windowID: String, spaceIndex: Int, on display: Display,
                           _ harness: ModelHarness) -> WindowPlacement? {
        WindowLayout.placements(for: harness.model.state.spaces[spaceIndex], availableFrame: display.visibleFrame,
                                tileGap: harness.model.gap, paneGap: harness.model.paneGap,
                                preferredHeights: harness.model.preferredHeights)
            .first { $0.windowID == windowID }
    }

    private func holderEvents(_ harness: ModelHarness) -> [[String: String]] {
        harness.events("contested_window_holder").compactMap { $0["details"] as? [String: String] }
    }

    private func moveRealWindow(_ harness: ModelHarness, to point: CGPoint, pointer: PointerFixture) async {
        pointer.location = point
        harness.overlays.onPointerMoved?()
        await harness.settle()
    }

    @Test func theRealWindowIsOnThePointersDisplayAndAPlaceholderOnTheOther() async throws {
        let (harness, arrangement, _) = await contestedHarness()
        defer { harness.cleanUp() }
        let builtIn = arrangement.displays[0]
        let external = arrangement.displays[1]
        let onBuiltIn = try #require(placement("s", spaceIndex: 0, on: builtIn, harness))
        let onExternal = try #require(placement("s", spaceIndex: 1, on: external, harness))
        #expect(onBuiltIn.isVisible && onExternal.isVisible)

        #expect(harness.model.contestedHolders == ["s": builtIn.id])
        #expect(harness.windows.windows["s"]?.frame == onBuiltIn.frame)
        #expect(harness.placeholders.shown.map(\.windowID) == ["s"])
        #expect(harness.placeholders.frame(of: "s", on: external.id) == onExternal.frame)
        #expect(harness.overlays.onPointerMoved != nil)
        #expect(holderEvents(harness).last == ["windowID": "s", "from": "none", "to": builtIn.id.logPrefix,
                                               "trigger": "layout"])
        #expect(!harness.windows.isParked(windowID: "s"))
    }

    @Test func aPointerCrossingMovesANonFocusedWindowAndItsPlaceholder() async throws {
        let (harness, arrangement, pointer) = await contestedHarness()
        defer { harness.cleanUp() }
        let builtIn = arrangement.displays[0]
        let external = arrangement.displays[1]
        let focusedFrame = harness.windows.windows["a"]?.frame

        await moveRealWindow(harness, to: CGPoint(x: external.frame.midX, y: external.frame.midY), pointer: pointer)

        let onExternal = try #require(placement("s", spaceIndex: 1, on: external, harness))
        let onBuiltIn = try #require(placement("s", spaceIndex: 0, on: builtIn, harness))
        #expect(harness.model.contestedHolders == ["s": external.id])
        #expect(harness.windows.windows["s"]?.frame == onExternal.frame)
        #expect(harness.placeholders.shown.map(\.display) == [builtIn.id])
        #expect(harness.placeholders.frame(of: "s", on: builtIn.id) == onBuiltIn.frame)
        #expect(holderEvents(harness).last?["trigger"] == "pointer")
        #expect(harness.model.state.focusedWindowID == "a" && harness.model.state.activeSpaceIndex == 0)
        #expect(harness.windows.windows["a"]?.frame == focusedFrame)

        await moveRealWindow(harness, to: CGPoint(x: builtIn.frame.midX, y: builtIn.frame.midY), pointer: pointer)
        #expect(harness.windows.windows["s"]?.frame == onBuiltIn.frame)
        #expect(harness.placeholders.frame(of: "s", on: external.id) == onExternal.frame)
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func theFocusedWindowStaysOnTheFocusedDisplayUntilFocusLeavesIt() async throws {
        let (harness, arrangement, pointer) = await contestedHarness()
        defer { harness.cleanUp() }
        let builtIn = arrangement.displays[0]
        let external = arrangement.displays[1]
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "s")
        let typingFrame = try #require(harness.windows.windows["s"]?.frame)
        #expect(builtIn.frame.contains(CGPoint(x: typingFrame.midX, y: typingFrame.midY)))
        let holderChanges = holderEvents(harness).count
        harness.windows.setFrameWrites.removeAll()
        func queuedRefreshes() -> Int {
            harness.events("change_queued").count { ($0["details"] as? [String: String])?["operation"] == "refresh" }
        }
        let refreshes = queuedRefreshes()

        await moveRealWindow(harness, to: CGPoint(x: external.frame.midX, y: external.frame.midY), pointer: pointer)
        #expect(queuedRefreshes() == refreshes)
        harness.model.enqueue(.refresh)
        await harness.settle()
        #expect(harness.windows.windows["s"]?.frame == typingFrame)
        #expect(!harness.windows.setFrameWrites.contains { $0.windowID == "s" })
        #expect(holderEvents(harness).count == holderChanges)

        harness.model.navigate(.focusPrevious)
        await harness.settle()
        let onExternal = try #require(placement("s", spaceIndex: 1, on: external, harness))
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.windows.windows["s"]?.frame == onExternal.frame)
        #expect(harness.placeholders.frame(of: "s", on: builtIn.id) != nil)
    }

    @Test func clickingAPlaceholderFocusesTheWindowOnThatDisplay() async throws {
        let (harness, arrangement, _) = await contestedHarness()
        defer { harness.cleanUp() }
        let builtIn = arrangement.displays[0]
        let external = arrangement.displays[1]

        harness.placeholders.click("s", on: external.id)
        await harness.settle()

        let state = harness.model.state
        #expect(state.activeSpaceIndex == 1 && state.focusedDisplay == external.id)
        #expect(state.focusedWindowID == "s")
        #expect(state.shownSpaceIndex(on: builtIn.id) == 0)
        let onExternal = try #require(placement("s", spaceIndex: 1, on: external, harness))
        #expect(harness.windows.windows["s"]?.frame == onExternal.frame)
        #expect(harness.model.contestedHolders == ["s": external.id])
        #expect(harness.placeholders.shown.map(\.display) == [builtIn.id])
        #expect(holderEvents(harness).last?["trigger"] == "click")
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func aSlideMovesThePlaceholderNotTheWindow() async throws {
        let (harness, arrangement, pointer) = await contestedHarness()
        defer { harness.cleanUp() }
        let builtIn = arrangement.displays[0]
        let external = arrangement.displays[1]
        await moveRealWindow(harness, to: CGPoint(x: external.frame.midX, y: external.frame.midY), pointer: pointer)
        let realFrame = harness.windows.windows["s"]?.frame
        let writes = harness.windows.motionPositionWrites
        let slid = try #require(harness.placeholders.frame(of: "s", on: builtIn.id)).offsetBy(dx: -50, dy: 0)

        harness.model.applyMotionFrames(["s": slid])

        #expect(harness.placeholders.frame(of: "s", on: builtIn.id) == slid)
        #expect(harness.windows.motionPositionWrites == writes)
        #expect(harness.windows.windows["s"]?.frame == realFrame)
        #expect(harness.model.navigationFrames()["s"] == slid)
    }

    @Test func thePointerWatchRunsOnlyWhileAWindowIsContested() async throws {
        let (harness, _, _) = await contestedHarness()
        defer { harness.cleanUp() }
        #expect(harness.overlays.onPointerMoved != nil)

        harness.model.removeMembership(windowID: "s", fromSpaceIndex: 1)
        await harness.settle()

        #expect(harness.model.contestedHolders.isEmpty)
        #expect(harness.overlays.onPointerMoved == nil)
        #expect(harness.placeholders.shown.isEmpty)

        harness.model.shareMembership(windowID: "s", fromSpaceIndex: 0, toSpaceIndex: 1)
        await harness.settle()
        #expect(harness.overlays.onPointerMoved != nil)

        harness.model.pause()
        #expect(harness.overlays.onPointerMoved == nil)
        #expect(harness.placeholders.shown.isEmpty)
    }

    @Test func withOneDisplayThereAreNoPlaceholdersOrPointerWatch() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.shareMembership(windowID: "a", fromSpaceIndex: 0, toSpaceIndex: 1)
        await harness.settle()
        for action in [NavigationAction.focusNext, .goToSpace(index: 1), .goToSpace(index: 0), .focusPrevious] {
            harness.model.navigate(action)
            await harness.settle()
        }
        #expect(harness.placeholders.calls == 0)
        #expect(harness.overlays.onPointerMoved == nil)
        #expect(harness.model.contestedHolders.isEmpty && harness.model.placeholderFrames.isEmpty)
        #expect(harness.events("contested_window_holder").isEmpty)
    }
}
