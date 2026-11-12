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

private func display(_ number: CGDirectDisplayID, x: CGFloat, width: CGFloat = 1000) -> Display {
    Display(id: DisplayID(rawValue: "D\(number)"), number: number,
            frame: CGRect(x: x, y: 0, width: width, height: 800),
            visibleFrame: CGRect(x: x, y: 25, width: width, height: 775),
            isBuiltIn: number == 1, backingScaleFactor: 2, maximumFramesPerSecond: 60)
}

// MARK: - Pure rules

@Test func theFreeSideIsUsedOnlyWhenOneEdgeIsShared() {
    for preferred in [WindowParkingSide.left, .right, nil] {
        #expect(freeParkingSide(preferred: preferred, sharedEdges: []) == preferred)
        #expect(freeParkingSide(preferred: preferred, sharedEdges: [.right]) == .left)
        #expect(freeParkingSide(preferred: preferred, sharedEdges: [.left]) == .right)
        #expect(freeParkingSide(preferred: preferred, sharedEdges: [.left, .right]) == preferred)
    }
}

@Test func aWindowParksOnTheDisplayItIsOnOnlyWhenOneOfItsSpacesIsThere() {
    let left = display(1, x: 0)
    let right = display(2, x: 1000)
    let third = display(3, x: 2000)
    let onRight = CGRect(x: 1200, y: 100, width: 400, height: 300)
    let onThird = CGRect(x: 2200, y: 100, width: 400, height: 300)

    #expect(displayToParkOn(candidates: [left], displays: [left, right], currentFrame: onRight) == left)
    #expect(displayToParkOn(candidates: [left, right], displays: [left, right], currentFrame: onRight) == right)
    #expect(displayToParkOn(candidates: [left, right], displays: [left, right, third], currentFrame: onThird) == left)
    #expect(displayToParkOn(candidates: [right, left], displays: [left, right], currentFrame: nil) == right)
    #expect(displayToParkOn(candidates: [], displays: [left], currentFrame: onRight) == nil)
}

@Test func aSlideWithoutASharedEdgeIsUnchanged() {
    let from = ["a": CGRect(x: -900, y: 0, width: 800, height: 600), "b": CGRect(x: 100, y: 0, width: 800, height: 600)]
    let to = ["a": CGRect(x: 100, y: 0, width: 800, height: 600), "b": CGRect(x: 1100, y: 0, width: 800, height: 600)]
    let slide = sharedEdgeSafeSlide(from: from, to: to, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                    sharedEdges: [])
    #expect(slide == SharedEdgeSlide(from: from, to: to, snappedWindowIDs: []))
}

@Test func aSlideAcrossASharedEdgeEntersAtItsTargetAndLeavesFromItsPlace() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let leaving = (from: CGRect(x: 100, y: 0, width: 800, height: 600), to: CGRect(x: 1100, y: 0, width: 800, height: 600))
    let entering = (from: CGRect(x: 1100, y: 0, width: 800, height: 600), to: CGRect(x: 100, y: 0, width: 800, height: 600))
    let freeSide = (from: CGRect(x: 100, y: 0, width: 800, height: 600), to: CGRect(x: -900, y: 0, width: 800, height: 600))
    let resting = CGRect(x: 1100, y: 0, width: 800, height: 600)
    let slide = sharedEdgeSafeSlide(
        from: ["leaving": leaving.from, "entering": entering.from, "free": freeSide.from, "resting": resting],
        to: ["leaving": leaving.to, "entering": entering.to, "free": freeSide.to, "resting": resting],
        displayFrame: screen, sharedEdges: [.right])

    #expect(slide.snappedWindowIDs == ["leaving", "entering"])
    #expect(slide.from["leaving"] == leaving.from && slide.to["leaving"] == leaving.from)
    #expect(slide.from["entering"] == entering.to && slide.to["entering"] == entering.to)
    #expect(slide.from["free"] == freeSide.from && slide.to["free"] == freeSide.to)
    #expect(slide.from["resting"] == resting && slide.to["resting"] == resting)
}

// MARK: - The model

@MainActor
@Suite(.serialized)
struct ParkingPerDisplayTests {
    @Test func withOneDisplayEveryWindowParksInsideItsVisibleFrameOnItsLayoutSide() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d"], focused: "a")
        defer { harness.cleanUp() }
        let available = try #require(harness.model.availableFrame)
        harness.model.start()
        await harness.settle()

