import CoreGraphics
import Testing
@testable import StagehandCore

private let viewport = CGRect(x: 0, y: 40, width: 1_000, height: 700)

@Test func acceptedAppSizesRepackTheRibbonAndStayCentered() throws {
    let state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b"], focusedWindowID: "b")
    ])
    let placements = WindowLayout.placements(
        for: state,
        availableFrame: viewport,
        gap: 10,
        observedWidths: ["a": 420, "b": 1_100],
        preferredHeights: ["a": 500, "b": 600],
        observedHeights: ["a": 480, "b": 620]
    )
    let first = try #require(placements.first { $0.windowID == "a" })
    let focused = try #require(placements.first { $0.windowID == "b" })
    #expect(first.frame.width == 420)
    #expect(focused.frame.width == 1_100)
    #expect(first.frame.maxX + 10 == focused.frame.minX)
    #expect(first.frame.midY == viewport.midY)
    #expect(focused.frame.midY == viewport.midY)
}

@Test func scrollingKeepsFocusVisibleAndRetainsIndividualWidths() throws {
    let state = WorkspaceState(spaces: [
        SpaceState(
            windowIDs: ["a", "b", "c"],
            focusedWindowID: "b",
            widthFractions: ["a": 0.25, "b": 0.8, "c": 1]
        )
    ])
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: 8)
    let first = try #require(placements.first { $0.windowID == "a" })
    let focused = try #require(placements.first { $0.windowID == "b" })
    let last = try #require(placements.first { $0.windowID == "c" })
    #expect(first.frame.width == 250)
    #expect(focused.frame.width == 800)
    #expect(last.frame.width == 1_000)
    #expect(focused.frame.minX >= viewport.minX)
    #expect(focused.frame.maxX <= viewport.maxX)
}

@Test func observedWidthsOverrideRequestsButMalformedValuesDoNot() throws {
    let state = WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")])
    for (observed, expected) in [(CGFloat(300), CGFloat(300)), (.nan, 950), (-1, 950)] {
        let placement = try #require(WindowLayout.placements(
            for: state,
            availableFrame: viewport,
            observedWidths: ["a": observed]
        ).first)
        #expect(placement.frame.width == expected)
    }
}

@Test func negativeGapCentersFocusAndPreservesRibbonOrder() throws {
    let state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "b")
    ])
    let placements = WindowLayout.placements(for: state, availableFrame: viewport, gap: -200)
    let first = try #require(placements.first { $0.windowID == "a" })
    let focused = try #require(placements.first { $0.windowID == "b" })
    let last = try #require(placements.first { $0.windowID == "c" })
    #expect(abs(focused.frame.midX - viewport.midX) < 0.001)
    #expect(first.frame.minX < focused.frame.minX)
    #expect(focused.frame.minX < last.frame.minX)
    #expect(first.frame.intersects(focused.frame))
    #expect(focused.frame.intersects(last.frame))
}

@Test func invalidOrEmptyAvailableFramesProduceNoPlacements() {
    let populated = WorkspaceState(spaces: [SpaceState(windowIDs: ["a"], focusedWindowID: "a")])
    #expect(WindowLayout.placements(for: WorkspaceState(), availableFrame: viewport).isEmpty)
    #expect(WindowLayout.placements(for: populated, availableFrame: .zero).isEmpty)
    #expect(WindowLayout.placements(
        for: populated,
        availableFrame: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)
    ).isEmpty)
}
