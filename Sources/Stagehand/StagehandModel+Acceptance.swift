import AppKit
import StagehandCore
import StagehandPlatform

/// `--acceptance`: the short focus and navigation check from docs/ACCEPTANCE.md,
/// driven against disposable probe windows. Only the probe's windows are managed.
extension StagehandModel {
    private static let acceptanceProbeID = "dev.stagehand.AcceptanceProbe"

    struct TypedProbe {
        let text: String
        let expectedWindowID: String
        let duringTransition: Bool
        var moment: String?
    }

    func diagnoseAcceptance(probeURL: URL, switches: Int = 30, systemStage: Bool = false) async -> String {
        guard Bundle(url: probeURL)?.bundleIdentifier == Self.acceptanceProbeID else {
            return "FAIL: expected dist/AcceptanceProbe.app. No windows were changed."
        }
        guard accessibilityGranted, let system = windowSystem as? WindowSystem else {
            return "FAIL: Accessibility permission is missing for this build. No windows were changed."
        }
        let ownID = Bundle.main.bundleIdentifier ?? ""
        guard NSRunningApplication.runningApplications(withBundleIdentifier: ownID).count <= 1 else {
            return "FAIL: another Stagehand is running. Quit it first so only one controller manages windows."
        }
        // Log this run without persisting the preference; the published property's
        // observer writes UserDefaults. Restored after the deferred pause below.
        let loggingWasEnabled = diagnostics.isEnabled
        diagnostics.isEnabled = true
        windowSystem.focusDiagnosticsEnabled = true
        defer {
            diagnostics.isEnabled = loggingWasEnabled
            windowSystem.focusDiagnosticsEnabled = diagnosticLoggingEnabled
        }
        let startedAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        // Marks the probe-driven run so scripts/analyze-log.py can leave it out of real usage.
        diagnostics.record("diagnostic_run_began", details: ["kind": "acceptance"])
        defer { diagnostics.record("diagnostic_run_ended", details: ["kind": "acceptance"]) }
        let reports = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagehand-acceptance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var probes: [NSRunningApplication] = []
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            pause()
            system.managedBundleIdentifiers = nil
            for probe in probes { probe.terminate() }
            try? FileManager.default.removeItem(at: reports)
            _ = previousApp?.activate(options: [])
        }

