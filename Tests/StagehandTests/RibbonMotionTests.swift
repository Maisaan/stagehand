import AppKit
import StagehandCore
import Testing
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

@MainActor @Test func gesturePreviewAndCommitUseTheAdjacentWindow() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1_000, height: 700)
    let state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "a")
    ])
    let widths = ["a": CGFloat(700), "b": 950, "c": 950]
    let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
        for: state,
        availableFrame: viewport,
        observedWidths: widths
    ).map { ($0.windowID, $0.frame) })
    var destinationState = state
    let changed = destinationState.apply(.focusNext)
    #expect(changed)
    let destination = Dictionary(uniqueKeysWithValues: WindowLayout.placements(
        for: destinationState,
        availableFrame: viewport,
        observedWidths: widths
    ).map { ($0.windowID, $0.frame) })

    #expect(RibbonMotion.dragFrames(
        state: state,
        from: base,
        availableFrame: viewport,
        gap: 8,
        displacement: -0.25
    ) == destination)
    #expect(RibbonMotion.horizontalCompletionAction(
        state: state,
        from: base,
        availableFrame: viewport,
        gap: 8,
        displacement: -0.01,
        velocity: 0
    ) == nil)
    #expect(RibbonMotion.horizontalCompletionAction(
        state: state,
        from: base,
        availableFrame: viewport,
        gap: 8,
        displacement: -0.03,
        velocity: -0.6
    ) == .focusNext)
}

@MainActor @Test func interpolationMovesPositionWithoutInventingGeometry() throws {
    let from = ["a": CGRect(x: 500, y: 10, width: 800, height: 500)]
    let to = ["a": CGRect(x: 0, y: 40, width: 900, height: 700)]
    #expect(RibbonMotion.interpolate(from: from, to: to, progress: 0) == [
        "a": CGRect(x: 500, y: 40, width: 900, height: 700)
    ])
    #expect(RibbonMotion.interpolate(from: from, to: to, progress: 1) == to)
    let middle = try #require(RibbonMotion.interpolate(
        from: from,
        to: to,
        progress: 0.5,
        curve: .linear
    )["a"])
    #expect(middle == CGRect(x: 250, y: 40, width: 900, height: 700))
}

@MainActor @Test func retargetingCancelsTheOldAnimationAndCompletesTheNewOne() {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 0 })
    var events: [String] = []
    motion.animate(
        from: ["a": CGRect(x: 0, y: 0, width: 10, height: 10)],
        to: ["a": CGRect(x: 100, y: 0, width: 10, height: 10)],
        configuration: .init(duration: 1, curve: .linear),
        update: { _ in },
        cancellation: { events.append("cancelled") },
        completion: { events.append("old completed") }
    )
    motion.animate(
        from: motion.frames,
        to: ["a": CGRect(x: -100, y: 0, width: 10, height: 10)],
        configuration: .init(duration: 1, curve: .linear),
        update: { _ in },
        completion: { events.append("completed") }
    )
    driver.emit(at: 1)
    #expect(events == ["cancelled", "completed"])
    #expect(motion.frames["a"]?.minX == -100)
}

@MainActor @Test func gestureFramesCoalesceToOneWritePerDisplayRefresh() {
    let driver = TestRibbonFrameDriver()
    let motion = RibbonMotion(frameDriver: driver, currentTime: { 0 })
    var latest = ["a": CGRect(x: 0, y: 0, width: 10, height: 10)]
    var updates: [[String: CGRect]] = []
    motion.follow(frames: { latest }, update: { updates.append($0) })
    latest["a"]?.origin.x = 10
    latest["a"]?.origin.x = 20
    #expect(updates.isEmpty)
    driver.emit(at: 1)
    #expect(updates == [latest])
    #expect(driver.startCount == 1)
}

@MainActor @Test func animationWritesRetryButCommitTrustsObservedPosition() {
    let target = CGRect(x: 100, y: 20, width: 300, height: 200)
    var written: [String: CGPoint] = [:]
    writeRibbonPositions(
        frames: ["a": target],
        writtenPositions: &written,
        backingScaleFactor: 2,
        setPosition: { _, _ in false }
    )
    #expect(written.isEmpty)

    let acceptedDespiteSetter = commitRibbonPositions(
        frames: ["a": target],
        backingScaleFactor: 2,
        setPosition: { _, _ in false },
        observedFrame: { _ in target }
    )
    #expect(acceptedDespiteSetter.isEmpty)

    let rejectedDespiteSetter = commitRibbonPositions(
        frames: ["a": target],
        backingScaleFactor: 2,
        setPosition: { _, _ in true },
        observedFrame: { _ in target.offsetBy(dx: -20, dy: 0) }
    )
    #expect(rejectedDespiteSetter.map(\.windowID) == ["a"])
}

@MainActor @Test func unavailableParkingDefersButReadableFailureStops() {
    #expect(parkWindow(windowID: "a", park: { _ in true }, observedFrame: { _ in nil }) == .parked)
    #expect(parkWindow(windowID: "a", park: { _ in false }, observedFrame: { _ in nil }) == .deferred)
    #expect(parkWindow(
        windowID: "a",
        park: { _ in false },
        observedFrame: { _ in CGRect(x: 0, y: 0, width: 10, height: 10) }
    ) == .failed)
}

@MainActor @Test func focusFirstNavigationCommitsInputOnlyAfterTranslation() async {
    var events: [String] = []
    let outcome = await runFocusFirstNavigation(
        translate: {
            events.append("translate")
            return .readyForFocus
        },
        focus: {
            events.append("focus")
            return true
        },
        focusConfirmed: { events.append("confirmed") },
        commitInput: { events.append("commit") },
        revealBorder: { events.append("border") }
    )
    #expect(outcome == .completed)
    #expect(events == ["border", "focus", "confirmed", "translate", "commit"])
}

@MainActor @Test func failedFocusDoesNotTranslateOrCommitInput() async {
    var translated = false
    var committed = false
    let outcome = await runFocusFirstNavigation(
        translate: {
            translated = true
            return .readyForFocus
        },
        focus: { false },
        focusConfirmed: {},
        commitInput: { committed = true },
        revealBorder: {}
    )
    #expect(outcome == .failed)
    #expect(!translated)
    #expect(!committed)
}
