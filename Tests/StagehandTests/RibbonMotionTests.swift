import AppKit
import Testing
import StagehandCore
@testable import Stagehand

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

@MainActor @Test func swipePreviewTracksLinearlyWithoutResizingAndResistsOnlyAtRibbonEnds() throws {
    let viewport = CGRect(x: 0, y: 40, width: 1000, height: 700)
    let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "b")])
    let base = Dictionary(uniqueKeysWithValues: WindowLayout.placements(for: state, availableFrame: viewport,
                                                                       gap: -55, observedHeights: ["a": 400, "b": 600, "c": 500]).map { ($0.windowID, $0.frame) })
    for direction in [-1.0, 1] {
        let full = RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: -55, displacement: direction * 0.25)
        let half = RibbonMotion.dragFrames(state: state, from: base, availableFrame: viewport, gap: -55, displacement: direction * 0.125)
        for (id, start) in base {
            let frame = try #require(half[id])
            #expect(frame.size == start.size)
            #expect(frame.minY == start.minY)
            #expect(frame.minX == (start.minX + (try #require(full[id])).minX) / 2)
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
