import AppKit
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// Slice M6: the model manages every display of the arrangement.
@MainActor
@Suite(.serialized)
struct MultiDisplayModelTests {
    private func external(_ arrangement: DisplayArrangement) throws -> Display {
        try #require(arrangement.displays.first { !$0.isBuiltIn })
    }

    /// The built-in display shows space 0 ("a"); the external display, to its right, shows
    /// space 1 ("b", "c"). "a" is focused.
    private func twoDisplayHarness() async throws -> (ModelHarness, DisplayArrangement) {
        let arrangement = DisplayArrangement.builtInBesideExternal
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        harness.model.displayArrangementProvider = { arrangement }
        harness.model.start()
        await harness.settle()
        let externalID = try external(arrangement).id
        func space(_ ids: [String], anchor: DisplayID? = nil) -> SpaceState {
            SpaceState(tiles: ids.map { Tile(windowID: $0, widthFraction: 0.4) }, focusedWindowID: ids.first,
                       displayAnchor: anchor)
        }
        var state = WorkspaceState(spaces: [space(["a"]), space(["b", "c"], anchor: externalID)],
                                   shownSpaceIndices: [externalID: 1])
        state.setDisplays(arrangement.ids, fallback: arrangement.fallback)
        harness.model.state = state
        harness.model.refreshWindows(forceLayout: true)
        await harness.settle()
        return (harness, arrangement)
    }

