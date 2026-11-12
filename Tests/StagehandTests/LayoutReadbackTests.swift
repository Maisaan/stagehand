import AppKit
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// The frame reads after a layout's focus or motion go to the app that was just
/// activated, while it is busiest; on the main thread each waited up to the 100 ms
/// messaging timeout and delayed typing, gestures and ribbon frames in every app
/// (busy benchmarks, 2026-11-13).
@MainActor
@Suite(.serialized)
struct LayoutReadbackTests {
    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func endings(_ harness: ModelHarness, operation: String) -> [[String: String]] {
        harness.events("change_ended").compactMap { $0["details"] as? [String: String] }
            .filter { $0["operation"] == operation }
    }

    /// "a" alone on the second space, refusing widths below the returned minimum, so
    /// the readback after focus finds a constraint to learn.
    private func harnessWithASpaceToSwitchTo() async throws -> (ModelHarness, minimumWidth: CGFloat) {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.moveToSpace(index: 1, follow: false))
        await harness.settle()
        let minimumWidth = (try #require(harness.model.availableFrame).width * 0.9).rounded()
        harness.windows.minimumSizes = ["a": CGSize(width: minimumWidth, height: 1)]
        return (harness, minimumWidth)
    }

    @Test func aSlowFrameReadAfterFocusLeavesTheMainThreadFree() async throws {
        let (harness, wide) = try await harnessWithASpaceToSwitchTo()
        defer { harness.cleanUp() }
        #expect(harness.model.learnedMinimumWidths["a"] == nil)
        harness.windows.holdsFrameReadsOffMain = true

        harness.model.navigate(.nextSpace)
        await waitFor { harness.windows.heldFrameReadCount > 0 }

        #expect(harness.windows.heldFrameReadCount == 1)
        #expect(harness.windows.frameReadsOffMain.last == ["a"])
        #expect(harness.windows.focused == "a")
        let otherWorkRan = await Task { @MainActor in true }.value
        #expect(otherWorkRan)
        #expect(harness.model.changes.isProcessing)

        harness.windows.holdsFrameReadsOffMain = false
        harness.windows.releaseHeldFrameReads()
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.events("automatic_pause").isEmpty)
        #expect(harness.model.state.activeSpaceIndex == 1)
        #expect(harness.model.learnedMinimumWidths["a"] == wide)
        #expect(harness.overlays.borderVisibility.last == true)
        #expect(endings(harness, operation: "action.nextSpace").isEmpty)
    }

    enum Interruption: CaseIterable {
        case pause, desktopChange
    }

    @Test(arguments: Interruption.allCases)
    func anInterruptionDuringTheReadAfterFocusEndsTheSwitchWithoutApplyingIt(_ interruption: Interruption) async throws {
        let (harness, wide) = try await harnessWithASpaceToSwitchTo()
        defer { harness.cleanUp() }
        harness.windows.holdsFrameReadsOffMain = true

        harness.model.navigate(.nextSpace)
        await waitFor { harness.windows.heldFrameReadCount > 0 }
        #expect(harness.windows.heldFrameReadCount == 1)
        switch interruption {
        case .pause:
            harness.model.pause()
        case .desktopChange:
            harness.desktop.id = nil
            harness.model.nativeDesktopChanged()
        }
        let readsBeforeRelease = harness.windows.frameReadsOffMain.count
        let writesBeforeRelease = harness.windows.setFrameCalls.count
        let borderBeforeRelease = harness.overlays.borderVisibility

        harness.windows.holdsFrameReadsOffMain = false
        harness.windows.releaseHeldFrameReads()
        await harness.settle()

        let ended = endings(harness, operation: "action.nextSpace")
        #expect(ended.map { $0["outcome"] } == ["interrupted"])
        #expect(harness.model.learnedMinimumWidths["a"] == nil)
        #expect(harness.windows.frameReadsOffMain.count == readsBeforeRelease)
        #expect(harness.windows.setFrameCalls.count == writesBeforeRelease)
        #expect(harness.overlays.borderVisibility == borderBeforeRelease)
        #expect(harness.events("layout_failed").isEmpty)
    }

    @Test func aPauseDuringTheReadAfterMotionEndsTheSwitchWithoutCorrectingOrBordering() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.holdsFrameReadsOffMain = true

        harness.model.navigate(.focusNext)
        await waitFor { harness.windows.heldFrameReadCount > 0 }
        #expect(harness.windows.frameReadsOffMain.last == ["b"])
        #expect(harness.windows.focused == "b")
        #expect(harness.events("ribbon_animation_completed").count == 1)
        harness.model.pause()
        let writesBeforeRelease = harness.windows.setFrameCalls.count
        let borderBeforeRelease = harness.overlays.borderVisibility

        harness.windows.holdsFrameReadsOffMain = false
        harness.windows.releaseHeldFrameReads()
        await harness.settle()

        #expect(endings(harness, operation: "action.focusNext").map { $0["outcome"] } == ["interrupted"])
        #expect(harness.windows.setFrameCalls.count == writesBeforeRelease)
        #expect(harness.overlays.borderVisibility == borderBeforeRelease)
    }
}
