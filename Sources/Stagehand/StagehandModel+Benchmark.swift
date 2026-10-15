import AppKit
import QuartzCore
import SwiftUI
import StagehandCore
import StagehandPlatform

/// Time from the kernel's process start to applicationDidFinishLaunching.
@MainActor var launchFinishedMilliseconds: Int?
/// Time to construct the model in applicationDidFinishLaunching.
@MainActor var modelInitMilliseconds: Int?

/// Posts a block to the main thread every 4 ms from a background thread and
/// records how long each waited. The keyboard tap, gestures, and ribbon frames
/// all run on the main thread, so this delay is the input latency users feel.
final class MainThreadLatencyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var postedTimes: [Double] = []
    private var running = false

    func start() {
        lock.withLock {
            samples.removeAll()
            postedTimes.removeAll()
            running = true
        }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let posted = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let waited = (CACurrentMediaTime() - posted) * 1_000
                    self.lock.withLock {
                        self.samples.append(waited)
                        self.postedTimes.append(posted)
                    }
                    answered.signal()
                }
                answered.wait()
                usleep(4_000)
            }
        }
    }

    /// Stalls over 33 ms as (posted uptime, waited ms).
    var stalls: [(Double, Double)] {
        lock.withLock { zip(postedTimes, samples).filter { $0.1 > 33 } }
    }

    func stop() -> [Double] {
        lock.withLock {
            running = false
            return samples
        }
    }
}

/// `--benchmark`: measures startup, navigation latency, ribbon frame cost, main-thread
/// stalls, and interface load times against the disposable acceptance probe windows.
extension StagehandModel {
    private struct SwitchTiming {
        var motion: Double?
        var focus: Double?
        var settled: Double = 0
        var frameWork: [Double] = []
        var droppedFrames = 0
    }

