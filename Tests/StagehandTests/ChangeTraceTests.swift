import AppKit
import Carbon
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// Every queued change ends in exactly one terminal event, change_completed or
/// change_ended, so scripts/analyze-log.py can tell a merged, cancelled or
/// refused action from a missing one. Before, 8 of 22 actions in a real log
/// were "started, never completed" with nothing saying why.
@MainActor
@Suite(.serialized)
struct ChangeTraceTests {
    private func details(_ event: [String: Any]) -> [String: String] {
        event["details"] as? [String: String] ?? [:]
    }

    private func terminals(_ harness: ModelHarness) -> [String: [String]] {
        var terminals: [String: [String]] = [:]
        for event in harness.events("change_completed") {
            terminals[details(event)["changeID"] ?? "?", default: []].append("completed")
        }
        for event in harness.events("change_ended") {
            terminals[details(event)["changeID"] ?? "?", default: []].append(details(event)["outcome"] ?? "?")
        }
        return terminals
    }

    private func ended(_ harness: ModelHarness, outcome: String) -> [[String: String]] {
        harness.events("change_ended").map(details).filter { $0["outcome"] == outcome }
    }

    private func queuedIDs(_ harness: ModelHarness) -> [String] {
        harness.events("change_queued").compactMap { details($0)["changeID"] }
    }

    private func expectOneTerminalPerQueuedChange(_ harness: ModelHarness,
                                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let queued = queuedIDs(harness)
        let terminals = terminals(harness)
        #expect(!queued.isEmpty, sourceLocation: sourceLocation)
        for id in queued {
            #expect(terminals[id]?.count == 1, "change \(id) ended as \(terminals[id] ?? [])",
                    sourceLocation: sourceLocation)
        }
        #expect(Set(terminals.keys).isSubset(of: Set(queued)), sourceLocation: sourceLocation)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aCompletedSwitchCarriesItsIDOnMotionAndFocus() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusNext)
        await harness.settle()

