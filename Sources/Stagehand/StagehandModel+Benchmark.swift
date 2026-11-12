import AppKit
import QuartzCore
import SwiftUI
import StagehandCore
import StagehandPlatform

/// Time from the kernel's process start to applicationDidFinishLaunching.
@MainActor var launchFinishedMilliseconds: Int?
/// Time to construct the model in applicationDidFinishLaunching.
@MainActor var modelInitMilliseconds: Int?

/// `--benchmark`: measures startup, navigation latency, ribbon frame cost, main-thread
/// stalls, and interface load times against the disposable acceptance probe windows.
extension StagehandModel {
    func runBenchmark(probeURL: URL, busy: Bool, switches: Int = 24, rawOutput: URL? = nil) async -> String {
        var record = BenchmarkRecord()
        var lines: [String] = []
        await performBenchmark(probeURL: probeURL, busy: busy, switches: switches, record: &record, lines: &lines)
        if let rawOutput {
            do {
                try record.jsonData().write(to: rawOutput)
            } catch {
                record.failures.append("raw samples not written to \(rawOutput.path): \(error.localizedDescription)")
            }
        }
        lines.append(record.resultLine)
        return lines.joined(separator: "\n")
    }

    private func performBenchmark(probeURL: URL, busy: Bool, switches: Int,
                                  record: inout BenchmarkRecord, lines: inout [String]) async {
        func fail(_ reason: String) {
            record.failures.append("setup: " + reason)
            lines.append("FAIL: " + reason)
        }
        guard Bundle(url: probeURL)?.bundleIdentifier == "dev.stagehand.AcceptanceProbe" else {
            return fail("expected dist/AcceptanceProbe.app.")
        }
        guard accessibilityGranted, let system = windowSystem as? WindowSystem else {
            return fail("Accessibility permission is missing for this build.")
        }
        guard let screen = builtInScreen else { return fail("no built-in display.") }
        let loggingWasEnabled = diagnostics.isEnabled
        let activityWasEnabled = MainThreadActivity.isEnabled
        MainThreadActivity.setEnabled(true)
        defer { MainThreadActivity.setEnabled(activityWasEnabled) }
        let logging = !ProcessInfo.processInfo.arguments.contains("--no-diagnostics")
        let measuresStacking = ProcessInfo.processInfo.arguments.contains("--stacking")
        // Column stacks, not window stacking order: `--stacking` above measures when a
        // destination reaches the front of WindowServer's window order.
        let stacksColumns = ProcessInfo.processInfo.arguments.contains("--column-stacks")
        let ribbonFramesPerSecond = Double(preferredRibbonFrameRate(maximum: screen.maximumFramesPerSecond))
        record.environment = .init(
            displayWidthPoints: screen.frame.width,
            displayHeightPoints: screen.frame.height,
            backingScale: screen.backingScaleFactor,
            maximumFramesPerSecond: screen.maximumFramesPerSecond,
            ribbonFramesPerSecond: ribbonFramesPerSecond,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        record.settings = .init(gap: gap, widthPresets: widthPresets, loggingEnabled: logging, busyProbes: busy,
                                measuresStacking: measuresStacking, columnStacks: stacksColumns, switches: switches)
        diagnostics.isEnabled = logging
        windowSystem.focusDiagnosticsEnabled = logging
        // Marks the probe-driven run so scripts/analyze-log.py can leave it out of real usage.
        diagnostics.record("diagnostic_run_began", details: ["kind": "benchmark"])
        let reports = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagehand-benchmark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var probes: [NSRunningApplication] = []
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            diagnostics.record("diagnostic_run_ended", details: ["kind": "benchmark"])
            diagnostics.eventObserver = nil
            ribbonMotion.onFrameTiming = nil
            pause()
            system.managedBundleIdentifiers = nil
            for probe in probes { probe.terminate() }
            try? FileManager.default.removeItem(at: reports)
            _ = previousApp?.activate(options: [])
            diagnostics.isEnabled = loggingWasEnabled
            windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
        }
        for (label, count) in [("a", 2), ("b", 1), ("c", 1)] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--windows", String(count), "--report", reports.path, "--label", label]
                + (busy ? ["--busy"] : [])
            guard let probe = try? await NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration) else {
                return fail("could not launch the probe.")
            }
            probes.append(probe)
        }
        system.managedBundleIdentifiers = ["dev.stagehand.AcceptanceProbe"]
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while system.scanWindows().count < 4, ContinuousClock.now < discoveryDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard system.scanWindows().count == 4 else { return fail("the probe windows did not appear.") }
        try? await Task.sleep(for: .milliseconds(400))
        var scans: [Double] = []
        for _ in 0..<9 {
            let began = CACurrentMediaTime()
            _ = system.scanWindows()
            scans.append((CACurrentMediaTime() - began) * 1_000)
        }

        lines.append("Benchmark (\(busy ? "busy" : "responsive") probes, 4 windows, \(switches) switches"
            + (stacksColumns ? ", two windows stacked in one column, columns "
                + String(format: "%.2f", Self.columnBenchmarkWidthFraction) + " of the screen wide" : "")
            + (logging ? ")" : ", diagnostic logging off)"))
        if let launchFinishedMilliseconds { lines.append("Launch to didFinishLaunching: \(launchFinishedMilliseconds) ms") }
        if let modelInitMilliseconds { lines.append("Model init: \(modelInitMilliseconds) ms") }
        lines.append("Window scan (3 apps): " + Self.percentiles(scans, digits: 1))
        let monitor = MainThreadLatencyMonitor()

        // Startup: Start through the first settled layout.
        monitor.start()
        let startBegan = CACurrentMediaTime()
        start()
        let startReturned = CACurrentMediaTime()
        let startIdle = await benchmarkWaitUntilIdle()
        let startSettled = CACurrentMediaTime()
        let startWaits = monitor.stop().map(\.milliseconds)
        record.phases.start = .init(callMs: (startReturned - startBegan) * 1_000,
                                    settledMs: (startSettled - startBegan) * 1_000,
                                    timedOut: !startIdle, mainThreadWaitsMs: startWaits)
        lines.append(String(format: "Start: call %.0f ms, settled %.0f ms", (startReturned - startBegan) * 1_000,
                            (startSettled - startBegan) * 1_000) + (startIdle ? "" : " (timed out)"))
        lines.append("  main thread: " + Self.stallSummary(startWaits))
        if !startIdle { record.failures.append("start: idle wait timed out") }
        guard isRunning else { return fail("Stagehand did not start. Warning: \(warning ?? "none")") }
        if stacksColumns {
            // The focused window joins a neighbor, so every switch below crosses or
            // reveals a stacked column: several windows written for one slot.
            var predicted = state
            let action: NavigationAction = predicted.apply(.stackNext) ? .stackNext : .stackPrevious
            navigate(action)
            guard await benchmarkWaitUntilIdle() else { return fail("stacking two probe windows did not settle.") }
            guard state.currentSpace.columns.contains(where: \.isStack) else {
                return fail("could not stack two probe windows.")
            }
            // Stacking leaves three columns at the probes' own 640-point width. With a
            // negative gap they fit a wide screen (1640 of 1800 points at -140), so no
            // switch would slide and the run would measure no motion. Columns this wide
            // overflow the screen for every allowed gap, so each switch scrolls.
            state = Self.widenedForColumnBenchmark(state)
            enqueue(.refresh)
            guard await benchmarkWaitUntilIdle() else { return fail("widening the probe columns did not settle.") }
            guard let availableFrame,
                  Self.everyColumnSwitchScrolls(state, availableFrame: availableFrame, gap: gap) else {
                return fail("the stacked probe columns fit on screen, so switches would not slide.")
            }
        }
        let frameInterval = 1 / ribbonFramesPerSecond

        // Sequential switches: one at a time, settled between them.
        var forward = true
        let sequential = await measureSwitchPhase(count: switches, busy: busy, probes: probes,
                                                  measuresStacking: measuresStacking, monitor: monitor,
                                                  frameInterval: frameInterval) {
            var predicted = state
            if !predicted.apply(forward ? .focusNext : .focusPrevious) { forward.toggle() }
            return forward ? .focusNext : .focusPrevious
        }
        record.phases.sequential = sequential
        record.failures += BenchmarkRecord.switchFailures(sequential, name: "sequential")
        lines.append("Sequential switches:")
        lines += Self.switchPhaseLines(sequential, measuresStacking: measuresStacking, attributesStalls: true)

        // Rapid switches with reversals, as in acceptance.
        var rapidRejections = 0
        diagnostics.eventObserver = { event in
            if event == "navigation_focus_rejected" { rapidRejections += 1 }
        }
        monitor.start()
        let rapidBegan = CACurrentMediaTime()
        var predicted = state
        for index in 0..<switches {
            let action: NavigationAction = index % 7 == 3 || index % 11 == 5 ? .focusPrevious : .focusNext
            if !predicted.apply(action) {
                let reverse: NavigationAction = action == .focusNext ? .focusPrevious : .focusNext
                predicted.apply(reverse)
                navigate(reverse)
            } else {
                navigate(action)
            }
            try? await Task.sleep(for: .milliseconds(index % 3 == 0 ? 0 : 40))
        }
        let rapidIdle = await benchmarkWaitUntilIdle()
        let rapidSettled = (CACurrentMediaTime() - rapidBegan) * 1_000
        let rapidWaits = monitor.stop().map(\.milliseconds)
        diagnostics.eventObserver = nil
        // A busy probe spins 150 ms on activation, longer than the 100 ms Accessibility
        // timeout, so focus is read after the same pause the other phases leave.
        try? await Task.sleep(for: .milliseconds(busy ? 300 : 150))
        let rapidFocusMismatch = finalFocusMismatch()
        let rapidFocusMatches = rapidFocusMismatch == nil
        record.phases.rapid = .init(settledMs: rapidSettled, timedOut: !rapidIdle, mainThreadWaitsMs: rapidWaits,
                                    finalFocusMatches: rapidFocusMatches)
        if !rapidIdle { record.failures.append("rapid: idle wait timed out") }
        if rapidRejections > 0 { record.failures.append("rapid: focus rejected \(rapidRejections) times") }
        if let rapidFocusMismatch { record.failures.append("rapid: final focus does not match the ribbon: \(rapidFocusMismatch)") }
        lines.append(String(format: "Rapid switches: settled %.0f ms after the first", rapidSettled)
            + (rapidIdle ? "" : " (timed out)"))
        lines.append("  main thread: " + Self.stallSummary(rapidWaits))
        lines.append("Final focus matches the ribbon: \(rapidFocusMatches)" + (rapidFocusMismatch.map { " (\($0))" } ?? ""))

        if stacksColumns, let stack = state.currentSpace.columns.first(where: \.isStack) {
            // Focus moving up and down inside the stack: no slide, one focus each.
            focusWindow(stack.windowIDs[0])
            if await benchmarkWaitUntilIdle() {
                var memberIndex = 0
                let members = await measureSwitchPhase(count: 16, busy: busy, probes: probes,
                                                       measuresStacking: false, monitor: monitor,
                                                       frameInterval: frameInterval) {
                    defer { memberIndex += 1 }
                    return memberIndex.isMultiple(of: 2) ? .focusMemberBelow : .focusMemberAbove
                }
                record.phases.members = members
                record.failures += BenchmarkRecord.switchFailures(members, name: "members")
                lines.append("Member switches in the stack:")
                lines += Self.switchPhaseLines(members, measuresStacking: false, attributesStalls: false)
            } else {
                record.failures.append("members: focusing the stack's first window did not settle")
            }
        }

        // Space switches: no slide; the outgoing space is parked as a whole.
        navigate(.moveToSpace(index: 1, follow: false))
        let spaceSetupIdle = await benchmarkWaitUntilIdle()
        if spaceSetupIdle, state.spaces[1].windowIDs.count == 1 {
            var spaceIndex = 0
            let spaces = await measureSwitchPhase(count: 16, busy: busy, probes: probes,
                                                  measuresStacking: measuresStacking, monitor: monitor,
                                                  frameInterval: frameInterval) {
                defer { spaceIndex += 1 }
                return spaceIndex.isMultiple(of: 2) ? .nextSpace : .previousSpace
            }
            record.phases.spaces = spaces
            record.failures += BenchmarkRecord.switchFailures(spaces, name: "spaces")
            lines.append("Space switches:")
            lines += Self.switchPhaseLines(spaces, measuresStacking: measuresStacking, attributesStalls: false)
        } else {
            record.failures.append("spaces: setup failed")
            lines.append("Space switches: setup failed")
        }

        // Interface load times.
        var appBar: [Double] = []
        for _ in 0..<5 {
            let began = CACurrentMediaTime()
            overlays.showNavigation(state: state, windows: windows)
            appBar.append((CACurrentMediaTime() - began) * 1_000)
            try? await Task.sleep(for: .milliseconds(50))
        }
        lines.append("App bar show: " + appBar.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " ms")
        var settingsTimes: [Double] = []
        for _ in 0..<2 {
            let began = CACurrentMediaTime()
            let settings = SettingsWindow.make(model: self, showOnboarding: {})
            settings.orderFront(nil)
            settings.displayIfNeeded()
            settingsTimes.append((CACurrentMediaTime() - began) * 1_000)
            settings.close()
            try? await Task.sleep(for: .milliseconds(100))
        }
        lines.append("Settings open (create, order front, first draw): "
            + settingsTimes.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms")
        var quickTimes: [Double] = []
        for _ in 0..<2 {
            let began = CACurrentMediaTime()
            let panel = QuickControlsPanel(contentView: NSHostingView(rootView: QuickControlsView(
                model: self, openSettings: {}, quit: {}, requestAccessibility: {}
            )))
            panel.present(at: CGPoint(x: 400, y: 400))
            panel.displayIfNeeded()
            quickTimes.append((CACurrentMediaTime() - began) * 1_000)
            panel.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
        lines.append("Quick controls open: " + quickTimes.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms")
        record.phases.interface = .init(appBarShowMs: appBar, settingsOpenMs: settingsTimes, quickControlsOpenMs: quickTimes)

        // The restore runs inside the call, so the call's duration is the main-thread stall.
        let pauseBegan = CACurrentMediaTime()
        pause()
        let pauseMilliseconds = (CACurrentMediaTime() - pauseBegan) * 1_000
        record.phases.pause = .init(callMs: pauseMilliseconds)
        lines.append(String(format: "Pause and restore frames: %.0f ms", pauseMilliseconds))
    }

    /// Runs `count` navigations, each settled before the next, and times motion, focus and frames.
    private func measureSwitchPhase(count: Int, busy: Bool, probes: [NSRunningApplication], measuresStacking: Bool,
                                    monitor: MainThreadLatencyMonitor, frameInterval: Double,
                                    nextAction: () -> NavigationAction) async -> BenchmarkRecord.SwitchPhase {
        let recorder = BenchmarkSwitchRecorder()
        diagnostics.eventObserver = { recorder.observe($0) }
        ribbonMotion.onFrameTiming = { recorder.frame(at: $0, work: $1, interval: frameInterval) }
        defer {
            diagnostics.eventObserver = nil
            ribbonMotion.onFrameTiming = nil
        }
        var phase = BenchmarkRecord.SwitchPhase()
        monitor.start()
        for _ in 0..<count {
            let action = nextAction()
            let began = CACurrentMediaTime()
            recorder.begin(at: began)
            navigate(action)
            let stackingTask = frontmostPoll(measuresStacking ? state.focusedWindowID : nil,
                                             since: began, probes: probes)
            let idle = await benchmarkWaitUntilIdle()
            var timing = recorder.finish()
            timing.settledMs = (CACurrentMediaTime() - began) * 1_000
            timing.timedOut = !idle
            let stacking = await stackingTask.value
            if measuresStacking {
                timing.frontmostMs = stacking.front
                timing.reordersAfterFrontmost = stacking.reorders
            }
            if timing.slid {
                let motion = windowSystem.motionWriteStatistics(reset: false, focusedWindowID: state.focusedWindowID)
                timing.focusedGapMs = motion["focusedMotionGapMilliseconds"].flatMap(Double.init)
                timing.largestGapMs = motion["largestMotionGapMilliseconds"].flatMap(Double.init)
            }
            phase.switches.append(timing)
            try? await Task.sleep(for: .milliseconds(busy ? 300 : 150))
        }
        let waits = monitor.stop()
        phase.mainThreadWaitsMs = waits.map(\.milliseconds)
        phase.stalls = waits.filter { $0.milliseconds > MainThreadLatencyMonitor.stallMilliseconds }.map {
            BenchmarkRecord.Stall(
                waitedMs: $0.milliseconds,
                label: $0.label.replacingOccurrences(of: #" pid=-?\d+"#, with: "", options: .regularExpression),
                phase: recorder.lastEvent(atOrBefore: $0.postedUptime) ?? "before"
            )
        }
        phase.finalFocusMismatch = finalFocusMismatch()
        phase.finalFocusMatches = phase.finalFocusMismatch == nil
        return phase
    }

    /// Nil when macOS reports the ribbon's focused window; otherwise what each side says.
    private func finalFocusMismatch() -> String? {
        guard isRunning else { return "Stagehand is not running" }
        let observed = windowSystem.focusedWindowID()
        guard observed != state.focusedWindowID else { return nil }
        return "macOS reports \(observed ?? "no readable focused window"), the ribbon \(state.focusedWindowID ?? "none")"
    }

    private static func switchPhaseLines(_ phase: BenchmarkRecord.SwitchPhase, measuresStacking: Bool,
                                         attributesStalls: Bool) -> [String] {
        let switches = phase.switches
        var lines = [
            "  slid on \(switches.count(where: \.slid)) of \(switches.count) switches",
            "  to motion scheduled: " + percentiles(switches.compactMap(\.motionScheduledMs)),
            "  to focus confirmed: " + percentiles(switches.compactMap(\.focusMs))
                + ", rejected \(switches.count(where: \.focusRejected))"
                + ", no attempt \(switches.count { !$0.focusAttempted })",
            "  to settled: " + percentiles(switches.map(\.settledMs))
                + ", timed out \(switches.count(where: \.timedOut))"
        ]
        if measuresStacking {
            let front = switches.map(\.frontmostMs)
            let reorders = switches.compactMap(\.reordersAfterFrontmost)
            lines.append("  destination frontmost on screen: " + percentiles(front.compactMap { $0 })
                + ", never within 1 s: \(front.count { $0 == nil })")
            lines.append("  stacking reorders after the destination was in front: \(reorders.reduce(0, +)) in "
                + "\(reorders.count { $0 > 0 }) of \(reorders.count) switches")
        }
        let work = switches.flatMap(\.frameWorkMs)
        if !work.isEmpty {
            let dropped = switches.map(\.droppedFrames).reduce(0, +)
            lines.append("  frame work per tick: " + percentiles(work, digits: 2)
                + ", dropped frames \(dropped) of \(work.count + dropped)")
            lines.append("  longest freeze of the destination window mid-motion: "
                + percentiles(switches.compactMap(\.focusedGapMs)))
            lines.append("  longest freeze of any moving window: " + percentiles(switches.compactMap(\.largestGapMs)))
        }
        lines.append("  main thread: " + stallSummary(phase.mainThreadWaitsMs))
        if attributesStalls {
            func totals(_ key: (BenchmarkRecord.Stall) -> String) -> [(String, Double)] {
                Dictionary(grouping: phase.stalls, by: key).mapValues { $0.reduce(0) { $0 + $1.waitedMs } }
                    .sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            }
            lines.append("  stalls by phase: " + totals(\.phase).map { "\($0.0) \(Int($0.1))" }.joined(separator: ", "))
            lines.append("  stalls by call: " + totals(\.label).prefix(4).map { "\($0.0) \(Int($0.1))" }
                .joined(separator: ", "))
        }
        if let finalFocusMatches = phase.finalFocusMatches {
            lines.append("Final focus matches the ribbon: \(finalFocusMatches)"
                + (phase.finalFocusMismatch.map { " (\($0))" } ?? ""))
        }
        return lines
    }

    /// Milliseconds from `since` until WindowServer lists the window frontmost among the
    /// probes' on-screen windows (nil if not within a second), and how many times the
    /// probes' front-to-back order changed after that during the next 600 ms: a
    /// reordering the user can see as a flicker.
    /// Polls the window list off the main thread, so neither the polling nor its
    /// 600 ms hold after the destination comes to the front shows up as time to
    /// settled. Only with --stacking: polling every 4 ms from any thread still
    /// froze the main thread for ~500 ms at the start of motion in 4 of 6 busy
    /// runs, and none in 2 runs without it.
    private func frontmostPoll(_ windowID: String?, since: Double,
                               probes: [NSRunningApplication]) -> Task<(front: Double?, reorders: Int), Never> {
        let number = windowID.flatMap { windowSystem.windowNumber(for: $0) }
        let pids = Set(probes.map(\.processIdentifier))
        return Task.detached(priority: .utility) {
            guard let number else { return (nil, 0) }
            return await Self.timeUntilFrontmost(number, since: since, pids: pids)
        }
    }

    nonisolated private static func timeUntilFrontmost(_ number: UInt32, since: Double,
                                                       pids: Set<pid_t>) async -> (front: Double?, reorders: Int) {
        func order() -> [UInt32] {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            return info.compactMap { window in
                guard (window[kCGWindowOwnerPID as String] as? Int32).map(pids.contains) == true,
                      (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
                return window[kCGWindowNumber as String] as? UInt32
            }
        }
        var front: Double?
        var last: [UInt32] = []
        var reorders = 0
        while CACurrentMediaTime() - since < (front == nil ? 1 : 0.6 + (front ?? 0) / 1_000) {
            let current = order()
            if front == nil, current.first == number {
                front = (CACurrentMediaTime() - since) * 1_000
                last = current
            } else if front != nil, current != last {
                reorders += 1
                last = current
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
        return (front, reorders)
    }

    /// The column width the `--column-stacks` run sets, one of the default presets.
    static let columnBenchmarkWidthFraction = 0.75

    /// Every column in the current space at `columnBenchmarkWidthFraction`. Three
    /// such columns overflow the screen for any gap in `GapInput.bounds`.
    static func widenedForColumnBenchmark(_ state: WorkspaceState) -> WorkspaceState {
        var widened = state
        for column in state.currentSpace.columns {
            widened.setWidthFraction(columnBenchmarkWidthFraction, for: column.activeWindowID)
        }
        return widened
    }

    /// Whether focusing each column puts the ribbon at a different offset from its
    /// neighbors', so every switch between adjacent columns slides. False when the
    /// whole ribbon fits on screen, or a clamped end leaves two columns at one offset.
    static func everyColumnSwitchScrolls(_ state: WorkspaceState, availableFrame: CGRect, gap: Double) -> Bool {
        let columns = state.currentSpace.columns
        guard columns.count > 1 else { return false }
        let reference = columns[0].windowIDs[0]
        var offsets: [CGFloat] = []
        for column in columns {
            var focused = state
            focused.focus(windowID: column.activeWindowID)
            let placements = WindowLayout.placements(for: focused, availableFrame: availableFrame, gap: CGFloat(gap))
            guard let x = placements.first(where: { $0.windowID == reference })?.frame.minX else { return false }
            offsets.append(x)
        }
        return zip(offsets, offsets.dropFirst()).allSatisfy { abs($0 - $1) >= 1 }
    }

    /// False when the change queue or ribbon motion was still busy at the timeout.
    private func benchmarkWaitUntilIdle(timeout: Duration = .seconds(8)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while changes.isProcessing || ribbonMotion.isRunning {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private static func percentiles(_ values: [Double], digits: Int = 0) -> String {
        guard !values.isEmpty else { return "n=0" }
        let sorted = values.sorted()
        let at = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let format = "%.\(digits)f"
        return "n=\(sorted.count) p50=" + String(format: format, at(0.5)) + " p90=" + String(format: format, at(0.9))
            + " max=" + String(format: format, sorted.last!) + " ms"
    }

    /// Main-thread wait for a posted block: the worst cases and total time beyond one frame.
    private static func stallSummary(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "no samples" }
        let sorted = samples.sorted()
        let beyondFrame = samples.reduce(0) { $0 + max(0, $1 - 16.7) }
        return String(format: "p99 %.1f ms, max %.0f ms, %d waits over 33 ms, %.0f ms blocked beyond one frame",
                      sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))], sorted.last!,
                      samples.count { $0 > 33 }, beyondFrame)
    }
}

@MainActor
private final class BenchmarkSwitchRecorder {
    private var current: BenchmarkRecord.Switch?
    private var began = 0.0
    private var lastTick: Double?
    private var events: [(uptime: Double, name: String)] = []

    func begin(at uptime: Double) {
        current = BenchmarkRecord.Switch()
        began = uptime
        lastTick = nil
    }

    func finish() -> BenchmarkRecord.Switch {
        defer { current = nil }
        return current ?? BenchmarkRecord.Switch()
    }

    func observe(_ event: String) {
        let now = CACurrentMediaTime()
        events.append((now, event))
        let elapsed = (now - began) * 1_000
        switch event {
        case "ribbon_animation_started" where current?.motionScheduledMs == nil:
            current?.motionScheduledMs = elapsed
        case "navigation_focus_succeeded" where current?.focusMs == nil:
            current?.focusMs = elapsed
        case "navigation_focus_rejected":
            current?.focusRejected = true
        default: break
        }
    }

    func frame(at timestamp: Double, work: Double, interval: Double) {
        guard current != nil else { return }
        current?.frameWorkMs.append(work * 1_000)
        if let lastTick {
            current?.droppedFrames += max(0, Int(((timestamp - lastTick) / interval).rounded()) - 1)
        }
        lastTick = timestamp
    }

    func lastEvent(atOrBefore uptime: Double) -> String? {
        events.last { $0.uptime <= uptime }?.name
    }
}
