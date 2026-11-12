import AppKit
import Carbon
import Testing
@testable import Stagehand

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