        // Two apps, one with two windows, as in the manual procedure.
        for (label, count) in [("a", 2), ("b", 1)] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--windows", String(count), "--report", reports.path, "--label", label]
            guard let probe = try? await NSWorkspace.shared.openApplication(at: probeURL, configuration: configuration) else {
                return "FAIL: could not launch the acceptance probe."
            }
            probes.append(probe)
        }
        system.managedBundleIdentifiers = [Self.acceptanceProbeID]
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while system.scanWindows().count < 3, ContinuousClock.now < discoveryDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard system.scanWindows().count == 3 else { return "FAIL: the probe windows did not appear." }

        start()
        await waitUntilIdle()
        guard isRunning else { return "FAIL: Stagehand did not start. Warning: \(warning ?? "none")" }
        let originalFrames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let titles = Dictionary(windows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })

        // Rapid switches in both directions, reversing during transitions. Typing right
        // after a switch belongs to that switch's destination once focus is verified.
        var predicted = state
        var typed: [TypedProbe] = []
        var lines0: [String] = []
        for index in 0..<switches {
            let action: NavigationAction = index % 7 == 3 || index % 11 == 5 ? .focusPrevious : .focusNext
            if !predicted.apply(action) {
                // At an end of the ribbon; turn around.
                let reverse: NavigationAction = action == .focusNext ? .focusPrevious : .focusNext
                predicted.apply(reverse)
                navigate(reverse)
            } else {
                navigate(action)
            }
            if index % 4 == 1, let destination = predicted.focusedWindowID {
                let text = Self.probeText(index)
                await type(text)
                typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: true))
            }
            if index % 6 == 5 {
                await waitUntilIdle()
                if let destination = state.focusedWindowID {
                    let text = Self.probeText(index + 1_000)
                    await type(text)
                    typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: false))
                }
            }
            try? await Task.sleep(for: .milliseconds(index % 3 == 0 ? 0 : 40))
        }
        await waitUntilIdle()

        // Space switching: one window in space 2, the other two in space 1. Space
        // changes park the whole outgoing space instead of sliding the ribbon.
        navigate(.moveToSpace(index: 1, follow: false))
        await waitUntilIdle()
        let spaceSwitches = 12
        var spacesReady = state.spaces[1].windowIDs.count == 1 && state.currentSpace.windowIDs.count == 2
        if !spacesReady { lines0.append("FAIL: could not put one window in space 2") }
        for index in 0..<(spacesReady ? spaceSwitches : 0) {
            let action: NavigationAction = index % 2 == 0 ? .nextSpace : .previousSpace
            predicted = state
            guard predicted.apply(action) else { spacesReady = false; break }
            navigate(action)
            if index % 3 == 1, let destination = predicted.focusedWindowID {
                let text = Self.probeText(index + 2_000)
                await type(text)
                typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: true))
            } else if index % 3 == 2 {
                await waitUntilIdle()
                if let destination = state.focusedWindowID {
                    let text = Self.probeText(index + 3_000)
                    await type(text)
                    typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: false))
                }
            } else {
                await waitUntilIdle()
            }
        }
        await waitUntilIdle()

        // Tiles, after the checks above so they run as before: all three windows into
        // one tile with a layout shortcut, typing during and after pane switches and
        // a swap, then back to one window per tile.
        let tile = await acceptanceTiles(system: system, typed: &typed)
        lines0 += tile.failures
        await waitUntilIdle()
        let systemReport = systemStage ? await acceptanceSystemStage(system: system, typed: &typed) : nil
        try? await Task.sleep(for: .milliseconds(400))

        var lines: [String] = lines0
        var failures = 0
        let finalFocusMatches = isRunning && state.focusedWindowID == windowSystem.focusedWindowID()
        if !finalFocusMatches { failures += 1 }
        failures += lines0.count
        lines.append("Space switches: \(spacesReady ? spaceSwitches : 0) of \(spaceSwitches)")
        if !spacesReady { failures += 1 }
        lines.append("Tile steps: \(tile.steps) of \(Self.acceptanceTileSteps)")
        if let systemReport {
            lines += systemReport.lines
            failures += systemReport.failures
        }
        lines.append("Final focus matches the ribbon: \(finalFocusMatches)")
        for probe in typed {
            let landed = titles.compactMap { id, title -> String? in
                let text = (try? String(contentsOf: reports.appendingPathComponent("\(title).txt"), encoding: .utf8)) ?? ""
                return text.contains(probe.text) ? id : nil
            }
            let ok = landed == [probe.expectedWindowID]
            if !ok { failures += 1 }
            let moment = probe.moment ?? "\(probe.duringTransition ? "during" : "after ") switch"
            lines.append("Typing \(moment) -> \(titles[probe.expectedWindowID] ?? "?"): "
                + (ok ? "ok" : "FAIL, landed in \(landed.map { titles[$0] ?? $0 })"))
        }

        pause()
        try? await Task.sleep(for: .milliseconds(200))
        for (id, original) in originalFrames.sorted(by: { $0.key < $1.key }) {
            let actual = system.observedFrame(windowID: id)
            let restored = actual.map { framesMatch(observed: $0, target: original) } ?? false
            if !restored { failures += 1 }
            lines.append("Frame restored for \(titles[id] ?? id): \(restored ? "ok" : "FAIL")")
        }
        lines.append(contentsOf: acceptanceLogSummary(since: startedAt, failures: &failures))
        lines.insert("\(failures == 0 ? "PASS" : "FAIL"): \(switches) switches, \(spaceSwitches) space switches, "
            + "\(tile.steps) tile steps, \(typed.count) typed checks, \(failures) failures"
            + (systemReport.map { ", system stage: \($0.summary)" } ?? ""), at: 0)
        return lines.joined(separator: "\n")
    }

    /// Shortcut steps the tile check makes when every one of them applies.
    private static let acceptanceTileSteps = 7

    /// Gathers the three probe windows into the active space, arranges them as one
    /// wide pane over two, checks the tile's live frames, moves focus between panes
    /// with typing during and after, swaps the bottom panes, then breaks the tile
    /// apart. Returns the steps that applied and a FAIL line for each check that
    /// did not hold.
    private func acceptanceTiles(system: WindowSystem,
                                 typed: inout [TypedProbe]) async -> (steps: Int, failures: [String]) {
        var failures: [String] = []
        var steps = 0
        let home = state.activeSpaceIndex
        if let away = state.spaces.indices.first(where: { $0 != home && !state.spaces[$0].windowIDs.isEmpty }) {
            navigate(.goToSpace(index: away))
            await waitUntilIdle()
            navigate(.moveToSpace(index: home, follow: true))
            await waitUntilIdle()
        }
        guard state.activeSpaceIndex == home, state.currentSpace.windowIDs.count == 3 else {
            return (0, ["FAIL: could not gather the three windows into one space for the tile check"])
        }
        /// Makes one shortcut step and checks that the tiles and focus became what
        /// the workspace predicts. A refused or ignored step counts as a failure.
        func step(_ action: NavigationAction, typeDuring index: Int? = nil) async -> Bool {
            var predicted = state
            guard predicted.apply(action) else {
                failures.append("FAIL: tile step \(action) did not apply")
                return false
            }
            navigate(action)
            if let index, let destination = predicted.focusedWindowID {
                let text = Self.probeText(index)
                await type(text)
                typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: true))
            }
            await waitUntilIdle()
            guard state.currentSpace.tiles.map(\.panes) == predicted.currentSpace.tiles.map(\.panes),
                  state.focusedWindowID == predicted.focusedWindowID else {
                failures.append("FAIL: tile step \(action) was refused or ended elsewhere")
                return false
            }
            steps += 1
            return true
        }
        func typeAfter(_ index: Int) async {
            guard let destination = state.focusedWindowID else { return }
            let text = Self.probeText(index)
            await type(text)
            typed.append(TypedProbe(text: text, expectedWindowID: destination, duringTransition: false))
        }
        // The first window takes the wide top pane.
        for _ in 0..<2 where state.currentSpace.focusedTileIndex.map({ $0 > 0 }) == true {
            navigate(.focusPrevious)
            await waitUntilIdle()
        }
        guard await step(.arrangeTile(.wideOverTwo), typeDuring: 4_000) else { return (steps, failures) }
        await typeAfter(4_001)
        let panes = state.currentSpace.tiles.first?.windowIDs ?? []
        let frames = panes.compactMap { system.observedFrame(windowID: $0) }
        let arranged = panes.count == 3 && frames.count == 3
            && frames[0].maxY <= min(frames[1].minY, frames[2].minY) + 1
            && abs(frames[1].minY - frames[2].minY) <= 2
            && frames[1].maxX <= frames[2].minX + 1
        if !arranged { failures.append("FAIL: the tile is not one wide pane over two side by side") }
        // Pane switches, typing right after each: down, right, up, then down again.
        for (index, action) in [NavigationAction.focusPaneBelow, .focusNext, .focusPaneAbove, .focusPaneBelow]
            .enumerated() {
            guard await step(action, typeDuring: index.isMultiple(of: 2) ? 4_010 + index : nil) else {
                return (steps, failures)
            }
            await typeAfter(4_020 + index)
        }
        // The focused bottom-left pane swaps with its right neighbor, then the tile breaks apart.
        guard await step(.moveWindowRightInTile, typeDuring: 4_030) else { return (steps, failures) }
        await typeAfter(4_031)
        _ = await step(.arrangeTile(.single))
        if state.currentSpace.tiles.count != 3 { failures.append("FAIL: the tile did not come apart into three tiles") }
        return (steps, failures)
    }

    /// Lowercase letters only: harmless if focus ever escapes to another app.
    static func probeText(_ index: Int) -> String {
        // Inner letters exclude q and z, so text typed next to another probe's
        // cannot contain a third probe's string by accident.
        let letters = Array("abcdefghijklmnop")
        var value = index
        var text = "q"
        repeat {
            text.append(letters[value % letters.count])
            value /= letters.count
        } while value > 0
        return text + "z"
    }

    func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for unit in text.utf16 {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                var character = unit
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            // Let the keyboard tap on the main run loop see each key in order.
            try? await Task.sleep(for: .milliseconds(4))
        }
        // Drain the last key before the next switch begins another transfer.
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func waitUntilIdle(timeout: Duration = .seconds(6)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while (changes.isProcessing || ribbonMotion.isRunning), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func acceptanceLogSummary(since start: String, failures: inout Int) -> [String] {
        guard let text = try? String(contentsOf: diagnostics.logURL, encoding: .utf8) else {
            return ["Diagnostic log unavailable"]
        }
        var pauses: [String] = []
        var focusTimes: [Int] = []
        for line in text.split(separator: "\n") {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let timestamp = entry["timestamp"] as? String, timestamp >= start,
                  let event = entry["event"] as? String else { continue }
            let details = entry["details"] as? [String: String] ?? [:]
            switch event {
            case "automatic_pause", "layout_failed":
                pauses.append("\(timestamp) \(event) \(details["reason"] ?? "")")
            case "navigation_focus_confirmed":
                if details["focusConfirmed"] == "false" { pauses.append("\(timestamp) focus rejected") }
                if let report = details["focusReport"],
                   let object = try? JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any],
                   let elapsed = object["elapsedMilliseconds"] as? Int {
                    focusTimes.append(elapsed)
                }
            default: break
            }
        }
        failures += pauses.count
        focusTimes.sort()
        let percentile = { (p: Double) in focusTimes.isEmpty ? 0 : focusTimes[min(focusTimes.count - 1, Int(Double(focusTimes.count) * p))] }
        return ["Focus confirmation ms: n=\(focusTimes.count) p50=\(percentile(0.5)) p90=\(percentile(0.9)) max=\(focusTimes.last ?? 0)"]
            + (pauses.isEmpty ? ["Pauses, layout failures, rejected focus: none"] : pauses.map { "FAIL: \($0)" })
    }
}
