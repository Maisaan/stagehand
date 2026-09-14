import AppKit
import Testing
@testable import Stagehand

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
