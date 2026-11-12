import AppKit
import StagehandCore
import StagehandPlatform

/// Wakes the system stage on Stagehand's events and the system notifications it waits
/// for. Each wait ends when its condition holds or at its deadline.
@MainActor
final class AcceptanceEvents {
    static let screenParametersChanged = "screen_parameters_notification"
    static let activeSpaceChanged = "active_space_notification"
    static let stateChanged = "state_changed"

    private(set) var counts: [String: Int] = [:]
    var changesStartedWhileSuspended = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var signalledWhileIdle = false

    func count(_ event: String) -> Int { counts[event, default: 0] }

    func note(_ event: String) {
        counts[event, default: 0] += 1
        guard continuation != nil else {
            signalledWhileIdle = true
            return
        }
        resume(returning: true)
    }

    /// False when `timeout` passed before `condition` held.
    func wait(for timeout: Duration, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard await nextEvent(before: deadline) else { return condition() }
        }
        return true
    }

    private func nextEvent(before deadline: ContinuousClock.Instant) async -> Bool {
        if signalledWhileIdle {
            signalledWhileIdle = false
            return true
        }
        guard ContinuousClock.now < deadline else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                self?.resume(returning: false)
            }
        }
    }

    private func resume(returning eventArrived: Bool) {
        deadlineTask?.cancel()
        deadlineTask = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: eventArrived)
    }
}

/// `--acceptance-system`: a display scaling change and a native Desktop switch, each
/// reported as ok, FAIL, or not run with the missing prerequisite.
extension StagehandModel {
    struct SystemStageReport {
        var lines: [String] = []
        var failures = 0
        private var outcomes: [String] = []

        var summary: String { outcomes.joined(separator: ", ") }

        mutating func record(_ check: String, failures found: [String], ok detail: String) {
            if found.isEmpty {
                lines.append("\(check): ok (\(detail))")
                outcomes.append("\(check.lowercased()) ok")
            } else {
                lines += found.map { "FAIL: \(check.lowercased()): \($0)" }
                failures += found.count
                outcomes.append("\(check.lowercased()) FAIL")
            }
        }

        mutating func notRun(_ check: String, _ reason: String) {
            lines.append("\(check): not run (\(reason))")
            outcomes.append("\(check.lowercased()) not run")
        }
    }

    private static let displayChangeTimeout: Duration = .seconds(10)
    private static let desktopSwitchTimeout: Duration = .seconds(5)
    private static let layoutTimeout: Duration = .seconds(6)