        let queued = try #require(harness.events("change_queued").map(details).last {
            $0["operation"] == "action.focusNext"
        })
        let id = try #require(queued["changeID"])
        #expect(queued["origin"] == "command")
        #expect(queued["gestureID"] == nil)
        #expect(terminals(harness)[id] == ["completed"])
        for name in ["navigation_motion_planned", "ribbon_animation_started", "ribbon_animation_completed",
                     "navigation_focus_confirmed"] {
            #expect(harness.events(name).map(details).last?["changeID"] == id, "\(name)")
        }
        #expect(harness.events("change_queued").map(details).contains { $0["origin"] == "system" })
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func aStepThatChangesNothingEndsWithNoEffect() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusPrevious)
        await harness.settle()

        #expect(ended(harness, outcome: "noEffect").map { $0["operation"] } == ["action.focusPrevious"])
        #expect(ended(harness, outcome: "noEffect").first?["reason"] == "state_unchanged")
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test(.enabled(if: !IsSecureEventInputEnabled(), "Secure Input is on, so the focus gate holds no transfers"))
    func aStepWithoutTypingMergesIntoTheNextOne() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusNext)
        harness.model.navigate(.focusNext)
        await harness.settle()

        let ids = queuedIDs(harness).suffix(2)
        let merged = try #require(ended(harness, outcome: "merged").first)
        #expect(merged["changeID"] == ids.first)
        #expect(merged["successorChangeID"] == ids.last)
        #expect(terminals(harness)[ids.last ?? ""] == ["completed"])
        #expect(harness.model.state.focusedWindowID == "c")
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func aSlideCutShortByTheNextSwitchIsSupersededNotCompleted() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", motionDriver: HeldFrameDriver())
        defer { harness.cleanUp() }
        harness.model.ribbonMotion.watchdogGrace = .milliseconds(300)
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.focusNext)
        await waitFor { harness.model.ribbonMotion.isAnimating }
        #expect(harness.model.ribbonMotion.isAnimating)
        harness.model.navigate(.focusNext)
        await harness.settle()

        let ids = queuedIDs(harness).filter { id in
            harness.events("change_queued").map(details).contains {
                $0["changeID"] == id && $0["operation"] == "action.focusNext"
            }
        }
        #expect(ids.count == 2)
        let superseded = try #require(ended(harness, outcome: "superseded").first)
        #expect(superseded["changeID"] == ids.first)
        #expect(superseded["successorChangeID"] == ids.last)
        #expect(superseded["reason"] == "slide_cut_short")
        #expect(superseded["appCallsOnMain"] != nil)
        #expect(terminals(harness)[ids.last ?? ""] == ["completed"])
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func sleepInterruptsTheActiveChangeAndCancelsThePendingOnes() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.focusDelayMilliseconds = 400

        harness.model.navigate(.focusNext)
        await waitFor {
            harness.events("change_started").contains { details($0)["operation"] == "action.focusNext" }
        }
        harness.model.navigate(.focusNext)
        let ids = queuedIDs(harness).suffix(2)
        harness.model.systemWillSleep()

        let interrupted = try #require(ended(harness, outcome: "interrupted").first)
        #expect(interrupted["changeID"] == ids.first)
        #expect(interrupted["reason"] == "system_will_sleep")
        let cancelled = try #require(ended(harness, outcome: "cancelled").first)
        #expect(cancelled["changeID"] == ids.last)
        #expect(cancelled["reason"] == "system_will_sleep")
        // A change cancelled while queued was never started, and its trace says so.
        #expect(cancelled["queuedUptimeMs"] != nil)
        #expect(cancelled["startedUptimeMs"] == nil)
        #expect(interrupted["startedUptimeMs"] != nil)

        harness.windows.focusDelayMilliseconds = 0
        harness.windows.onChange?()
        await harness.settle()
        #expect(terminals(harness)[ids.first ?? ""] == ["interrupted"])
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func pausingEndsTheActiveAndPendingChangesWithThePauseReason() async {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.focusDelayMilliseconds = 400

        harness.model.navigate(.focusNext)
        await waitFor {
            harness.events("change_started").contains { details($0)["operation"] == "action.focusNext" }
        }
        harness.model.enqueue(.refresh)
        harness.model.pause()
        await harness.settle()

        #expect(ended(harness, outcome: "interrupted").map { $0["reason"] } == ["manual"])
        #expect(ended(harness, outcome: "cancelled").map { $0["operation"] } == ["refresh"])
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func aFocusFailureEndsTheChangeAsFailedBeforeThePause() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.windows.refusesFocus = ["b"]

        harness.model.navigate(.focusNext)
        await waitFor { !harness.events("automatic_pause").isEmpty }

        let failed = try #require(ended(harness, outcome: "failed").first)
        #expect(failed["operation"] == "action.focusNext")
        #expect(failed["reason"] == "focus_confirmation_failed")
        #expect(terminals(harness)[failed["changeID"] ?? ""] == ["failed"])
        #expect(terminals(harness).values.allSatisfy { $0.count == 1 })
    }

    @Test func aTileLayoutWithTooFewWindowsEndsAsRefused() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.navigate(.arrangeTile(.grid))
        await harness.settle()

        let refused = ended(harness, outcome: "refused")
        #expect(refused.map { $0["operation"] } == ["tiles.arrange.grid"])
        #expect(refused.first?["reason"] == "tile_refused_before_change")
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func aPreferencesLayoutWithoutAManagedFocusedWindowIsSkipped() async {
        let harness = ModelHarness(windowIDs: ["a", "b"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.windows.setFocus("unmanaged")
        harness.model.enqueue(.preferences)
        await harness.settle()

        let skipped = ended(harness, outcome: "skipped")
        #expect(skipped.map { $0["reason"] }.contains("no_managed_window_focused"))
        expectOneTerminalPerQueuedChange(harness)
    }

    @Test func aSwipeCarriesItsGestureIDToTheChangeItQueuesAndToItsRestore() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
        harness.model.handleGesture(.ended(displacement: -0.2, velocity: -1.5, action: .focusNext, mode: .plain))
        await harness.settle()
        harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.01, mode: .plain))
        harness.model.handleGesture(.ended(displacement: 0, velocity: 0, action: nil, mode: .plain))
        await harness.settle()

        let started = harness.events("gesture_motion_started").map { details($0)["gestureID"] }
        #expect(started == ["1", "2"])
        #expect(harness.events("gesture_motion_resolved").map { details($0)["gestureID"] } == ["1", "2"])
        let fromSwipe = harness.events("change_queued").map(details).filter { $0["gestureID"] != nil }
        #expect(fromSwipe.map { $0["gestureID"] } == ["1"])
        #expect(fromSwipe.first?["origin"] == "gesture")
        #expect(fromSwipe.first?["operation"] == "action.focusNext")
        let restore = try #require(harness.events("ribbon_animation_started").map(details).last {
            $0["operation"] == "gesture.preview.restore"
        })
        #expect(restore["gestureID"] == "2")
        #expect(restore["changeID"] == nil)
        expectOneTerminalPerQueuedChange(harness)
    }

    private func uptime(_ details: [String: String], _ key: String,
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> Double {
        try #require(details[key].flatMap(Double.init), "\(key) missing", sourceLocation: sourceLocation)
    }

    @Test(.enabled(if: !IsSecureEventInputEnabled(), "Secure Input is on, so the focus gate holds no transfers"))
    func aSwitchEndsWithItsFeltDelayStampsInOrder() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        var sunk: [EndedChangeTrace] = []
        harness.model.changeTraceSink = { sunk.append($0) }
        let pressed = ProcessInfo.processInfo.systemUptime

        InputArrival.delivering(InputArrival(source: .keyboardTap, eventUptime: pressed - 0.004,
                                             receivedUptime: pressed - 0.002)) {
            harness.model.navigate(.focusNext)
        }
        let typed = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(harness.model.focusGate.processKeyboardEvent(type: .keyDown, event: typed))
        await harness.settle()

        let completed = try #require(harness.events("change_completed").map(details).last {
            $0["operation"] == "action.focusNext"
        })
        #expect(completed["inputSource"] == "keyboardTap")
        let order = ["inputEventUptimeMs", "inputReceivedUptimeMs", "inputDeliveredUptimeMs", "queuedUptimeMs",
                     "startedUptimeMs", "motionScheduledUptimeMs", "firstAcknowledgedWriteUptimeMs",
                     "motionEndedUptimeMs", "focusRequestedUptimeMs", "focusConfirmedUptimeMs",
                     "heldInputPostedUptimeMs"]
        let stamps = try order.map { try uptime(completed, $0) }
        #expect(stamps == stamps.sorted(), "\(zip(order, stamps).map { "\($0) \($1)" })")
        #expect(completed["motionWritesAcknowledged"].flatMap(Int.init) ?? 0 > 0)
        #expect(completed["motionWritesFailed"] == "0")
        #expect(completed["heldInputEvents"] == "1")
        #expect(completed["heldInputTransferAgeMs"] != nil)

        let trace = try #require(sunk.last { $0.operation == "action.focusNext" })
        #expect(trace.outcome == "completed")
        #expect(String(trace.changeID) == completed["changeID"])
        #expect(trace.trace.details == completed.filter { trace.trace.details[$0.key] != nil })
    }

    @Test func theTraceIsFilledWithLoggingOff() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        harness.model.diagnostics.isEnabled = false
        var sunk: [EndedChangeTrace] = []
        harness.model.changeTraceSink = { sunk.append($0) }

        harness.model.navigate(.focusNext)
        await harness.settle()

        let trace = try #require(sunk.first { $0.operation == "action.focusNext" }).trace
        #expect(trace.input == nil)
        #expect(trace.started != nil)
        #expect(trace.motionScheduled != nil)
        #expect(trace.firstAcknowledgedWrite != nil)
        #expect(trace.focusConfirmed != nil)
        #expect(trace.ended != nil)
        #expect(harness.events("change_completed").allSatisfy { details($0)["operation"] != "action.focusNext" })
    }

    @Test func aSwipeChangeCarriesTheArrivalOfItsReleaseFrame() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let now = ProcessInfo.processInfo.systemUptime

        harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
        InputArrival.delivering(InputArrival(source: .trackpad, eventUptime: now - 0.003, receivedUptime: now - 0.002,
                                             touchesLandedUptime: now - 0.2)) {
            harness.model.handleGesture(.ended(displacement: -0.2, velocity: -1.5, action: .focusNext, mode: .plain))
        }
        await harness.settle()

        let completed = try #require(harness.events("change_completed").map(details).last {
            $0["operation"] == "action.focusNext"
        })
        #expect(completed["inputSource"] == "trackpad")
        #expect(try uptime(completed, "touchesLandedUptimeMs") < uptime(completed, "inputEventUptimeMs"))
        #expect(try uptime(completed, "inputDeliveredUptimeMs") <= uptime(completed, "queuedUptimeMs"))
    }

    @Test func aChordThroughTheKeyboardGateStampsTheChangeItQueues() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a")
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let chord = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow),
                                         keyDown: true))
        chord.flags = [.maskControl, .maskAlternate]

        #expect(harness.model.focusGate.processKeyboardEvent(type: .keyDown, event: chord))
        await harness.settle()

        let completed = try #require(harness.events("change_completed").map(details).last {
            $0["operation"] == "action.focusNext"
        })
        #expect(completed["inputSource"] == "keyboardTap")
        #expect(try uptime(completed, "inputReceivedUptimeMs") <= uptime(completed, "queuedUptimeMs"))
        // A change Stagehand queues itself carries no input.
        let systemIDs = Set(harness.events("change_queued").map(details).filter { $0["origin"] == "system" }
            .compactMap { $0["changeID"] })
        let systemTerminals = (harness.events("change_completed") + harness.events("change_ended")).map(details)
            .filter { systemIDs.contains($0["changeID"] ?? "") }
        #expect(!systemTerminals.isEmpty)
        #expect(systemTerminals.allSatisfy { $0["inputSource"] == nil && $0["queuedUptimeMs"] != nil })
    }
}

@MainActor
@Test func cancellingTheQueueReturnsTheItemsItDropped() {
    let queue = ChangeQueue<Int>()
    queue.append(1)
    queue.append(2)
    #expect(queue.cancel() == [1, 2])
    #expect(queue.count == 0)
    #expect(queue.cancel().isEmpty)
}
