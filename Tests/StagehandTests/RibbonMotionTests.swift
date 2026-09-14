import AppKit
import Testing
import StagehandCore
@testable import Stagehand

@MainActor
private final class TestRibbonFrameDriver: RibbonFrameDriving {
    private var handler: ((TimeInterval) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var maximumFramesPerSecond: Int?

    func start(maximumFramesPerSecond: Int, onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        startCount += 1
        self.maximumFramesPerSecond = maximumFramesPerSecond
        handler = onFrame
        return true
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(at timestamp: TimeInterval) {
        handler?(timestamp)
    }
}

@MainActor @Test func swipePreviewStopsAtTheAdjacentWindowForEveryAcceptedWidth() {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
    for width in [CGFloat(300), 700, 1000] {
        var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "a")])
        let widths = ["a": width, "b": width, "c": width]
        let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(for: state, availableFrame: viewport,
                                                                           observedWidths: widths).map { ($0.windowID, $0.frame) })
        let preview = RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: 8, displacement: -0.25)
        state.apply(.focusNext)
        let destination = Dictionary(uniqueKeysWithValues: WindowLayout.placements(for: state, availableFrame: viewport,
                                                                                  observedWidths: widths).map { ($0.windowID, $0.frame) })
        #expect(preview == destination)
    }
}

@MainActor @Test func swipePreviewTravelDoesNotChangeWithWindowWidth() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
    var observedTravel: [CGFloat] = []

    for leadingWidth in [CGFloat(250), 950] {
        let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "a")])
        let widths = ["a": leadingWidth, "b": CGFloat(950), "c": CGFloat(950)]
        let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
            for: state,
            availableFrame: viewport,
            observedWidths: widths
        ).map { ($0.windowID, $0.frame) })
        let preview = RibbonMotion.dragFrames(
            state: state,
            from: base,
            availableFrame: viewport,
            gap: 8,
            displacement: -0.04
        )
        observedTravel.append(abs((try #require(preview["a"])).minX - (try #require(base["a"])).minX))
    }

    #expect(abs((try #require(observedTravel.first)) - 160) < 0.001)
    #expect(abs((try #require(observedTravel.last)) - 160) < 0.001)
}

@MainActor @Test func swipeCompletionUsesVisibleProgressForDifferentWindowWidths() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)

    for leadingWidth in [CGFloat(250), 950] {
        let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "a")])
        let widths = ["a": leadingWidth, "b": CGFloat(950), "c": CGFloat(950)]
        let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
            for: state,
            availableFrame: viewport,
            observedWidths: widths
        ).map { ($0.windowID, $0.frame) })
        var destination = state
        destination.apply(.focusNext)
        let target = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
            for: destination,
            availableFrame: viewport,
            observedWidths: widths
        ).map { ($0.windowID, $0.frame) })
        let distance = abs((try #require(target["a"])).minX - (try #require(base["a"])).minX)
        let displacementForFullTravel = Double(distance / viewport.width / 4)

        #expect(RibbonMotion.horizontalCompletionAction(
            state: state,
            from: base,
            availableFrame: viewport,
            gap: 8,
            displacement: -displacementForFullTravel * 0.29,
            velocity: 0
        ) == nil)
        #expect(RibbonMotion.horizontalCompletionAction(
            state: state,
            from: base,
            availableFrame: viewport,
            gap: 8,
            displacement: -displacementForFullTravel * 0.31,
            velocity: 0
        ) == .focusNext)
        if leadingWidth == 950 {
            #expect(RibbonMotion.horizontalCompletionAction(
                state: state,
                from: base,
                availableFrame: viewport,
                gap: 8,
                displacement: -0.02,
                velocity: -0.5
            ) == .focusNext)
            #expect(RibbonMotion.horizontalCompletionAction(
                state: state,
                from: base,
                availableFrame: viewport,
                gap: 8,
                displacement: -0.02,
                velocity: 0.5
            ) == nil)
        }
    }
}