    func acceptanceSystemStage(system: WindowSystem, typed: inout [TypedProbe]) async -> SystemStageReport {
        let events = AcceptanceEvents()
        let previousEventObserver = diagnostics.eventObserver
        let previousStateChange = onStateChange
        diagnostics.eventObserver = { [weak self] event in
            previousEventObserver?(event)
            if event == "change_started", self?.isSuspended == true { events.changesStartedWhileSuspended += 1 }
            events.note(event)
        }
        onStateChange = {
            previousStateChange?()
            events.note(AcceptanceEvents.stateChanged)
        }
        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { events.note(AcceptanceEvents.screenParametersChanged) } }
        let spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { events.note(AcceptanceEvents.activeSpaceChanged) } }
        defer {
            diagnostics.eventObserver = previousEventObserver
            onStateChange = previousStateChange
            NotificationCenter.default.removeObserver(screenToken)
            NSWorkspace.shared.notificationCenter.removeObserver(spaceToken)
        }
        var report = SystemStageReport()
        await acceptanceScalingChange(system: system, events: events, report: &report)
        await acceptanceDesktopSwitch(system: system, events: events, typed: &typed, report: &report)
        return report
    }

    // MARK: Scaling

    private func acceptanceScalingChange(system: WindowSystem, events: AcceptanceEvents,
                                         report: inout SystemStageReport) async {
        let check = "Scaling change"
        guard let display = DisplayModeSwitch.activeBuiltInDisplay(),
              let modes = DisplayModeSwitch(display: display) else {
            return report.notRun(check, "the built-in display is not active")
        }
        guard let (targetMode, target) = modes.alternativeMode() else {
            return report.notRun(check, "the built-in display has no other scaled mode of the same shape")
        }
        let parked = await parkProbeWindow(system: system, events: events)
        guard !parked.isEmpty else {
            return report.record(check, failures: ["no probe window was parked before the change"], ok: "")
        }
        let original = modes.original
        var failures: [String] = []
        var screenChanges = events.count(AcceptanceEvents.screenParametersChanged)
        let applied = modes.apply(targetMode)
        if applied == .success {
            failures += await verifyDisplayChange(to: target, since: screenChanges, modes: modes,
                                                  parked: parked, system: system, events: events)
        } else {
            failures.append("switching to \(target.pointSize) failed with CGError \(applied.rawValue)")
        }
        screenChanges = events.count(AcceptanceEvents.screenParametersChanged)
        let restored = modes.restore()
        if restored != .success {
            failures.append("restoring \(original.pointSize) failed with CGError \(restored.rawValue); "
                + "macOS restores it when Stagehand quits")
        } else if applied == .success {
            failures += await verifyDisplayChange(to: original, since: screenChanges, modes: modes,
                                                  parked: parked, system: system, events: events)
        }
        report.record(check, failures: failures, ok: "\(original.pointSize) to \(target.pointSize) and back, "
            + "\(parked.count) parked window\(parked.count == 1 ? "" : "s") read again each time")
    }

    /// Moves the focused probe window to another space, which parks it, and returns
    /// every parked probe window.
    private func parkProbeWindow(system: WindowSystem, events: AcceptanceEvents) async -> [String] {
        navigate(.moveToSpace(index: state.activeSpaceIndex == 0 ? 1 : 0, follow: false))
        _ = await events.wait(for: Self.layoutTimeout) { self.layoutIsIdle }
        return windows.map(\.id).filter { system.isParked(windowID: $0) }
    }

    private var layoutIsIdle: Bool { !changes.isProcessing && !ribbonMotion.isRunning }

    private func verifyDisplayChange(to mode: DisplayModeOption, since screenChanges: Int, modes: DisplayModeSwitch,
                                     parked: [String], system: WindowSystem, events: AcceptanceEvents) async -> [String] {
        let size = CGSize(width: mode.width, height: mode.height)
        let label = "at \(mode.pointSize)"
        let screenChanged = await events.wait(for: Self.displayChangeTimeout) {
            events.count(AcceptanceEvents.screenParametersChanged) > screenChanges && modes.screenSize == size
        }
        guard screenChanged else {
            return ["\(label): the screen did not change within \(Self.displayChangeTimeout)"]
        }
        let laidOut = await events.wait(for: Self.layoutTimeout) {
            !self.isRunning || self.isSuspended
                || (self.layoutIsIdle && parked.allSatisfy { system.parkingReadSinceDisplayChange(windowID: $0) })
        }
        guard isRunning, !isSuspended else {
            return ["\(label): Stagehand \(isRunning ? "suspended" : "paused") (\(warning ?? "no warning"))"]
        }
        guard laidOut else {
            let unread = parked.filter { !system.parkingReadSinceDisplayChange(windowID: $0) }
            return ["\(label): " + (unread.isEmpty
                ? "the layout did not finish within \(Self.layoutTimeout)"
                : "the layout did not read \(unread.count) parked window\(unread.count == 1 ? "" : "s") again "
                    + "within \(Self.layoutTimeout)")]
        }
        let visibleFrames = Self.visibleFramesInWindowCoordinates()
        var failures: [String] = []
        for id in parked {
            let name = windows.first { $0.id == id }?.title ?? id
            guard system.isParked(windowID: id) else {
                failures.append("\(label): \(name) is no longer parked")
                continue
            }
            let remnant = parkedRemnantWidth(forBundleIdentifier: windows.first { $0.id == id }?.bundleIdentifier ?? "")
            guard let frame = system.observedFrame(windowID: id) else {
                failures.append("\(label): could not read \(name)'s frame")
                continue
            }
            if !Self.parkedFrameShowsOnlyRemnant(frame, visibleFrames: visibleFrames, remnantWidth: remnant) {
                failures.append("\(label): parked \(name) at \(frame) shows more than \(Int(remnant)) pt of a visible frame")
            }
        }
        return failures
    }

    /// Each screen's visible frame with a top-left origin, as Accessibility reports windows.
    private static func visibleFramesInWindowCoordinates() -> [CGRect] {
        let screens = NSScreen.screens
        guard let primaryTop = screens.first?.frame.maxY else { return [] }
        return screens.map {
            CGRect(x: $0.visibleFrame.minX, y: primaryTop - $0.visibleFrame.maxY,
                   width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
    }

    /// Parking leaves at most a side strip of `remnantWidth` showing so macOS does not
    /// clamp the window back; anything more is visible content.
    static func parkedFrameShowsOnlyRemnant(_ frame: CGRect, visibleFrames: [CGRect], remnantWidth: CGFloat) -> Bool {
        visibleFrames.allSatisfy { visible in
            let shown = frame.intersection(visible)
            guard !shown.isNull, shown.width > 0, shown.height > 0 else { return true }
            let atSide = frame.minX >= visible.maxX - remnantWidth || frame.maxX <= visible.minX + remnantWidth
            return atSide && shown.width <= remnantWidth
        }
    }

    // MARK: Desktop switch

    private func acceptanceDesktopSwitch(system: WindowSystem, events: AcceptanceEvents,
                                         typed: inout [TypedProbe], report: inout SystemStageReport) async {
        let check = "Desktop switch"
        let readiness = DesktopSwitchReadiness.check(
            displays: DisplaySpaces.current(),
            builtInIdentifier: DisplayModeSwitch.activeBuiltInDisplay().flatMap(DisplaySpaces.identifier(of:)),
            hotKeys: SymbolicHotKeys.current())
        guard case .ready(let plan) = readiness else {
            if case .notRun(let reason) = readiness { report.notRun(check, reason) }
            return
        }
        _ = await events.wait(for: Self.layoutTimeout) { self.layoutIsIdle }
        guard isRunning, !isSuspended, layoutIsIdle else {
            return report.record(check, failures: ["Stagehand was not running and idle before the switch"], ok: "")
        }
        let ribbonBefore = state
        let framesBefore = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, system.observedFrame(windowID: $0.id)) })
        var failures: [String] = []
        var unreadableAway = 0
        let spaceChanges = events.count(AcceptanceEvents.activeSpaceChanged)
        let changesBefore = events.changesStartedWhileSuspended
        if plan.away.post() {
            let left = await events.wait(for: Self.desktopSwitchTimeout) {
                self.isSuspended && events.count(AcceptanceEvents.activeSpaceChanged) > spaceChanges
            }
            if left {
                for (id, before) in framesBefore {
                    guard let before, let now = system.observedFrame(windowID: id) else {
                        unreadableAway += 1
                        continue
                    }
                    if !framesMatch(observed: now, target: before) {
                        let name = windows.first { $0.id == id }?.title ?? id
                        failures.append("\(name) moved from \(before) to \(now) while away")
                    }
                }
            } else {
                failures.append(isSuspended
                    ? "macOS reported no Space change within \(Self.desktopSwitchTimeout) of \(plan.away.displayName)"
                    : "Stagehand did not suspend within \(Self.desktopSwitchTimeout) of \(plan.away.displayName)")
            }
        } else {
            failures.append("could not make the \(plan.away.displayName) key events")
        }
        failures += await returnToStagehandDesktop(plan: plan, events: events)
        let layoutsAway = events.changesStartedWhileSuspended - changesBefore
        if layoutsAway > 0 { failures.append("\(layoutsAway) layout change\(layoutsAway == 1 ? "" : "s") started while away") }
        if failures.isEmpty {
            if state.spaces != ribbonBefore.spaces || state.activeSpaceIndex != ribbonBefore.activeSpaceIndex {
                failures.append("the ribbon's spaces, order, widths, or focus changed across the switch")
            }
            if let focused = state.focusedWindowID {
                let text = Self.probeText(5_000)
                await type(text)
                typed.append(TypedProbe(text: text, expectedWindowID: focused, duringTransition: false,
                                        moment: "after Desktop return"))
            }
        }
        report.record(check, failures: failures, ok: "\(plan.away.displayName) and back; no layout or window moves "
            + "while away" + (unreadableAway > 0 ? ", \(unreadableAway) frames unreadable while away" : ""))
    }

    /// Switches back whenever Stagehand's Desktop is not showing, also after a failure,
    /// and never when the first switch did not happen.
    private func returnToStagehandDesktop(plan: DesktopSwitchPlan, events: AcceptanceEvents) async -> [String] {
        desktopScope.invalidate()
        switch desktopScope.refresh() {
        case .home:
            return []
        case .unknown:
            return ["could not tell which Desktop is showing, so \(plan.back.displayName) was not sent; "
                + "check the Desktop by hand"]
        case .away:
            break
        }
        let resumes = events.count("desktop_resume_refreshed")
        guard plan.back.post() else {
            return ["could not make the \(plan.back.displayName) key events; press it by hand to return"]
        }
        let returned = await events.wait(for: Self.desktopSwitchTimeout) {
            !self.isSuspended && events.count("desktop_resume_refreshed") > resumes && self.layoutIsIdle
        }
        guard returned else {
            desktopScope.invalidate()
            let stillAway = desktopScope.refresh() != .home
            return [stillAway
                ? "still on another Desktop \(Self.desktopSwitchTimeout) after \(plan.back.displayName); press it by hand to return"
                : "Stagehand did not resume and finish its layout within \(Self.desktopSwitchTimeout) of returning"]
        }
        return []
    }
}
