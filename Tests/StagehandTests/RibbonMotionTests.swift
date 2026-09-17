import AppKit
import Testing
import StagehandCore
@testable import Stagehand

@MainActor
private final class TestRibbonFrameDriver: RibbonFrameDriving {
    private var handler: ((TimeInterval) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onFrame: @escaping (TimeInterval) -> Void) -> Bool {
        startCount += 1
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

    #expect(abs((try #require(observedTravel.first)) - 200) < 0.001)
    #expect(abs((try #require(observedTravel.last)) - 200) < 0.001)
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
        let configuration = RibbonAnimationConfiguration.default
        let displacementForFullTravel = Double(distance / viewport.width) / configuration.tracking

        #expect(RibbonMotion.horizontalCompletionAction(
            state: state,
            from: base,
            availableFrame: viewport,
            gap: 8,
            displacement: -displacementForFullTravel * (configuration.commitProgress - 0.01),
            velocity: 0
        ) == nil)
        #expect(RibbonMotion.horizontalCompletionAction(
            state: state,
            from: base,
            availableFrame: viewport,
            gap: 8,
            displacement: -displacementForFullTravel * (configuration.commitProgress + 0.01),
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
        let halfDisplacement = direction * Double(distance / viewport.width)
            / RibbonAnimationConfiguration.default.tracking / 2
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
    #expect(abs(middle.minX - 250) < 0.001)
    #expect(middle.size == to["a"]?.size)
}

@MainActor @Test func ribbonSlideAcceleratesIntoAndDeceleratesOutOfOnscreenTranslation() throws {
    let from = ["window": CGRect(x: 1800, y: 40, width: 1800, height: 1130)]
    let to = ["window": CGRect(x: 0, y: 40, width: 1800, height: 1130)]
    let frameCount = 12
    let positions = try (0...frameCount).map { frame in
        try #require(RibbonMotion.interpolate(
            from: from,
            to: to,
            progress: Double(frame) / Double(frameCount)
        )["window"]?.minX)
    }
    let translations = zip(positions, positions.dropFirst()).map { abs($1 - $0) }

    #expect(try #require(translations.first) < #require(translations.dropFirst().first))
    #expect(try #require(translations.last) < #require(translations.dropLast().last))
}

@MainActor @Test func ribbonAnimationCurvesProduceDistinctTiming() {
    let progress = 0.25
    let custom = RibbonAnimationCurve(x1: 0.1, y1: 0.8, x2: 0.4, y2: 0.9)
    let overshoot = RibbonAnimationCurve(x1: 0.1, y1: 1.5, x2: 0.2, y2: 1.5)
    let clamped = RibbonAnimationCurve(x1: -1, y1: -2, x2: 2, y2: 3)

    #expect(RibbonAnimationCurve.linear.progress(at: progress) == progress)
    #expect(RibbonAnimationCurve.smoother.progress(at: progress) < progress)
    #expect(RibbonAnimationCurve.easeOut.progress(at: progress) > progress)
    #expect(RibbonAnimationCurve.ease.progress(at: progress) > progress)
    #expect(custom.progress(at: 0.5) > 0.5)
    #expect(overshoot.progress(at: 0.5) > 1)
    #expect(clamped.controlPoints == [0, -0.5, 1, 1.5])
    #expect(RibbonAnimationCurve.easeInOut.progress(at: -1) == 0)
    #expect(RibbonAnimationCurve.easeInOut.progress(at: 2) == 1)
}

@MainActor @Test func defaultRibbonMotionUsesTheEstablishedConfiguration() {
    #expect(RibbonAnimationConfiguration.default.duration == 0.3)
    #expect(RibbonAnimationConfiguration.default.curve.controlPoints == [0.16, 1, 0.3, 1])
    #expect(RibbonAnimationConfiguration.default.tracking == 5)
    #expect(RibbonAnimationConfiguration.default.commitProgress == 0.4)
    #expect(RibbonAnimationConfiguration.default.flickDistance == 0.02)
    #expect(RibbonAnimationConfiguration.default.flickVelocity == 0.45)
    #expect(RibbonAnimationConfiguration.default.edgeResistance == 60)
}

@MainActor @Test func ribbonFrameDriverLimitsAccessibilityWorkToSixtyUpdatesPerSecond() {
    #expect(preferredRibbonFrameRate(maximum: 120) == 60)
    #expect(preferredRibbonFrameRate(maximum: 60) == 60)
    #expect(preferredRibbonFrameRate(maximum: 30) == 30)
    #expect(preferredRibbonFrameRate(maximum: 0) == 1)
}