@MainActor @Test func swipePreviewTracksLinearlyWithoutResizingAndResistsOnlyAtRibbonEnds() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
    let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "b")])
    let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(for: state, availableFrame: viewport,
                                                                       gap: -55, observedHeights: ["a": 400, "b": 600, "c": 500]).map { ($0.windowID, $0.frame) })
    for direction in [-1.0, 1] {
        let full = RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: -55, displacement: direction * 0.25)
        let distance = abs((try #require(full["b"])).minX - (try #require(base["b"])).minX)
        let halfDisplacement = direction * Double(distance / viewport.width / 4 / 2)
        let half = RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: -55, displacement: halfDisplacement)
        for (id, start) in base {
            let frame = try #require(half[id])
            #expect(frame.size == start.size)
            #expect(frame.minY == start.minY)
            #expect(abs(frame.minX - (start.minX + (try #require(full[id])).minX) / 2) < 0.001)
        }
    }
    var first = state
    first.focus(windowID: "a")
    let boundary = RibbonMotion.dragFrames(state: first, from: base, availableFrame: viewport, gap: -55, displacement: 0.5)
    #expect(try #require(boundary["a"]).minX - #require(base["a"]).minX < 60)
    #expect(RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: -55, displacement: 0) == base)
}

@MainActor @Test func ribbonSlideOnlyInterpolatesPositionAndReachesExactDestination() {
    let from = ["a": CGRect(x: 500, y: 40, width: 900, height: 700)]
    let to = ["a": CGRect(x: 0, y: 40, width: 900, height: 700)]
    #expect(RibbonMotion.interpolate(from: from, to: to, progress: 0) == from)
    #expect(RibbonMotion.interpolate(from: from, to: to, progress: 1) == to)
    let middle = RibbonMotion.interpolate(from: from, to: to, progress: 0.5)["a"]!
    #expect(middle.minX > 0 && middle.minX < 250)
    #expect(middle.size == to["a"]?.size)
}

@MainActor @Test func ribbonSlideKeepsTheTargetsVerticalPosition() throws {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver)
    let target = CGRect(x: 0, y: 40, width: 900, height: 700)
    let reported = CGRect(x: 1000, y: 692, width: 900, height: 700)
    var updates: [CGRect] = []
    var completions = 0

    // A delayed vertical position report must not turn horizontal navigation
    // into an upward slide.
    motion.animate(from: ["window": reported], to: ["window": target], duration: 0.2,
                   update: { frames in
        if let frame = frames["window"] { updates.append(frame) }
    }, completion: { completions += 1 })
    let start = CACurrentMediaTime()
    for elapsed in [0.01, 0.05, 0.1, 0.25] { driver.emit(at: start + elapsed) }

    #expect(updates.count == 4)
    for frame in updates {
        #expect(frame.minY == target.minY)
        #expect(frame.size == target.size)
    }
    let first = try #require(updates.first)
    #expect(first.minX > target.minX && first.minX < reported.minX)
    #expect(updates.last == target)
    #expect(completions == 1)
    #expect(!motion.isRunning)
}

@MainActor @Test func retargetedSlideNeverCompletesAnOutdatedAnimation() async throws {
    let motion = RibbonMotion()
    let a = ["a": CGRect(x: 0, y: 0, width: 900, height: 700)]
    let b = ["a": CGRect(x: 900, y: 0, width: 900, height: 700)]
    var staleCompletions = 0
    var currentCompletions = 0
    motion.animate(from: a, to: b, update: { _ in }, completion: { staleCompletions += 1 })
    await Task.yield()
    motion.animate(from: motion.frames, to: a, duration: 0, update: { _ in }, completion: { currentCompletions += 1 })
    try await Task.sleep(for: .milliseconds(30))
    #expect(staleCompletions == 0)
    #expect(currentCompletions == 1)
    #expect(!motion.isRunning)
    #expect(motion.frames == a)
}

@MainActor @Test func cancellingDuringTheFinalPositionWriteCannotRunStaleCleanup() async throws {
    let motion = RibbonMotion()
    let start = ["a": CGRect(x: 0, y: 0, width: 900, height: 700)]
    let target = ["a": CGRect(x: 100, y: 0, width: 900, height: 700)]
    var completions = 0
    motion.animate(from: start, to: target, duration: 0,
                   update: { _ in motion.cancel() }, completion: { completions += 1 })
    #expect(completions == 0)
    motion.animate(from: start, to: target, duration: 0.01,
                   update: { frames in if frames == target { motion.cancel() } },
                   completion: { completions += 1 })
    try await Task.sleep(for: .milliseconds(40))
    #expect(completions == 0)
}

