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

    /// A swipe preview retried a refused first move on every display tick. For a closing
    /// window, or one whose app is not answering, each try is a main-thread round trip.
    /// A refusal that can still be read keeps its per-tick retry.
    @Test func aSwipePreviewStopsRetryingAWindowItCannotRead() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let available = try #require(harness.model.availableFrame)
        let base = harness.model.navigationFrames()
        let preview = { (displacement: Double) in
            _ = harness.model.gesturePreviewFrames(from: base, availableFrame: available,
                                                   displacement: displacement)
        }
        func writes(to id: String) -> Int { harness.windows.setFrameCalls.filter { $0 == id }.count }

        harness.model.gestureBase = base
        harness.model.gesturePrepared = ["a"]
        harness.windows.refusesFrames = ["b"]
        harness.windows.unreadableFrames = ["b"]
        let startup = writes(to: "b")
        for displacement in [-0.05, -0.06, -0.07] { preview(displacement) }
        #expect(writes(to: "b") - startup == 1)

        harness.model.resetGestureTracking()
        harness.model.gestureBase = base
        harness.model.gesturePrepared = ["a"]
        harness.windows.unreadableFrames = []
        let before = writes(to: "b")
        for displacement in [-0.05, -0.06, -0.07] { preview(displacement) }
        #expect(writes(to: "b") - before == 3)
        harness.model.resetGestureTracking()
    }

    /// Every frame read is a synchronous round trip to an app, on the main thread.
    /// A slide starts from the frames Stagehand wrote or scanned and reads a frame
    /// back only once, after activation, when the app may have resized its window.
    @Test func aSlideStartsFromKnownFramesWithoutReadingThem() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.resetReadCounts()

        harness.model.navigate(.focusNext)
        await harness.settle()

        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.frameReads == 1)
        // The destination's app was not frontmost, so no focus read preceded
        // activation; the refresh after the switch reads focus once.
        #expect(harness.windows.focusReads == 1)
        #expect(harness.events("ribbon_animation_completed").count == 1)
        #expect(harness.events("ribbon_position_commit_failed").isEmpty)
    }

    /// The preset shortcut steps through the presets saved in settings, and a listed
    /// app's windows are parked with the wider allowance while others keep the default.
    @Test func widthPresetsAndParkedEdgeAllowanceComeFromSettings() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        let savedPresets = harness.model.widthPresets
        let savedApps = harness.model.wideParkedEdgeBundleIdentifiers
        let savedWidth = harness.model.wideParkedEdgeWidth
        defer {
            harness.model.widthPresets = savedPresets
            harness.model.wideParkedEdgeBundleIdentifiers = savedApps
            harness.model.wideParkedEdgeWidth = savedWidth
        }
        harness.model.widthPresets = [1.0, 0.4, .nan, 0.4]
        harness.model.wideParkedEdgeBundleIdentifiers = ["test.app101", "", "test.app101"]
        harness.model.wideParkedEdgeWidth = 1_000
        #expect(harness.model.widthPresets == [0.4, 1.0])
        #expect(harness.model.wideParkedEdgeBundleIdentifiers == ["test.app101"])
        #expect(harness.model.wideParkedEdgeWidth == Double(WindowTuning.maximumParkedRemnantWidth))
        harness.model.start()
        await harness.settle()
        // The harness windows open at 60% of the available width.
        #expect(harness.model.state.currentSpace.widthFraction(for: "a") == 0.6)

        harness.model.navigate(.nextWidthPreset)
        await harness.settle()
        #expect(harness.model.state.currentSpace.widthFraction(for: "a") == 1)
        // A full-width window hides both neighbors. b belongs to the listed app.
        #expect(harness.windows.parkRemnantWidths["b"] == WindowTuning.maximumParkedRemnantWidth)
        #expect(harness.windows.parkRemnantWidths["c"] == WindowTuning.parkedRemnantWidth)

        harness.model.navigate(.nextWidthPreset)
        await harness.settle()
        #expect(harness.model.state.currentSpace.widthFraction(for: "a") == 0.4)
        harness.model.navigate(.previousWidthPreset)
        await harness.settle()
        #expect(harness.model.state.currentSpace.widthFraction(for: "a") == 1)
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

    /// Pausing returns windows to their frames from before Stagehand. Resuming
    /// must lay them out at the heights chosen while Stagehand ran, as it does
    /// for widths, not at those older heights.
    @Test func resumingKeepsTheHeightChosenBeforeThePause() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let original = harness.windows.windows["a"]!.original.height
        harness.model.navigate(.shrinkHeight)
        await harness.settle()
        let chosen = harness.windows.windows["a"]!.frame.height
        #expect(chosen < original)

        harness.model.pause()
        #expect(harness.windows.windows["a"]!.frame.height == original)
        harness.model.start()
        await harness.settle()

        #expect(harness.windows.windows["a"]!.frame.height == chosen)
    }

    /// Typing captured for a switch is held for a bounded time. A destination
    /// that stays busy past that deadline drops the held keys rather than
    /// delivering them late, but the switch still finishes and Stagehand keeps
    /// running: a slow system is not a failed switch.
    @Test(.enabled(if: !IsSecureEventInputEnabled(), "Secure Input is on, so the focus gate holds no transfers"))
    func anExpiredInputTransferFinishesTheSwitchWithoutPausing() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a", transferTimeoutMilliseconds: 40)
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.focusDelayMilliseconds = 300

        harness.model.navigate(.focusNext)
        await harness.settle()

        let expiry = harness.events("input_transfer_expired").first?["details"] as? [String: String]
        #expect(expiry?["token"] != nil)
        #expect(harness.events("automatic_pause").isEmpty)
        #expect(harness.events("layout_failed").isEmpty)
        #expect(harness.model.isRunning)
        #expect(harness.model.state.focusedWindowID == "b")
        #expect(harness.windows.focused == "b")
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

    /// Returning from the lock screen lays out once; the border appears once
    /// instead of showing, hiding for the layout, and showing again.
    @Test func resumingShowsTheBorderOnceAfterOneLayout() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.desktop.id = nil
        harness.model.nativeDesktopChanged()
        #expect(harness.model.isSuspended)
        let refreshesBefore = harness.events("change_queued").count
        harness.overlays.borderVisibility = []

        harness.desktop.id = 1
        harness.model.nativeDesktopChanged()
        await harness.settle()
        #expect(!harness.model.isSuspended)
        #expect(harness.events("change_queued").count == refreshesBefore + 1)
        #expect(harness.overlays.borderVisibility == [true])
    }

    /// Unlocking after a long lock rechecks at once and then every 50 ms for a
    /// short while, instead of waiting for the 5 s backoff check.
    @Test func unlockingRechecksTheDesktopImmediatelyAndQuickly() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.desktop.id = nil
        for _ in 0...StagehandModel.quickDesktopChecks {
            harness.model.nativeDesktopChanged()
        }
        #expect(harness.model.desktopCheckDelay == .seconds(5))

        // WindowServer still reports the lock when the unlock notification arrives.
        harness.model.screenUnlocked()
        #expect(harness.model.isSuspended)
        #expect(harness.model.desktopCheckDelay == .milliseconds(50))

        harness.desktop.id = 1
        harness.model.nativeDesktopChanged()
        await harness.settle()
        #expect(!harness.model.isSuspended)
        #expect(harness.model.unlockDesktopChecks == 0)
        #expect(harness.events("desktop_resumed").count == 1)

        // A long lock that outlasts the unlock checks falls back to the backoff.
        harness.desktop.id = nil
        harness.model.nativeDesktopChanged()
        harness.model.screenUnlocked()
        for _ in 0..<StagehandModel.unlockDesktopCheckCount {
            harness.model.nativeDesktopChanged()
        }
        #expect(harness.model.unlockDesktopChecks == 0)
        #expect(harness.model.desktopCheckDelay == .seconds(5))
    }

    /// Sleep during a switch: the in-flight transition is dropped and rolled
    /// back without pausing, and the wake refresh lays the ribbon out again.
    @Test func sleepDuringASwitchDropsTheTransitionAndWakeLaysOutAgain() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.focusDelayMilliseconds = 400

        harness.model.navigate(.focusNext)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !harness.model.changes.isProcessing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
        harness.model.systemWillSleep()

        #expect(harness.model.isRunning)
        #expect(!harness.model.changes.isProcessing)
        #expect(!harness.model.ribbonMotion.isRunning)
        #expect(harness.model.state.focusedWindowID == "a")
        #expect(harness.model.workspaceRestoration.isInTransition == false)
        #expect(harness.events("system_will_sleep").count == 1)

        // Wake: WindowSystem reports a change, and the refresh must lay out again.
        harness.windows.focusDelayMilliseconds = 0
        harness.windows.onChange?()
        await harness.settle()
        #expect(harness.model.isRunning)
        #expect(harness.events("automatic_pause").isEmpty)
        #expect(harness.model.state.focusedWindowID == harness.windows.focusedWindowID())
        #expect(harness.events("change_completed").contains {
            ($0["details"] as? [String: String])?["operation"] == "preferences"
        })
    }

    /// README: one built-in display only. With the lid closed on an external
    /// display, Stagehand used to fall back to NSScreen.main and manage that
    /// display. Now it pauses once the display change settles, and refuses to
    /// start without the built-in display.
    @Test func losingTheBuiltInDisplayPausesAndRestoresAfterTheChangeSettles() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        let originals = harness.windows.windows.mapValues(\.original)
        harness.model.displayCheckDelay = .milliseconds(60)
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.windows.windows.mapValues(\.frame) != originals)

        // A transient change that comes back within the delay does not pause.
        harness.model.builtInScreenProvider = { nil }
        harness.model.screenParametersChanged()
        harness.model.builtInScreenProvider = { NSScreen.screens.first }
        harness.model.screenParametersChanged()
        try? await Task.sleep(for: .milliseconds(150))
        await harness.settle()
        #expect(harness.model.isRunning)

        harness.model.builtInScreenProvider = { nil }
        harness.model.screenParametersChanged()
        #expect(harness.model.isRunning)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while harness.model.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!harness.model.isRunning)
        #expect(harness.windows.windows.mapValues(\.frame) == originals)
        #expect((harness.events("paused").last?["details"] as? [String: String])?["reason"] == "built_in_display_unavailable")
        #expect(harness.model.warning == StagehandModel.missingDisplayWarning)
        #expect(harness.events("automatic_pause").isEmpty)

        harness.model.start()
        #expect(!harness.model.isRunning)
        #expect((harness.events("start_failed").last?["details"] as? [String: String])?["reason"] == "built_in_display_unavailable")

        harness.model.builtInScreenProvider = { NSScreen.screens.first }
        harness.model.start()
        await harness.settle()
        #expect(harness.model.isRunning)
    }

    /// Revoking Accessibility in System Settings sends no notification. The
    /// model used to notice only when its own window became active, leaving
    /// windows parked offscreen with no way to move them back.
    @Test func revokingAccessibilityWhileRunningPausesAndRegrantingRecovers() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        let originals = harness.windows.windows.mapValues(\.original)
        harness.model.accessibilityPollInterval = .milliseconds(20)
        harness.model.startAccessibilityMonitor()
        harness.model.start()
        await harness.settle()
        harness.model.navigate(.focusNext)
        await harness.settle()
        #expect(harness.model.isRunning)

        harness.windows.isAccessibilityTrusted = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while harness.model.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!harness.model.isRunning)
        #expect(!harness.model.accessibilityGranted)
        #expect(harness.windows.windows.mapValues(\.frame) == originals)
        #expect((harness.events("paused").last?["details"] as? [String: String])?["reason"] == "accessibility_revoked")
        #expect(harness.events("accessibility_revoked").count == 1)
        #expect(harness.model.warning == StagehandModel.accessibilityRevokedWarning)
        #expect(harness.overlays.warnings.last == StagehandModel.accessibilityRevokedWarning)
        #expect(harness.events("automatic_pause").isEmpty)

        // Start is refused while revoked.
        harness.model.start()
        #expect(!harness.model.isRunning)
        #expect((harness.events("start_failed").last?["details"] as? [String: String])?["reason"] == "accessibility_permission_missing")

        harness.windows.isAccessibilityTrusted = true
        while !harness.model.accessibilityGranted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.model.accessibilityGranted)
        #expect(harness.events("accessibility_granted").count == 1)
        #expect(!harness.model.isRunning)
        #expect(harness.model.warning == nil)
        harness.model.start()
        await harness.settle()
        #expect(harness.model.isRunning)
    }
}