        for action in [NavigationAction.focusNext, .focusNext, .focusNext, .focusPrevious, .focusPrevious] {
            harness.windows.parkRequests.removeAll()
            harness.model.navigate(action)
            await harness.settle()
            let placements = WindowLayout.placements(for: harness.model.state.currentSpace, availableFrame: available,
                                                     tileGap: harness.model.gap, paneGap: harness.model.paneGap)
            let hidden = Set(placements.filter { !$0.isVisible }.map(\.windowID))
            #expect(!harness.windows.parkRequests.isEmpty)
            #expect(Set(harness.windows.parkRequests.map(\.windowID)).isSubset(of: hidden))
            #expect(harness.windows.parkRequests.allSatisfy { $0.bounds == available })
            for request in harness.windows.parkRequests where request.side != nil {
                let frame = try #require(placements.first { $0.windowID == request.windowID }?.frame)
                #expect(request.side == preferredParkingSide(for: frame, relativeTo: available))
            }
        }
        #expect(harness.events("shared_edge_motion_snapped").isEmpty)
    }

    /// Space 0 (focused) and space 2 are on the built-in display, spaces 1 and 3 on the
    /// external display to its right, which shows space 1.
    private func twoDisplayHarness() async -> (ModelHarness, DisplayArrangement) {
        let arrangement = builtInWithExternalOnTheRight()
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d", "e", "f"], focused: "a")
        harness.model.displayArrangementProvider = { arrangement }
        harness.model.start()
        await harness.settle()
        let external = arrangement.displays[1].id
        func space(_ ids: [String], anchor: DisplayID? = nil) -> SpaceState {
            let base = SpaceState(windowIDs: ids)
            return SpaceState(tiles: base.tiles, focusedWindowID: base.focusedWindowID, displayAnchor: anchor)
        }
        var state = WorkspaceState(spaces: [space(["a", "b", "c"]), space(["d"], anchor: external),
                                            space(["e"]), space(["f"], anchor: external)])
        state.setDisplays(arrangement.ids, fallback: arrangement.fallback)
        harness.model.state = state
        return (harness, arrangement)
    }

    @Test func eachWindowParksOnItsSpacesDisplayAtTheFreeEdgeAndShownWindowsStay() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)
        let external = arrangement.displays[1]
        #expect(harness.model.state.shownSpaceIndex(on: external.id) == 1)
        #expect(harness.model.windowsShownOnOtherDisplays(in: arrangement) == ["d"])

        harness.windows.parkRequests.removeAll()
        harness.model.navigate(.focusNext)
        await harness.settle()

        let requests = harness.windows.parkRequests
        #expect(!requests.contains { $0.windowID == "d" })
        #expect(requests.contains { $0.windowID == "e" })
        #expect(requests.contains { $0.windowID == "f" })
        for request in requests {
            let expected = request.windowID == "f" ? external : builtIn
            #expect(request.bounds == expected.visibleFrame, "\(request.windowID)")
            #expect(request.side == (request.windowID == "f" ? .right : .left), "\(request.windowID)")
        }
        for (id, window) in harness.windows.windows where id != "d" && harness.windows.isParked(windowID: id) {
            #expect(!window.frame.intersects(external.frame) || id == "f", "\(id) parked onto the external display")
        }
    }

    @Test(.enabled(if: reduceMotionIsOff))
    func aSlideAcrossTheSharedEdgeSnapsThoseWindowsAndLogs() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)
        harness.model.navigate(.focusNext)
        await harness.settle()
        harness.windows.motionFrames.removeAll()

        harness.model.navigate(.focusNext)
        await harness.settle()
        harness.model.navigate(.focusPrevious)
        await harness.settle()
        harness.model.navigate(.focusPrevious)
        await harness.settle()

        #expect(!harness.events("shared_edge_motion_snapped").isEmpty)
        for (id, frames) in harness.windows.motionFrames {
            #expect(frames.allSatisfy { $0.maxX <= builtIn.frame.maxX + 1 }, "\(id) slid onto the external display")
        }
    }

    @Test(.enabled(if: reduceMotionIsOff))
    func aSwipePreviewHoldsWindowsBackFromTheSharedEdge() async throws {
        let (harness, arrangement) = await twoDisplayHarness()
        defer { harness.cleanUp() }
        let builtIn = try #require(arrangement.builtIn)

        harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
        for displacement in [-0.1, -0.3, -0.6] {
            harness.model.handleGesture(.changed(displacement: displacement, velocity: -0.5))
            let base = try #require(harness.model.gestureBase)
            let preview = harness.model.gesturePreviewFrames(
                from: base, on: builtIn, sharedEdges: arrangement.sharedEdges(of: builtIn.id),
                displacement: displacement)
            for (id, frame) in preview where frame != base[id] {
                #expect(frame.maxX <= builtIn.frame.maxX + 1, "\(id) previewed onto the external display")
            }
        }
        harness.model.handleGesture(.cancelled)
        await harness.settle()
    }
}