@MainActor @Test func gestureTuningChangesTrackingCommitAndBoundaryFeedback() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
    let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b"], focusedWindowID: "a")])
    let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
        for: state,
        availableFrame: viewport,
        observedWidths: ["a": 900, "b": 900]
    ).map { ($0.windowID, $0.frame) })
    let slow = RibbonAnimationConfiguration(duration: 0.2, curve: .smoother, tracking: 2)
    let fast = RibbonAnimationConfiguration(duration: 0.2, curve: .smoother, tracking: 6)
    let slowPreview = RibbonMotion.dragFrames(
        state: state, from: base, availableFrame: viewport, gap: 8,
        displacement: -0.02, configuration: slow
    )
    let fastPreview = RibbonMotion.dragFrames(
        state: state, from: base, availableFrame: viewport, gap: 8,
        displacement: -0.02, configuration: fast
    )
    #expect(abs((try #require(fastPreview["a"])).minX - (try #require(base["a"])).minX)
            > abs((try #require(slowPreview["a"])).minX - (try #require(base["a"])).minX))

    let strict = RibbonAnimationConfiguration(
        duration: 0.2, curve: .smoother, commitProgress: 0.8,
        flickDistance: 0.05, flickVelocity: 1.2
    )
    let loose = RibbonAnimationConfiguration(
        duration: 0.2, curve: .smoother, commitProgress: 0.1,
        flickDistance: 0.01, flickVelocity: 0.2
    )
    #expect(RibbonMotion.horizontalCompletionAction(
        state: state, from: base, availableFrame: viewport, gap: 8,
        displacement: -0.02, velocity: -0.5, configuration: strict
    ) == nil)
    #expect(RibbonMotion.horizontalCompletionAction(
        state: state, from: base, availableFrame: viewport, gap: 8,
        displacement: -0.02, velocity: -0.5, configuration: loose
    ) == .focusNext)

    var boundary = state
    boundary.focus(windowID: "a")
    let firm = RibbonAnimationConfiguration(duration: 0.2, curve: .smoother, edgeResistance: 20)
    let soft = RibbonAnimationConfiguration(duration: 0.2, curve: .smoother, edgeResistance: 140)
    let firmPreview = RibbonMotion.dragFrames(
        state: boundary, from: base, availableFrame: viewport, gap: 8,
        displacement: 0.2, configuration: firm
    )
    let softPreview = RibbonMotion.dragFrames(
        state: boundary, from: base, availableFrame: viewport, gap: 8,
        displacement: 0.2, configuration: soft
    )
    #expect((try #require(softPreview["a"])).minX > (try #require(firmPreview["a"])).minX)
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
    motion.animate(from: ["window": reported], to: ["window": target],
                   configuration: RibbonAnimationConfiguration(
                    duration: 0.2,
                    curve: .smoother
                   ),
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

@MainActor @Test func gestureReleaseHandoffPreservesHorizontalVelocity() throws {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
    let from = ["window": CGRect(x: 500, y: 40, width: 900, height: 700)]
    let to = ["window": CGRect(x: 0, y: 40, width: 900, height: 700)]
    let releaseVelocity = CGFloat(-2_500)
    var updates: [CGRect] = []
    var completions = 0

    motion.animate(
        from: from,
        to: to,
        configuration: RibbonAnimationConfiguration(
            duration: 0.22,
            curve: RibbonAnimationCurve(x1: 0.22, y1: 0.55, x2: 0.32, y2: 1)
        ),
        initialHorizontalVelocity: releaseVelocity,
        update: { frames in
            if let frame = frames["window"] { updates.append(frame) }
        },
        completion: { completions += 1 }
    )
    driver.emit(at: 100.001)
    driver.emit(at: 100.002)

    let first = try #require(updates.first)
    let second = try #require(updates.last)
    let settleVelocity = (second.minX - first.minX) / 0.001
    #expect(abs((settleVelocity - releaseVelocity) / releaseVelocity) < 0.1)

    driver.emit(at: 100.3)
    #expect(updates.last == to["window"])
    #expect(completions == 1)
}

@MainActor @Test func fastGestureSettleDoesNotSpringPastCommittedTarget() throws {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
    let from = ["window": CGRect(x: 0, y: 40, width: 900, height: 700)]
    let to = ["window": CGRect(x: 100, y: 40, width: 900, height: 700)]
    var positions: [CGFloat] = []

    motion.animate(
        from: from,
        to: to,
        configuration: RibbonAnimationConfiguration(
            duration: 0.7,
            curve: RibbonAnimationCurve(x1: 0.184, y1: 0.935, x2: 0.305, y2: 0.989)
        ),
        initialHorizontalVelocity: 20_000,
        update: { frames in
            if let frame = frames["window"] { positions.append(frame.minX) }
        },
        completion: {}
    )
    for frame in 1...84 {
        driver.emit(at: 100 + Double(frame) / 120)
    }

    #expect(!positions.isEmpty)
    #expect(positions.allSatisfy { 0...100 ~= $0 })
    #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(positions.last == 100)
}

@MainActor @Test func gestureSettleKeepsBackgroundWindowsOnOneTimeline() throws {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
    let frame = CGRect(x: 0, y: 40, width: 900, height: 700)
    let from = ["primary": frame, "short": frame, "opposite": frame]
    let to = [
        "primary": frame.offsetBy(dx: 1_000, dy: 0),
        "short": frame.offsetBy(dx: 100, dy: 0),
        "opposite": frame.offsetBy(dx: -300, dy: 0)
    ]
    var update: [String: CGRect] = [:]

    motion.animate(
        from: from,
        to: to,
        configuration: RibbonAnimationConfiguration(
            duration: 0.7,
            curve: RibbonAnimationCurve(x1: 0.184, y1: 0.935, x2: 0.305, y2: 0.989)
        ),
        initialHorizontalVelocity: 20_000,
        update: { update = $0 },
        completion: {}
    )
    driver.emit(at: 100 + 1.0 / 120)

    let primaryProgress = try #require(update["primary"]?.minX) / 1_000
    let shortProgress = try #require(update["short"]?.minX) / 100
    let oppositeProgress = try #require(update["opposite"]?.minX) / -300
    #expect(primaryProgress > 0 && primaryProgress < 1)
    #expect(abs(shortProgress - primaryProgress) < 0.001)
    #expect(abs(oppositeProgress - primaryProgress) < 0.001)
}

@MainActor @Test func boundaryReleaseDoesNotAddAnotherTranslation() {
    for (start, outwardVelocity) in [(CGFloat(-55), CGFloat(-8_000)), (55, 8_000)] {
        let driver = TestRibbonFrameDriver()
        let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
        let from = ["window": CGRect(x: start, y: 40, width: 900, height: 700)]
        let to = ["window": CGRect(x: 0, y: 40, width: 900, height: 700)]
        var positions: [CGFloat] = []

        motion.animate(
            from: from,
            to: to,
            configuration: RibbonAnimationConfiguration(duration: 0.4, curve: .easeOut),
            initialHorizontalVelocity: outwardVelocity,
            update: { frames in
                if let frame = frames["window"] { positions.append(frame.minX) }
            },
            completion: {}
        )
        for frame in 1...48 { driver.emit(at: 100 + Double(frame) / 120) }

        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { min(start, 0)...max(start, 0) ~= $0 })
        if start < 0 {
            #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 })
        } else {
            #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 >= $1 })
        }
        #expect(positions.last == 0)
    }
}

