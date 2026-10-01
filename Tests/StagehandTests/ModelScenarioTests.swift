import AppKit
import Testing
import StagehandCore
@testable import Stagehand
@testable import StagehandPlatform

/// End-to-end model behavior against in-memory windows. Each test names the
/// production failure it guards. Real Accessibility behavior still needs the
/// live checks in docs/ACCEPTANCE.md.
@MainActor
@Suite(.serialized)
struct ModelScenarioTests {
    @Test func navigationMovesFocusAndParksTheRibbonsHiddenWindows() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focusedWindowID() == "b")
        #expect(harness.events("automatic_pause").isEmpty)
    }

    /// 2026-10-01T01:53:56Z: a parked window was minimized without an AX
    /// notification, and navigating onto it paused Stagehand.
    @Test func navigatingOntoASilentlyMinimizedWindowDropsItInsteadOfPausing() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let order = harness.model.state.currentSpace.windowIDs
        let target = order[(order.firstIndex(of: "a")! + 1) % order.count]
        harness.windows.minimizeSilently(target)

        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.events("automatic_pause").isEmpty)
        #expect(!harness.model.state.currentSpace.windowIDs.contains(target))
        #expect(harness.model.state.focusedWindowID == harness.windows.focusedWindowID())
        #expect(harness.events("window_unavailable_detected").count == 1)
        #expect(harness.overlays.warnings.isEmpty)

        // Restoring it returns the window to its membership.
        harness.windows.restoreFromDock(target)
        await harness.settle()
        #expect(harness.model.state.currentSpace.windowIDs == order)
    }

    /// The dangerous opposite: a live window that refuses focus must still pause
    /// and restore every window, rather than being skipped.
    @Test func aLiveWindowThatRefusesFocusStillPausesAndRestoresFrames() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        let originals = harness.windows.windows.mapValues(\.original)
        harness.model.start()
        await harness.settle()
        harness.windows.refusesFocus = ["b"]

        harness.model.navigate(.focusNext)
        // Stop at the pause; the automatic resume retries 100 ms later.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while harness.events("automatic_pause").isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        let pause = harness.events("automatic_pause").first?["details"] as? [String: String]
        #expect(pause?["reason"] == "focus_confirmation_failed")
        #expect(harness.events("window_unavailable_detected").isEmpty)
        #expect(harness.windows.windows.mapValues(\.frame) == originals)
        #expect(harness.overlays.warnings.contains { $0.contains("paused and restored") })
    }

    /// Navigating to another space parks every window of the old one. A window
    /// minimized without notification used to exhaust parking retries and pause.
    @Test func parkingASilentlyMinimizedWindowDropsItInsteadOfPausing() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.moveToSpace(index: 1, follow: false))
        await harness.settle()
        let remaining = harness.model.state.currentSpace.windowIDs
        harness.windows.minimizeSilently(remaining.last!)

        harness.model.navigate(.nextSpace)
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.events("automatic_pause").isEmpty)
        #expect(harness.model.state.activeSpaceIndex == 1)
        #expect(harness.model.state.focusedWindowID == "a")
    }

    @Test func closingTheFocusedWindowFocusesTheMostRecentSurvivor() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        let closing = harness.model.state.focusedWindowID!
        let previous = harness.model.state.currentSpace.windowIDs.first { $0 != closing && $0 != "a" } ?? "a"

        harness.windows.close(closing)
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(!harness.model.state.currentSpace.windowIDs.contains(closing))
        #expect(harness.model.state.focusedWindowID == previous)
        #expect(harness.windows.focusedWindowID() == previous)
    }

    /// Typing during a switch is held and delivered only to the verified destination.
    @Test func bufferedTypingIsDeliveredAfterVerifiedFocus() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusNext)
        let keyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(harness.model.focusGate.processKeyboardEvent(type: .keyDown, event: keyDown))
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.postedEvents() == 1)
    }

    /// A pause during an interrupted switch resumes the layout from before it.
    @Test func pauseAndResumeRestoresTheLayoutAndOmitsClosedWindows() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.shareToSpace(index: 2))
        await harness.settle()
        let layout = harness.model.state

        harness.model.pause()
        harness.windows.close("c")
        harness.model.start()
        await harness.settle()

        #expect(harness.model.state.spaces[2].windowIDs == layout.spaces[2].windowIDs.filter { $0 != "c" })
        #expect(harness.model.state.spaces[0].windowIDs == layout.spaces[0].windowIDs.filter { $0 != "c" })
    }
}