@MainActor @Test func gestureFramesAreCoalescedToTheDisplayRefresh() throws {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver)
    let first = ["a": CGRect(x: 10, y: 0, width: 900, height: 700)]
    let latest = ["a": CGRect(x: 30, y: 0, width: 900, height: 700)]
    var updates: [[String: CGRect]] = []

    motion.follow(frames: { first }, update: { updates.append($0) })
    motion.follow(frames: { latest }, update: { updates.append($0) })
    #expect(driver.startCount == 1)
    #expect(driver.maximumFramesPerSecond == 60)
    #expect(updates.isEmpty)

    driver.emit(at: 1)
    #expect(updates == [latest])
    #expect(motion.frames == latest)
}

@MainActor @Test func gestureGeometryIsComputedOnlyOncePerDisplayRefresh() {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver)
    let first = ["a": CGRect(x: 10, y: 0, width: 900, height: 700)]
    let latest = ["a": CGRect(x: 30, y: 0, width: 900, height: 700)]
    var computations = 0
    var updates: [[String: CGRect]] = []

    motion.follow(frames: {
        computations += 1
        return first
    }, update: { updates.append($0) })
    motion.follow(frames: {
        computations += 1
        return latest
    }, update: { updates.append($0) })

    #expect(computations == 0)
    #expect(updates.isEmpty)
    driver.emit(at: 1)
    #expect(computations == 1)
    #expect(updates == [latest])
}

@MainActor @Test func motionPositionsAlignToDisplayPixels() {
    #expect(RibbonMotion.pixelAligned(
        CGPoint(x: 10.24, y: 20.26),
        backingScaleFactor: 2
    ) == CGPoint(x: 10, y: 20.5))
    #expect(RibbonMotion.pixelAligned(
        CGPoint(x: 10.6, y: 20.4),
        backingScaleFactor: 0
    ) == CGPoint(x: 11, y: 20))
}

@MainActor @Test func ribbonPositionWritesRetryAWindowThatIsTemporarilyUnavailable() {
    let target = CGRect(x: 100.25, y: 40.25, width: 900, height: 700)
    var writtenPositions: [String: CGPoint] = [:]
    var writeAttempts = 0
    var isAvailable = false

    let firstFailure = writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in
            writeAttempts += 1
            return isAvailable
        },
        observedFrame: { _ in isAvailable ? target : nil }
    )

    #expect(firstFailure == nil)
    #expect(writtenPositions.isEmpty)

    isAvailable = true
    let retryFailure = writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in
            writeAttempts += 1
            return isAvailable
        },
        observedFrame: { _ in target }
    )

    #expect(retryFailure == nil)
    #expect(writeAttempts == 2)
    #expect(writtenPositions["window"] == CGPoint(x: 100.5, y: 40.5))
}

@MainActor @Test func ribbonPositionWritesStillFailWhenAReadableWindowRejectsTheMove() throws {
    let current = CGRect(x: 50, y: 40, width: 900, height: 700)
    let target = CGRect(x: 100, y: 40, width: 900, height: 700)
    var writtenPositions: [String: CGPoint] = [:]

    let failure = try #require(writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in false },
        observedFrame: { _ in current }
    ))

    #expect(failure.windowID == "window")
    #expect(failure.requestedFrame == target)
    #expect(failure.actualFrame == current)
    #expect(writtenPositions.isEmpty)
}

@MainActor @Test func parkingSkipsUnavailableWindowsAndReportsReadableFailures() {
    let readableFrame = CGRect(x: 50, y: 40, width: 900, height: 700)
    var attempts: [String] = []

    let parkedOutcome = parkWindow(
        windowID: "parked",
        park: { windowID in
            attempts.append(windowID)
            return true
        },
        observedFrame: { _ in
            Issue.record("A successful parking write needs no follow-up read")
            return readableFrame
        }
    )
    let unavailableOutcome = parkWindow(
        windowID: "unavailable",
        park: { windowID in
            attempts.append(windowID)
            return false
        },
        observedFrame: { _ in nil }
    )
    let blockedOutcome = parkWindow(
        windowID: "blocked",
        park: { windowID in
            attempts.append(windowID)
            return false
        },
        observedFrame: { _ in readableFrame }
    )

    #expect(parkedOutcome == .parked)
    #expect(unavailableOutcome == .deferred)
    #expect(attempts == ["parked", "unavailable", "blocked"])
    #expect(blockedOutcome == .failed)
}