@MainActor @Test func retargetedSlideNeverCompletesAnOutdatedAnimation() {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver)
    let a = ["a": CGRect(x: 0, y: 0, width: 900, height: 700)]
    let b = ["a": CGRect(x: 900, y: 0, width: 900, height: 700)]
    var staleCompletions = 0
    var currentCompletions = 0
    motion.animate(from: a, to: b, update: { _ in }, completion: { staleCompletions += 1 })
    #expect(motion.isRunning)
    motion.animate(
        from: motion.frames,
        to: a,
        configuration: RibbonAnimationConfiguration(
            duration: 0,
            curve: .smoother
        ),
        update: { _ in },
        completion: { currentCompletions += 1 }
    )
    #expect(staleCompletions == 0)
    #expect(currentCompletions == 1)
    #expect(!motion.isRunning)
    #expect(motion.frames == a)
}

@MainActor @Test func awaitedRibbonAnimationResolvesForCompletionAndCancellation() async {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
    let from = ["window": CGRect(x: 0, y: 40, width: 900, height: 700)]
    let to = ["window": CGRect(x: 900, y: 40, width: 900, height: 700)]

    let completed = Task { @MainActor in
        await motion.animate(
            from: from,
            to: to,
            configuration: RibbonAnimationConfiguration(duration: 0.2, curve: .linear),
            update: { _ in }
        )
    }
    await Task.yield()
    driver.emit(at: 100.2)
    #expect(await completed.value)

    let cancelled = Task { @MainActor in
        await motion.animate(
            from: from,
            to: to,
            configuration: RibbonAnimationConfiguration(duration: 0.2, curve: .linear),
            update: { _ in }
        )
    }
    await Task.yield()
    motion.cancel()
    #expect(await !cancelled.value)
}

