import AppKit
import Carbon
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

    /// Quitting and relaunching Stagehand while apps keep running must return
    /// windows to their spaces and order.
    @Test func relaunchRestoresTheSavedLayoutOfStillRunningWindows() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagehand-layout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let launchDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let store = WorkspaceLayoutStore(url: url, launchDate: { _ in launchDate })

        let first = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", layoutStore: store)
        first.model.start()
        await first.settle()
        first.model.navigate(.reorderNext)
        await first.settle()
        first.model.navigate(.shareToSpace(index: 2))
        await first.settle()
        first.model.shutDown()
        let saved = first.model.state
        first.cleanUp()
        #expect(saved.spaces[0].windowIDs == ["b", "a", "c"])
        #expect(saved.spaces[2].windowIDs == ["a"])

        let second = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", layoutStore: store)
        defer { second.cleanUp() }
        second.model.start()
        await second.settle()
        #expect(second.model.state.spaces.map(\.windowIDs) == saved.spaces.map(\.windowIDs))
        #expect(second.events("layout_restored").count == 1)

        let relaunchedApps = ModelHarness(
            windowIDs: ["a", "b", "c"], focused: "a",
            layoutStore: WorkspaceLayoutStore(url: url, launchDate: { _ in launchDate.addingTimeInterval(1) })
        )
        defer { relaunchedApps.cleanUp() }
        relaunchedApps.model.start()
        await relaunchedApps.settle()
        #expect(relaunchedApps.events("layout_restored").isEmpty)
        #expect(relaunchedApps.model.state.spaces[2].windowIDs.isEmpty)
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

    /// Five windows, the second focused: a window reopened from the Dock or a
    /// newly opened app joins third and takes focus, instead of its old slot.
    @Test(arguments: ["notification", "scanBeforeFocus", "scanAfterFocus"])
    func aWindowRestoredFromTheDockJoinsAfterTheFocusedWindow(path: String) async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d", "e"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        let order = harness.model.state.currentSpace.windowIDs
        let focused = order[1]
        #expect(harness.model.state.focusedWindowID == focused)
        let restored = order[4]
        harness.windows.minimize(restored)
        await harness.settle()
        #expect(harness.model.state.focusedWindowID == focused)

        harness.windows.restoreFromDock(restored, notify: path == "notification",
                                        focus: path != "scanBeforeFocus")
        await harness.settle()

        #expect(harness.model.state.currentSpace.windowIDs == [order[0], focused, restored, order[2], order[3]])
        #expect(harness.model.state.focusedWindowID == restored)
        #expect(harness.windows.focusedWindowID() == restored)
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test(arguments: [true, false])
    func aNewlyOpenedAppJoinsAfterTheFocusedWindow(focusedAtScan: Bool) async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c", "d", "e"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        let order = harness.model.state.currentSpace.windowIDs

        harness.windows.addWindow("new", pid: 300, frame: CGRect(x: 80, y: 60, width: 700, height: 500))
        if focusedAtScan { harness.windows.setFocus("new") }
        harness.windows.onChange?()
        await harness.settle()
        if !focusedAtScan {
            // The app activates after its window was discovered.
            harness.windows.setFocus("new")
            harness.windows.onFocusedWindowChange?("new")
            await harness.settle()
        }

        #expect(harness.model.state.currentSpace.windowIDs == [order[0], order[1], "new"] + order[2...])
        #expect(harness.model.state.focusedWindowID == "new")
        #expect(harness.windows.focusedWindowID() == "new")
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

    /// Background scans are discarded when windows changed during the read. The
    /// refresh must try again rather than miss a newly opened window.
    @Test func aStaleBackgroundScanIsRetriedSoNewWindowsStillJoin() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let scansBefore = harness.windows.offMainScans

        harness.windows.addWindow("new", pid: 300, frame: CGRect(x: 80, y: 60, width: 700, height: 500))
        harness.windows.staleScansRemaining = 1
        harness.windows.onChange?()
        await harness.settle()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !harness.model.state.currentSpace.windowIDs.contains("new"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.windows.offMainScans - scansBefore >= 2)
        #expect(harness.model.state.currentSpace.windowIDs.contains("new"))
        #expect(harness.events("automatic_pause").isEmpty)
    }

    /// Typing during a switch is held and delivered only to the verified destination.
    @Test(.enabled(if: !IsSecureEventInputEnabled(), "Secure Input is on, so the focus gate holds no transfers"))
    func bufferedTypingIsDeliveredAfterVerifiedFocus() async throws {
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

    /// Windows that keep changing under the background reader used to restart
    /// the 100 ms cycle forever. After a few stale reads one synchronous scan
    /// completes the refresh.
    @Test func repeatedStaleScansFallBackToASynchronousScan() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let scansBefore = harness.windows.offMainScans

        harness.windows.addWindow("new", pid: 300, frame: CGRect(x: 80, y: 60, width: 700, height: 500))
        harness.windows.staleScansRemaining = harness.model.refreshStaleScanFallback
        harness.windows.onChange?()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !harness.model.state.currentSpace.windowIDs.contains("new"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await harness.settle()

        #expect(harness.model.state.currentSpace.windowIDs.contains("new"))
        #expect(harness.windows.offMainScans - scansBefore >= harness.model.refreshStaleScanFallback)
        #expect(harness.events("refresh_scan_fallback").count == 1)
        #expect(harness.events("refresh_starved").isEmpty)
        #expect(harness.events("automatic_pause").isEmpty)
    }

    @Test func aRefreshThatStaysBlockedLogsStarvationAndStopsPolling() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.refreshRetryLimit = 3
        let scansBefore = harness.windows.offMainScans

        // A gesture in progress blocks every refresh attempt.
        harness.model.gestureBase = [:]
        harness.windows.onChange?()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while harness.events("refresh_starved").isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(250))

        let starved = harness.events("refresh_starved")
        #expect(starved.count == 1)
        #expect((starved.first?["details"] as? [String: String])?["attempts"] == "3")
        #expect((starved.first?["details"] as? [String: String])?["gestureActive"] == "true")
        #expect(harness.windows.offMainScans == scansBefore)
        #expect(harness.model.isRunning)
        harness.model.gestureBase = nil
    }

    /// README: after an automatic pause Stagehand tries to resume once after
    /// 100 ms. The retry must happen exactly once and clear the warning when
    /// it succeeds.
    @Test func anAutomaticPauseResumesOnceAndClearsTheWarning() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.refusesFocus = ["b"]

        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(harness.model.isRunning)
        #expect(harness.events("automatic_pause").count == 1)
        #expect(harness.events("automatic_resume_attempt").count == 1)
        #expect(harness.events("automatic_resume_succeeded").count == 1)
        #expect(harness.events("automatic_resume_failed").isEmpty)
        #expect(harness.model.warning == nil)
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.model.automaticResumeTask == nil)
    }

    /// If the resume fails too, Stagehand stays paused with frames restored and
    /// tells the user to press Start; it must not keep retrying.
    @Test func aSecondFailureStaysPausedWithARetryWarning() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        let originals = harness.windows.windows.mapValues(\.original)
        harness.model.start()
        await harness.settle()
        harness.windows.refusesFocus = ["a", "b"]
        harness.windows.setFocus("elsewhere")

        harness.model.navigate(.focusNext)
        await harness.settle()
        try? await Task.sleep(for: .milliseconds(300))

        #expect(!harness.model.isRunning)
        #expect(harness.events("automatic_pause").count == 2)
        #expect(harness.events("automatic_resume_attempt").count == 1)
        #expect(harness.events("automatic_resume_succeeded").isEmpty)
        #expect(harness.model.warning?.hasSuffix("Press Start to retry.") == true)
        #expect(harness.overlays.warnings.last?.hasSuffix("Press Start to retry.") == true)
        #expect(harness.windows.windows.mapValues(\.frame) == originals)

        // A manual Start resets the single-retry budget.
        harness.windows.refusesFocus = []
        harness.windows.setFocus("a")
        harness.model.start()
        await harness.settle()
        #expect(harness.model.isRunning)
        #expect(harness.model.warning == nil)
    }

    /// Typing captured for a switch is held for a bounded time. A destination
    /// that stays busy past that deadline pauses with input_transfer_expired
    /// rather than delivering the keys late or to the wrong window.
    @Test(.enabled(if: !IsSecureEventInputEnabled(), "Secure Input is on, so the focus gate holds no transfers"))
    func anExpiredInputTransferPausesAndRestoresFrames() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a", transferTimeoutMilliseconds: 40)
        defer { harness.cleanUp() }
        let originals = harness.windows.windows.mapValues(\.original)
        harness.model.start()
        await harness.settle()
        harness.windows.focusDelayMilliseconds = 300

        harness.model.navigate(.focusNext)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while harness.events("automatic_pause").isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await harness.settle()

        let pause = harness.events("automatic_pause").first?["details"] as? [String: String]
        #expect(pause?["reason"] == "input_transfer_expired")
        #expect(pause?["token"] != nil)
        #expect(harness.overlays.warnings.contains { $0.contains("couldn't finish switching windows") })
        #expect(harness.windows.windows.mapValues(\.frame) == originals)
        #expect(harness.model.focusGate.isAvailable)
    }

    /// While WindowServer reports no Desktop (lock screen), the model rechecks
    /// every 500 ms. That must not continue indefinitely.
    @Test func anUnknownDesktopIsRecheckedQuicklyThenBacksOff() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.desktop.id = nil
        harness.model.nativeDesktopChanged()
        #expect(harness.model.isSuspended)
        #expect(harness.model.desktopCheckAttempts == 1)
        #expect(harness.model.desktopCheckDelay == .milliseconds(500))

        // Drive the recheck chain without waiting on the real timers.
        for _ in 0..<StagehandModel.quickDesktopChecks {
            harness.model.nativeDesktopChanged()
        }
        #expect(harness.model.desktopCheckAttempts == StagehandModel.quickDesktopChecks + 1)
        #expect(harness.model.desktopCheckDelay == .seconds(5))
        #expect(harness.events("desktop_check_backoff").count == 1)
        #expect(harness.model.isSuspended)

        harness.desktop.id = 1
        harness.model.nativeDesktopChanged()
        await harness.settle()
        #expect(!harness.model.isSuspended)
        #expect(harness.model.desktopCheckAttempts == 0)
        #expect(harness.events("desktop_resumed").count == 1)
    }
}