    @Test func withOneDisplayTheModelManagesTheBuiltInDisplayAlone() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let builtIn = try #require(DisplayArrangement.testBuiltIn.builtIn)
        #expect(harness.model.state.displays.ids == [builtIn.id])
        #expect(harness.model.navigationDisplays() == [
            NavigationDisplay(id: builtIn.id, number: builtIn.number, spaceIndex: 0, isFocused: true)
        ])
        let arrangements = harness.events("display_arrangement").compactMap { $0["details"] as? [String: String] }
        #expect(arrangements.count == 1 && arrangements.first?["anchored"] == "")

        harness.model.screenParametersChanged()
        await harness.settle()
        #expect(harness.events("display_arrangement").count == 1)
        #expect(harness.model.displayCheckTask == nil)
        #expect(harness.events("change_queued").last.flatMap { $0["details"] as? [String: String] }?["operation"]
            == "preferences")
    }

    @Test func keysCrossToTheNextDisplayAtTheEndOfTheRibbonButSwipesDoNot() async throws {
        let (harness, arrangement) = try await twoDisplayHarness()
        defer { harness.cleanUp() }
        let externalID = try external(arrangement).id

        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.model.state.activeSpaceIndex == 0)

        harness.model.navigateFromKeyboard(.focusNext)
        await harness.settle()
        #expect(harness.model.state.activeSpaceIndex == 1)
        #expect(harness.model.state.focusedDisplay == externalID)
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")

        harness.model.navigateFromKeyboard(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "c")

        harness.model.navigateFromKeyboard(.focusNext)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == "c")

        harness.model.navigateFromKeyboard(.focusPrevious)
        harness.model.navigateFromKeyboard(.focusPrevious)
        await harness.settle()
        #expect(harness.model.state.activeSpaceIndex == 0)
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.model.state.shownSpaceIndex(on: externalID) == 1)
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func moveSpaceToDisplayReanchorsTheSpaceAndFocusFollows() async throws {
        let (harness, arrangement) = try await twoDisplayHarness()
        defer { harness.cleanUp() }
        let externalID = try external(arrangement).id

        harness.model.navigateFromKeyboard(.moveSpaceToDisplay(direction: 1))
        await harness.settle()
        #expect(harness.model.state.spaces[0].displayAnchor == externalID)
        #expect(harness.model.state.focusedDisplay == externalID)
        #expect(harness.model.state.focusedWindowID == "a")
        let frame = try #require(harness.windows.windows["a"]?.frame)
        #expect(try external(arrangement).visibleFrame.insetBy(dx: -1, dy: -1).contains(frame))
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func aNewDisplayTakesTheLowestEmptySpaceOnceTheChangeSettles() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.displayCheckDelay = .milliseconds(60)
        harness.model.start()
        await harness.settle()
        let both = DisplayArrangement.builtInBesideExternal
        let externalID = try external(both).id

        harness.model.displayArrangementProvider = { both }
        harness.model.screenParametersChanged()
        #expect(harness.model.state.displays.ids.contains(externalID))
        #expect(harness.model.state.shownSpaceIndex(on: externalID) == nil)
        try? await Task.sleep(for: .milliseconds(150))
        await harness.settle()

        #expect(harness.model.state.shownSpaceIndex(on: externalID) == 1)
        #expect(harness.model.state.spaces[1].displayAnchor == externalID)
        let logged = harness.events("display_arrangement").last?["details"] as? [String: String]
        #expect(logged?["anchored"] == "\(externalID.logPrefix)=2")
        #expect(harness.model.state.activeSpaceIndex == 0 && harness.model.state.focusedWindowID == "a")
    }

    @Test func aDisplayBetweenTwoOthersLeavesTheBuiltInDisplayManagedAlone() async throws {
        let builtIn = ScreenDescription.testBuiltIn
        let middle = ScreenDescription.external(
            number: 2, frame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1080))
        let right = ScreenDescription.external(
            number: 3, frame: CGRect(x: builtIn.frame.maxX + 1920, y: builtIn.frame.minY, width: 1920, height: 1080))
        let arrangement = DisplayArrangement(screens: [builtIn, middle, right])
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.displayArrangementProvider = { arrangement }
        harness.model.start()
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.model.state.displays.ids == [builtIn.id])
        let refused = harness.events("display_arrangement_unsupported").last?["details"] as? [String: String]
        #expect(refused?["withoutFreeEdge"] == middle.id.logPrefix)
        #expect(harness.model.warning == nil)
        #expect(harness.overlays.warnings.isEmpty)
    }

    @Test func theBuiltInDisplayBetweenTwoOthersPausesAndStartRefuses() async throws {
        let builtIn = ScreenDescription.testBuiltIn
        let left = ScreenDescription.external(
            number: 2, frame: CGRect(x: builtIn.frame.minX - 1920, y: builtIn.frame.minY, width: 1920, height: 1080))
        let right = ScreenDescription.external(
            number: 3, frame: CGRect(x: builtIn.frame.maxX, y: builtIn.frame.minY, width: 1920, height: 1080))
        let refused = DisplayArrangement(screens: [builtIn, left, right])
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.displayArrangementProvider = { refused }
        harness.model.screenParametersChanged()
        #expect(!harness.model.isRunning)
        #expect((harness.events("paused").last?["details"] as? [String: String])?["reason"]
            == "display_arrangement_unsupported")
        #expect(harness.events("automatic_pause").isEmpty)

        harness.model.start()
        #expect(!harness.model.isRunning)
        #expect((harness.events("start_failed").last?["details"] as? [String: String])?["reason"]
            == "display_arrangement_unsupported")

        harness.model.displayArrangementProvider = { .testBuiltIn }
        harness.model.start()
        await harness.settle()
        #expect(harness.model.isRunning)
    }

    @Test func theAppBarListsEachDisplaysSpaceAndActsInIt() async throws {
        let (harness, arrangement) = try await twoDisplayHarness()
        defer { harness.cleanUp() }
        let externalID = try external(arrangement).id
        let displays = harness.model.navigationDisplays()
        #expect(displays.map(\.spaceIndex) == [0, 1])
        #expect(displays.map(\.isFocused) == [true, false])

        let other = NavigationHUDContent(state: harness.model.state, otherSpaceIndex: 1, display: externalID)
        #expect(other.space.windowIDs == ["b", "c"] && other.availableSpaceIndices == [1])
        let focused = NavigationHUDContent(state: harness.model.state, otherSpaceIndex: nil, display: nil)
        #expect(focused.space.windowIDs == ["a"] && focused.availableSpaceIndices == [0])

        harness.overlays.onFocusWindow?("c", 1)
        await harness.settle()
        #expect(harness.model.state.activeSpaceIndex == 1 && harness.model.state.focusedWindowID == "c")
        #expect(harness.model.state.focusedDisplay == externalID)
    }
}
