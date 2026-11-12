import AppKit
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

private var reduceMotionIsOff: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// The built-in display with an external display touching its right edge.
@MainActor
private func builtInWithExternalOnTheRight() -> DisplayArrangement {
    let builtIn = ScreenDescription.testBuiltIn
    let external = ScreenDescription.external(
        number: 2,
        frame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1080),
        visibleFrame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1055))
    return DisplayArrangement(screens: [builtIn, external])
}

private func space(_ ids: [String], anchor: DisplayID? = nil, widths: Double = SpaceState.defaultWidthFraction) -> SpaceState {
    SpaceState(tiles: ids.map { Tile(windowID: $0, widthFraction: widths) }, focusedWindowID: ids.first,
               displayAnchor: anchor)
}

@Test func aWindowRestingAcrossASharedEdgeIsHiddenUnlessFocused() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let placements = [
        WindowPlacement(windowID: "inside", frame: CGRect(x: 100, y: 0, width: 600, height: 600), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "peeking", frame: CGRect(x: 800, y: 0, width: 600, height: 600), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "focused", frame: CGRect(x: 700, y: 0, width: 600, height: 600), isVisible: true, isFocused: true),
        WindowPlacement(windowID: "freeSide", frame: CGRect(x: -300, y: 0, width: 600, height: 600), isVisible: true, isFocused: false),
        WindowPlacement(windowID: "hidden", frame: CGRect(x: 1400, y: 0, width: 600, height: 600), isVisible: false, isFocused: false)
    ]
    #expect(restingOffSharedEdges(placements, displayFrame: screen, sharedEdges: []) == placements)
    let rested = restingOffSharedEdges(placements, displayFrame: screen, sharedEdges: [.right])
    #expect(rested.filter(\.isVisible).map(\.windowID) == ["inside", "focused", "freeSide"])
    #expect(rested.map(\.frame) == placements.map(\.frame))
}

@MainActor
@Suite(.serialized)
struct DisplayLayoutTests {
    /// The built-in display shows space 0 (focused). The external display, to its right,
    /// shows space 3; space 1 is also on it. "s" is shared by space 2 (built-in) and 3.
    private func twoDisplayHarness() async -> (ModelHarness, DisplayArrangement) {
        let arrangement = builtInWithExternalOnTheRight()
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d", "s", "f"], focused: "a")
        harness.windows.scansReportLiveFrames = true
        harness.model.displayArrangementProvider = { arrangement }
        harness.model.start()
        await harness.settle()
        let external = arrangement.displays[1].id
        var state = WorkspaceState(spaces: [space(["a", "b", "c"], widths: 0.4), space(["d"], anchor: external),
                                            space(["s"]), space(["s", "f"], anchor: external, widths: 0.4)],
                                   shownSpaceIndices: [external: 3])
        state.setDisplays(arrangement.ids, fallback: arrangement.fallback)
        harness.model.state = state
        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()
        return (harness, arrangement)
    }

    private func frames(_ harness: ModelHarness) -> [String: CGRect] {
        harness.windows.windows.mapValues(\.frame)
    }

