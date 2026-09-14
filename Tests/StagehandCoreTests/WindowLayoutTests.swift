import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

private let screen = CGRect(x: 100, y: 40, width: 1000, height: 700)

@Test func scrollingShowsNextSliverAndKeepsFocusedWindowFullyVisible() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c"])
    for windowID in state.currentSpace.windowIDs {
        state.focus(windowID: windowID)
        let placements = WindowLayout.placements(for: state, availableFrame: screen)
        let active = try #require(placements.first { $0.isFocused })
        #expect(screen.contains(active.frame))
        #expect(active.frame.width == 950)
        #expect(active.frame.height == 700)
        #expect(active.frame.minY == 40)
        #expect(placements.filter(\.isVisible).count == 2)
    }
    state.focus(windowID: "a")
    let placements = WindowLayout.placements(for: state, availableFrame: screen)
    #expect(placements[0].frame == CGRect(x: 100, y: 40, width: 950, height: 700))
    #expect(placements[1].frame.intersection(screen).width == 42)
    #expect(!placements[2].isVisible)
}

@Test func scrollingUsesIndividualWidthsAndDoesNotScrollShortRibbon() {
    let state = WorkspaceState(spaces: [SpaceState(
        windowIDs: ["a", "b"], focusedWindowID: "b", widthFractions: ["a": 0.25, "b": 0.4]
    )])
    let placements = WindowLayout.placements(for: state, availableFrame: screen)
    #expect(placements[0].frame.minX == screen.minX)
    #expect(placements[0].frame.width == 250)
    #expect(placements[1].frame.width == 400)
    #expect(placements[1].frame.minX - placements[0].frame.maxX == 8)
    #expect(placements.allSatisfy { $0.isVisible })
}

@Test func monocleFillsScreenAndParksOtherWindowsWithoutChangingWidths() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b"])
    state.setWidthFraction(0.5, for: "b")
    state.layoutMode = .monocle
    let placements = WindowLayout.placements(for: state, availableFrame: screen)
    let focused = try #require(placements.first { $0.isFocused })
    let parked = try #require(placements.first { !$0.isFocused })
    #expect(focused.frame == screen)
    #expect(focused.isVisible)
    #expect(!parked.frame.intersects(screen))
    #expect(!parked.isVisible)
    #expect(state.currentSpace.widthFraction(for: "b") == 0.5)
    state.layoutMode = .scrolling
    let scrolling = WindowLayout.placements(for: state, availableFrame: screen)
    #expect(scrolling.first { $0.isFocused }?.frame.width == 500)
}

@Test func layoutHandlesEmptySpacesAndInvalidFrames() {
    var state = WorkspaceState()
    #expect(WindowLayout.placements(for: state, availableFrame: screen).isEmpty)
    state.reconcile(windowIDs: ["a"])
    #expect(WindowLayout.placements(for: state, availableFrame: .zero).isEmpty)
    #expect(WindowLayout.placements(for: state, availableFrame: .infinite).isEmpty)
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: -.infinity)
    #expect(placements.count == 1)
    #expect(placements[0].frame.minX == screen.minX)
}