@MainActor @Test func ribbonAnimationUpdatesOnEveryDisplayRefresh() {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 100 })
    let from = ["window": CGRect(x: 0, y: 40, width: 900, height: 700)]
    let to = ["window": CGRect(x: 900, y: 40, width: 900, height: 700)]
    var updates = 0

    motion.animate(
        from: from,
        to: to,
        configuration: RibbonAnimationConfiguration(duration: 0.1, curve: .linear),
        update: { _ in updates += 1 },
        completion: {}
    )
    for frame in 1..<12 { driver.emit(at: 100 + Double(frame) / 120) }
    driver.emit(at: 100.101)

    #expect(updates == 12)
    #expect(motion.frames == to)
}

@MainActor @Test func cancellingDuringTheFinalPositionWriteCannotRunStaleCleanup() async throws {
    let motion = RibbonMotion()
    let start = ["a": CGRect(x: 0, y: 0, width: 900, height: 700)]
    let target = ["a": CGRect(x: 100, y: 0, width: 900, height: 700)]
    var completions = 0
    motion.animate(from: start, to: target,
                   configuration: RibbonAnimationConfiguration(
                    duration: 0,
                    curve: .smoother
                   ),
                   update: { _ in motion.cancel() }, completion: { completions += 1 })
    #expect(completions == 0)
    motion.animate(from: start, to: target,
                   configuration: RibbonAnimationConfiguration(
                    duration: 0.01,
                    curve: .smoother
                   ),
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

    writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in
            writeAttempts += 1
            return isAvailable
        }
    )

    #expect(writtenPositions.isEmpty)

    isAvailable = true
    writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in
            writeAttempts += 1
            return isAvailable
        }
    )

    #expect(writeAttempts == 2)
    #expect(writtenPositions["window"] == CGPoint(x: 100.5, y: 40.5))
}

@MainActor @Test func animationWritesDoNotFailWhenAReadableWindowRejectsTheMove() {
    let current = CGRect(x: 50, y: 40, width: 900, height: 700)
    let target = CGRect(x: 100, y: 40, width: 900, height: 700)
    var writtenPositions: [String: CGPoint] = [:]

    writeRibbonPositions(
        frames: ["window": target],
        writtenPositions: &writtenPositions,
        backingScaleFactor: 2,
        setPosition: { _, _ in false }
    )

    #expect(writtenPositions.isEmpty)
    _ = current
}

@MainActor @Test func commitAcceptsAnObservedDestinationDespiteSetterFailure() {
    let target = CGRect(x: 1800, y: 39, width: 723, height: 1130)
    var actual = CGRect(x: 0, y: 39, width: 723, height: 1130)

    let failures = commitRibbonPositions(
        frames: ["window": target],
        backingScaleFactor: 2,
        setPosition: { _, position in actual.origin = position; return false },
        observedFrame: { _ in actual }
    )

    #expect(failures.isEmpty)
}

@MainActor @Test func commitRejectsAStaleWindowDespiteSetterSuccess() throws {
    let target = CGRect(x: 1732.272972823002, y: 39, width: 1710, height: 1130)
    let clamped = CGRect(x: 1760, y: 39, width: 1710, height: 1130)

    let failure = try #require(commitRibbonPositions(
        frames: ["outgoing": target],
        backingScaleFactor: 2,
        setPosition: { _, _ in true },
        observedFrame: { _ in clamped }
    ).first)

    #expect(failure.windowID == "outgoing")
    #expect(failure.actualFrame == clamped)
}

@MainActor @Test func commitReportsAnUnavailableWindow() throws {
    let target = CGRect(x: 100, y: 39, width: 900, height: 700)

    let failure = try #require(commitRibbonPositions(
        frames: ["visible": target],
        backingScaleFactor: 2,
        setPosition: { _, _ in false },
        observedFrame: { _ in nil }
    ).first)

    #expect(failure.windowID == "visible")
    #expect(failure.actualFrame == nil)
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