    @Test func eachDisplayShowsItsSpace() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)
        let external = arrangement.displays[1]
        let model = harness.model
        #expect(model.state.activeSpaceIndex == 0)

        let layouts = model.otherDisplayLayouts(in: arrangement)
        #expect(layouts.map(\.display.id) == [external.id] && layouts.map(\.spaceIndex) == [3])
        let externalShown = try #require(layouts.first).placements.filter(\.isVisible)
        #expect(Set(externalShown.map(\.windowID)) == ["s", "f"])
        for placement in externalShown {
            #expect(harness.windows.windows[placement.windowID]?.frame == placement.frame, "\(placement.windowID)")
            #expect(placement.frame.minX >= external.frame.minX)
        }
        let builtInShown = restingOffSharedEdges(
            WindowLayout.placements(for: model.state.currentSpace, availableFrame: builtIn.visibleFrame,
                                    tileGap: model.gap, paneGap: model.paneGap,
                                    preferredHeights: model.preferredHeights),
            displayFrame: builtIn.frame, sharedEdges: arrangement.sharedEdges(of: builtIn.id)).filter(\.isVisible)
        for placement in builtInShown {
            #expect(harness.windows.windows[placement.windowID]?.frame == placement.frame, "\(placement.windowID)")
        }
        #expect(harness.windows.isParked(windowID: "d"))
        #expect(harness.windows.parkRequests.last { $0.windowID == "d" }?.bounds == external.visibleFrame)
        #expect(!harness.windows.isParked(windowID: "s") && !harness.windows.isParked(windowID: "f"))

        harness.windows.setFrameWrites.removeAll()
        model.refreshWindows(forceLayout: true)
        await harness.settle()
        #expect(!harness.windows.setFrameWrites.contains { $0.windowID == "s" || $0.windowID == "f" })
    }

    @Test func clickingAWindowOnTheOtherDisplayFocusesThatDisplayWithoutMovingTheFirst() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let external = arrangement.displays[1]
        let before = frames(harness)
        harness.windows.setFrameWrites.removeAll()

        harness.windows.setFocus("s")
        harness.model.enqueue(.observedFocus("s"))
        await harness.settle()

        #expect(harness.model.state.activeSpaceIndex == 3)
        #expect(harness.model.state.focusedDisplay == external.id)
        #expect(harness.model.state.focusedWindowID == "s")
        #expect(harness.model.state.shownSpaceIndex(on: try #require(arrangement.builtIn).id) == 0)
        for id in ["a", "b", "c", "s", "f"] {
            #expect(frames(harness)[id] == before[id], "\(id) moved")
        }
        #expect(!harness.windows.setFrameWrites.contains { ["a", "b", "c"].contains($0.windowID) })
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func aRefreshFindingFocusOnTheOtherDisplayFollowsTheSpaceShownThere() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        harness.windows.setFocus("s")
        harness.model.refreshWindows()
        await harness.settle()
        #expect(harness.model.state.activeSpaceIndex == 3)
        #expect(harness.model.state.focusedDisplay == arrangement.displays[1].id)
    }

    @Test func aTitleBarDropOnTheOtherDisplayJoinsItsShownSpaceAtTheDropPosition() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let external = arrangement.displays[1]
        let start = try #require(harness.windows.windows["a"]?.frame)
        harness.model.pointerInteraction = StagehandModel.PointerInteraction(windowID: "a", placements: [],
                                                                              needsLayout: false)
        harness.windows.userSetFrame("a", CGRect(origin: CGPoint(x: external.frame.minX + 10, y: start.minY),
                                                 size: start.size))
        harness.model.refreshWindows()
        await harness.settle()

        let state = harness.model.state
        #expect(state.spaces[3].windowIDs == ["a", "s", "f"])
        #expect(!state.spaces[0].contains(windowID: "a"))
        #expect(state.activeSpaceIndex == 3 && state.focusedWindowID == "a")
        #expect(state.shownSpaceIndex(on: try #require(arrangement.builtIn).id) == 0)
        let placed = try #require(harness.windows.windows["a"]?.frame)
        #expect(placed.minX == external.visibleFrame.minX)
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func anOffSpaceWindowBackOnTheOtherDisplayIsLaidOutAgain() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let external = arrangement.displays[1]
        #expect(harness.windows.isParked(windowID: "d"))
        harness.windows.setFocus("a")
        harness.windows.userSetFrame("d", CGRect(x: external.frame.midX, y: 100, width: 600, height: 400))
        harness.model.refreshWindows()
        await harness.settle()

        #expect(harness.events("off_space_window_reappeared").contains {
            ($0["details"] as? [String: Any])?["windowID"] as? String == "d"
        })
        #expect(harness.windows.isParked(windowID: "d"))
    }

    @Test func aNewWindowJoinsTheSpaceShownOnTheDisplayItOpensOn() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let external = arrangement.displays[1]
        harness.windows.addWindow("new", pid: 300, frame: CGRect(x: external.frame.minX + 200, y: 100,
                                                                 width: 800, height: 600))
        harness.model.refreshWindows()
        await harness.settle()

        #expect(harness.model.state.spaces[3].contains(windowID: "new"))
        #expect(!harness.model.state.spaces[0].contains(windowID: "new"))
        #expect(harness.model.state.activeSpaceIndex == 0)
    }

    @Test func aNeighborRestingAcrossTheSharedEdgeIsParkedAtTheFreeEdge() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)
        let external = arrangement.displays[1]
        let placements = WindowLayout.placements(for: harness.model.state.currentSpace,
                                                 availableFrame: builtIn.visibleFrame,
                                                 tileGap: harness.model.gap, paneGap: harness.model.paneGap,
                                                 preferredHeights: harness.model.preferredHeights)
        let crossing = placements.filter { $0.isVisible && !$0.isFocused && $0.frame.maxX > builtIn.frame.maxX }
        #expect(!crossing.isEmpty, "the ribbon should leave a neighbor across the shared edge")
        for placement in crossing {
            #expect(harness.windows.isParked(windowID: placement.windowID), "\(placement.windowID)")
            #expect(harness.windows.parkRequests.last { $0.windowID == placement.windowID }?.side == .left)
        }
        for (id, window) in harness.windows.windows where !["s", "f"].contains(id) {
            #expect(!window.frame.intersects(external.frame), "\(id) shows on the external display")
        }
    }

    @Test(.enabled(if: reduceMotionIsOff))
    func aWindowSlidingToRestAcrossTheSharedEdgeEndsParkedNotHeldInPlace() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)
        let external = arrangement.displays[1]
        harness.model.navigate(.focusNext)
        await harness.settle()
        harness.model.navigate(.focusPrevious)
        await harness.settle()

        let focused = try #require(harness.windows.windows["a"]?.frame)
        for (id, window) in harness.windows.windows where !["s", "f", "a"].contains(id) {
            #expect(!window.frame.intersects(external.frame), "\(id) shows on the external display")
            let onScreen = window.frame.intersection(builtIn.visibleFrame)
            #expect(onScreen.isNull || !onScreen.intersects(focused) || harness.windows.isParked(windowID: id),
                    "\(id) was left over the focused window")
        }
    }

    @Test func withOneDisplayEveryWriteIsAPlacementOfTheFocusedSpace() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d"], focused: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        harness.model.start()
        await harness.settle()

        for action in [NavigationAction.focusNext, .focusNext, .goToSpace(index: 1), .goToSpace(index: 0),
                       .focusPrevious] {
            harness.windows.setFrameWrites.removeAll()
            harness.model.navigate(action)
            await harness.settle()
            let placements = WindowLayout.placements(for: harness.model.state.currentSpace, availableFrame: available,
                                                     tileGap: harness.model.gap, paneGap: harness.model.paneGap,
                                                     preferredHeights: harness.model.preferredHeights)
            let targets = Dictionary(placements.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
            for write in harness.windows.setFrameWrites {
                let target = try #require(targets[write.windowID], "\(write.windowID) is not in the focused space")
                #expect(write.frame.size == target.size && write.frame.minY == target.minY, "\(write.windowID)")
            }
            for placement in placements where placement.isVisible {
                #expect(harness.windows.windows[placement.windowID]?.frame == placement.frame)
            }
        }
        #expect(harness.model.otherDisplayLayouts(in: harness.model.displayArrangement).isEmpty)
        #expect(harness.model.otherDisplayFrames.isEmpty)
    }
}
