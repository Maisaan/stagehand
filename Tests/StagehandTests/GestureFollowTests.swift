import AppKit
import QuartzCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// Ticks on demand at the given target times, with the cadence a display link would report.
@MainActor
private final class SteppedFrameDriver: RibbonFrameDriving {
    private var handler: ((TimeInterval) -> Void)?
    var frameInterval: TimeInterval?
    var startSucceeds = true

    init(frameInterval: TimeInterval?) {
        self.frameInterval = frameInterval
    }

    func start(display: CGDirectDisplayID, onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        handler = startSucceeds ? onFrame : nil
        return startSucceeds
    }

    func stop() { handler = nil }

    func tick(target: TimeInterval) { handler?(target) }
}

/// Ticks on its own at about 120 Hz, reporting a 60 Hz cadence, like a running display link.
@MainActor
private final class RunningFrameDriver: RibbonFrameDriving {
    private var ticker: Task<Void, Never>?
    let frameInterval: TimeInterval? = 1.0 / 60

    func start(display: CGDirectDisplayID, onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        stop()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                onFrame(CACurrentMediaTime() + 1.0 / 60)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
        return true
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }
}

@MainActor
@Suite(.serialized)
struct GestureFollowTests {
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func follow(_ motion: RibbonMotion, dx: CGFloat) {
        motion.follow(on: 1, frames: { ["a": self.frame.offsetBy(dx: dx, dy: 0)] }, update: { _ in })
    }

    @Test func irregularTicksAreCountedAgainstTheLinksCadenceWithEntryTimesApart() throws {
        let driver = SteppedFrameDriver(frameInterval: 0.010)
        var now = 100.0
        let motion = RibbonMotion(frameDriver: driver, currentTime: { now })
        var started = 0
        var summaries: [RibbonFollowSummary] = []
        motion.onFollowStarted = { started += 1 }
        motion.onFollowEnded = { summaries.append($0) }

        follow(motion, dx: 4)
        follow(motion, dx: 8)
        for (target, entered) in [(100.010, 100.002), (100.020, 100.012), (100.050, 100.055), (100.060, 100.051)] {
            now = entered
            driver.tick(target: target)
        }
        now = 100.070
        motion.cancel()

        #expect(started == 1)
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.ticks == 4)
        #expect(summary.droppedTicks == 2)
        #expect(abs((summary.largestTargetGap ?? 0) - 0.030) < 1e-9)
        #expect(abs((summary.largestCallbackGap ?? 0) - 0.043) < 1e-9)
        #expect(summary.lateCallbacks == 1)
        #expect(summary.started == 100.0)
        #expect(summary.ended == 100.070)
        #expect(!summary.handedToAnimation)
    }

    @Test func aFollowReplacedByASettleIsHandedToTheAnimation() throws {
        let driver = SteppedFrameDriver(frameInterval: nil)
        var now = 5.0
        let motion = RibbonMotion(frameDriver: driver, currentTime: { now })
        var summaries: [RibbonFollowSummary] = []
        motion.onFollowEnded = { summaries.append($0) }

        follow(motion, dx: 4)
        driver.tick(target: 5.010)
        now = 5.012
        driver.tick(target: 5.020)
        motion.animate(on: 1, from: ["a": frame], to: ["a": frame.offsetBy(dx: 50, dy: 0)], update: { _ in },
                       completion: {})
        motion.cancel()

        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.handedToAnimation)
        #expect(summary.ticks == 2)
        #expect(summary.droppedTicks == nil)
    }

    @Test func aFollowWithoutADisplayLinkIsNotMeasured() {
        let driver = SteppedFrameDriver(frameInterval: 0.016)
        driver.startSucceeds = false
        let motion = RibbonMotion(frameDriver: driver, currentTime: { 1 })
        var events = 0
        motion.onFollowStarted = { events += 1 }
        motion.onFollowEnded = { _ in events += 1 }

        follow(motion, dx: 4)
        motion.cancel()

        #expect(events == 0)
    }

    private func details(_ event: [String: Any]) -> [String: String] {
        event["details"] as? [String: String] ?? [:]
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Starts a swipe from frames that landed `touchesLanded` and waits until its follow writes.
    private func beginSwipe(_ harness: ModelHarness, touchesLanded: TimeInterval) async {
        let writes = harness.windows.motionPositionWrites
        InputArrival.delivering(InputArrival(source: .trackpad, eventUptime: touchesLanded + 0.03,
                                             receivedUptime: touchesLanded + 0.031,
                                             touchesLandedUptime: touchesLanded)) {
            harness.model.handleGesture(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
        }
        harness.model.handleGesture(.changed(displacement: -0.04, velocity: -0.5))
        await waitFor { harness.windows.motionPositionWrites > writes }
    }

    private func followEnded(_ harness: ModelHarness) -> [[String: String]] {
        harness.events("gesture_follow_ended").map(details)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns off the preview"))
    func aSwipeThatNavigatesHandsItsFollowToTheChangeItQueued() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", motionDriver: RunningFrameDriver())
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()
        let landed = ProcessInfo.processInfo.systemUptime

        await beginSwipe(harness, touchesLanded: landed)
        harness.model.handleGesture(.ended(displacement: -0.2, velocity: -1.5, action: .focusNext, mode: .plain))
        await harness.settle()

        let ended = try #require(followEnded(harness).first)
        #expect(followEnded(harness).count == 1)
        let queued = try #require(harness.events("change_queued").map(details).first { $0["gestureID"] != nil })
        #expect(ended["gestureID"] == queued["gestureID"])
        #expect(ended["handoff"] == "change")
        #expect(ended["handoffChangeID"] == queued["changeID"])
        #expect(Int(ended["ticks"] ?? "") ?? 0 > 0)
        #expect(ended["droppedTicks"] != "unknown")
        #expect(Int(ended["motionWritesAcknowledged"] ?? "") ?? 0 > 0)
        #expect(ended["motionWritesFailed"] == "0")
        let afterTouch = try #require(ended["firstAcknowledgedWriteAfterTouchMilliseconds"].flatMap(Int.init))
        #expect(afterTouch >= 0)
        #expect(try #require(ended["followStartedAfterTouchMilliseconds"].flatMap(Int.init)) <= afterTouch)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns off the preview"))
    func aShortSwipeHandsItsFollowToTheRestore() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", motionDriver: RunningFrameDriver())
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        await beginSwipe(harness, touchesLanded: ProcessInfo.processInfo.systemUptime)
        harness.model.handleGesture(.ended(displacement: 0, velocity: 0, action: nil, mode: .plain))
        await harness.settle()

        let ended = try #require(followEnded(harness).first)
        #expect(ended["handoff"] == "settle")
        #expect(ended["settleOperation"] == "gesture.preview.restore")
        #expect(ended["handoffChangeID"] == nil)
        // The follow's writes, counted before the restore reset them.
        #expect(Int(ended["motionWritesSent"] ?? "") ?? 0 > 0)
    }

    @Test(.enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns off the preview"))
    func aFollowCutByAPauseEndsCancelled() async throws {
        let harness = ModelHarness(windowIDs: ["a", "b", "c"], focused: "a", motionDriver: RunningFrameDriver())
        defer { harness.cleanUp() }
        harness.model.start()
        await harness.settle()

        await beginSwipe(harness, touchesLanded: ProcessInfo.processInfo.systemUptime)
        harness.model.pause()

        let ended = try #require(followEnded(harness).first)
        #expect(ended["handoff"] == "cancelled")
        #expect(ended["gestureID"] != nil)
    }
}
