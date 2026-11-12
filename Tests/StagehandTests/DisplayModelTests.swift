import AppKit
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// The built-in display's visible frame flipped against the menu-bar display, as
/// `availableFrame` read it from `builtInScreenProvider` before the arrangement.
private func screenProviderAvailableFrame(_ screens: [ScreenDescription]) -> CGRect? {
    guard let builtIn = screens.first(where: \.isBuiltIn), let primary = screens.first else { return nil }
    let frame = builtIn.visibleFrame
    return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
}

@MainActor
private func builtInBesideExternal(builtInScale: CGFloat = 3) -> [ScreenDescription] {
    let size = ScreenDescription.testBuiltIn
    let external = ScreenDescription.external(number: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                              visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
    let inset = CGRect(x: size.visibleFrame.minX - size.frame.minX, y: size.visibleFrame.minY - size.frame.minY,
                       width: size.visibleFrame.width, height: size.visibleFrame.height)
    let builtIn = ScreenDescription(
        id: size.id, number: 1,
        frame: CGRect(x: 2560, y: 120, width: size.frame.width, height: size.frame.height),
        visibleFrame: inset.offsetBy(dx: 2560, dy: 120),
        isBuiltIn: true, backingScaleFactor: builtInScale, maximumFramesPerSecond: 120)
    return [external, builtIn]
}

private var reduceMotionIsOff: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

@MainActor
@Suite(.serialized)
struct DisplayModelTests {
    @Test func theAvailableFrameIsTheBuiltInVisibleFrameAsTheScreenProviderGaveIt() {
        let harness = ModelHarness(windowIDs: ["a"], focused: "a")
        defer { harness.cleanUp() }
        let below = ScreenDescription(
            id: ScreenDescription.testBuiltIn.id, number: 1,
            frame: CGRect(x: -300, y: -982, width: 1512, height: 982),
            visibleFrame: CGRect(x: -300, y: -912, width: 1512, height: 880),
            isBuiltIn: true, backingScaleFactor: 2, maximumFramesPerSecond: 120)
        let primary = ScreenDescription.external(number: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                 visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let cases: [[ScreenDescription]] = [
            [.testBuiltIn], builtInBesideExternal(), [primary, below],
            [.external(number: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))],
            []
        ]
        for screens in cases {
            harness.model.displayArrangementProvider = { DisplayArrangement(screens: screens) }
            #expect(harness.model.availableFrame == screenProviderAvailableFrame(screens))
            #expect(harness.model.focusedDisplay?.number == screens.first(where: \.isBuiltIn)?.number)
        }
    }

    /// Until the model sets its displays, an external display is never managed (070bfa8),
    /// even though it is the arrangement's fallback once the lid is closed.
    @Test func withoutABuiltInDisplayNothingIsLaidOut() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.displayArrangementProvider = { .externalOnly }

        #expect(DisplayArrangement.externalOnly.fallback != nil)
        #expect(harness.model.availableFrame == nil)
        harness.model.start()
        #expect(!harness.model.isRunning)
    }

    @Test func navigationLaysOutOnTheBuiltInDisplayAndMovesAtItsScale() async throws {
        let screens = builtInBesideExternal(builtInScale: 3)
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.displayArrangementProvider = { DisplayArrangement(screens: screens) }
        let available = try #require(screenProviderAvailableFrame(screens))

        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "b")
        let focused = try #require(harness.windows.windows["b"]?.frame)
        #expect(available.insetBy(dx: -1, dy: -1).contains(focused))
        #expect(harness.model.motionBackingScaleFactor == 3)
        if reduceMotionIsOff {
            #expect(!harness.frameDriver.displays.isEmpty)
            #expect(harness.frameDriver.displays.allSatisfy { $0 == 1 })
        }
    }

    @Test(.enabled(if: reduceMotionIsOff))
    func aSwipeFollowsTheBuiltInDisplaysLinkAndScale() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.displayArrangementProvider = { DisplayArrangement(screens: builtInBesideExternal(builtInScale: 3)) }
        harness.model.start()
        await harness.settle()
        harness.model.motionBackingScaleFactor = 1

        harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
        harness.model.handleGesture(.changed(displacement: -0.05, velocity: -0.5))

        #expect(harness.model.motionBackingScaleFactor == 3)
        #expect(harness.frameDriver.displays.last == 1)
        harness.model.handleGesture(.cancelled)
        await harness.settle()
    }
}