    func runBenchmark(probeURL: URL, busy: Bool, switches: Int = 24) async -> String {
        guard Bundle(url: probeURL)?.bundleIdentifier == "dev.stagehand.AcceptanceProbe" else {
            return "FAIL: expected dist/AcceptanceProbe.app."
        }
        guard accessibilityGranted, let system = windowSystem as? WindowSystem else {
            return "FAIL: Accessibility permission is missing for this build."
        }
        let loggingWasEnabled = diagnostics.isEnabled
        let logging = !ProcessInfo.processInfo.arguments.contains("--no-diagnostics")
        diagnostics.isEnabled = logging
        windowSystem.focusDiagnosticsEnabled = logging
        let reports = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagehand-benchmark-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var probes: [NSRunningApplication] = []
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
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
                return "FAIL: could not launch the probe."
            }
            probes.append(probe)
        }
        system.managedBundleIdentifiers = ["dev.stagehand.AcceptanceProbe"]
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while system.scanWindows().count < 4, ContinuousClock.now < discoveryDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard system.scanWindows().count == 4 else { return "FAIL: the probe windows did not appear." }
        try? await Task.sleep(for: .milliseconds(400))
        var scans: [Double] = []
        for _ in 0..<9 {
            let began = CACurrentMediaTime()
            _ = system.scanWindows()
            scans.append((CACurrentMediaTime() - began) * 1_000)
        }

        var lines = ["Benchmark (\(busy ? "busy" : "responsive") probes, 4 windows, \(switches) switches"
            + (logging ? ")" : ", diagnostic logging off)")]
        if let launchFinishedMilliseconds { lines.append("Launch to didFinishLaunching: \(launchFinishedMilliseconds) ms") }
        if let modelInitMilliseconds { lines.append("Model init: \(modelInitMilliseconds) ms") }
        lines.append("Window scan (3 apps): " + Self.percentiles(scans, digits: 1))
        let monitor = MainThreadLatencyMonitor()

        // Startup: Start through the first settled layout.
        monitor.start()
        let startBegan = CACurrentMediaTime()
        start()
        let startReturned = CACurrentMediaTime()
        await benchmarkWaitUntilIdle()
        let startSettled = CACurrentMediaTime()
        lines.append(String(format: "Start: call %.0f ms, settled %.0f ms", (startReturned - startBegan) * 1_000,
                            (startSettled - startBegan) * 1_000))
        lines.append("  main thread: " + Self.stallSummary(monitor.stop()))
        guard isRunning else { return "FAIL: Stagehand did not start. Warning: \(warning ?? "none")" }

        // Sequential switches: one at a time, settled between them.
        var timings: [SwitchTiming] = []
        var current: SwitchTiming?
        var switchBegan = 0.0
        var lastTick: TimeInterval?
        var events: [(Double, String)] = []
        diagnostics.eventObserver = { event in
            let now = CACurrentMediaTime()
            events.append((now, event))
            switch event {
            case "ribbon_animation_started" where current?.motion == nil:
                current?.motion = (now - switchBegan) * 1_000
            case "navigation_focus_confirmed" where current?.focus == nil:
                current?.focus = (now - switchBegan) * 1_000
            default: break
            }
        }
        ribbonMotion.onFrameTiming = { timestamp, work in
            current?.frameWork.append(work * 1_000)
            if let lastTick {
                let frames = Int(((timestamp - lastTick) / (1.0 / 60)).rounded())
                current?.droppedFrames += max(0, frames - 1)
            }
            lastTick = timestamp
        }
        monitor.start()
        var forward = true
        for _ in 0..<switches {
            var predicted = state
            if !predicted.apply(forward ? .focusNext : .focusPrevious) { forward.toggle() }
            current = SwitchTiming()
            lastTick = nil
            switchBegan = CACurrentMediaTime()
            navigate(forward ? .focusNext : .focusPrevious)
            await benchmarkWaitUntilIdle()
            current?.settled = (CACurrentMediaTime() - switchBegan) * 1_000
            if let current { timings.append(current) }
            current = nil
            try? await Task.sleep(for: .milliseconds(busy ? 300 : 150))
        }
        let sequentialStalls = monitor.stop()
        var blockedByPhase: [String: Double] = [:]
        for (posted, waited) in monitor.stalls {
            let phase = events.last(where: { $0.0 <= posted })?.1 ?? "before"
            blockedByPhase[phase, default: 0] += waited
        }
        lines.append("Sequential switches:")
        lines.append("  to first motion: " + Self.percentiles(timings.compactMap(\.motion)))
        lines.append("  to focus confirmed: " + Self.percentiles(timings.compactMap(\.focus)))
        lines.append("  to settled: " + Self.percentiles(timings.map(\.settled)))
        let work = timings.flatMap(\.frameWork)
        let dropped = timings.map(\.droppedFrames).reduce(0, +)
        lines.append("  frame work per tick: " + Self.percentiles(work, digits: 2)
            + ", dropped frames \(dropped) of \(work.count + dropped)")
        lines.append("  main thread: " + Self.stallSummary(sequentialStalls))
        lines.append("  stalls by phase: " + blockedByPhase.sorted { $0.value > $1.value }
            .map { "\($0.key) \(Int($0.value))" }.joined(separator: ", "))
        diagnostics.eventObserver = nil
        ribbonMotion.onFrameTiming = nil

        // Rapid switches with reversals, as in acceptance.
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
        await benchmarkWaitUntilIdle()
        lines.append(String(format: "Rapid switches: settled %.0f ms after the first", (CACurrentMediaTime() - rapidBegan) * 1_000))
        lines.append("  main thread: " + Self.stallSummary(monitor.stop()))
        lines.append("Final focus matches the ribbon: \(isRunning && state.focusedWindowID == windowSystem.focusedWindowID())")

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

        monitor.start()
        let pauseBegan = CACurrentMediaTime()
        pause()
        lines.append(String(format: "Pause and restore frames: %.0f ms", (CACurrentMediaTime() - pauseBegan) * 1_000))
        lines.append("  main thread: " + Self.stallSummary(monitor.stop()))
        return lines.joined(separator: "\n")
    }

    private func benchmarkWaitUntilIdle(timeout: Duration = .seconds(8)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while changes.isProcessing || ribbonMotion.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
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
