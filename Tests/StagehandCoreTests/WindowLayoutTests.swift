import CoreGraphics
import Foundation
import Testing
@testable import StagehandCore

private let screen = CGRect(x: 100, y: 40, width: 1000, height: 700)

@Test func ribbonKeepsHeightStableAcrossFocusChanges() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c"])
    for maximize in [false, true] {
        state.maximizeWindows = maximize
        for focusedID in state.currentSpace.windowIDs {
            state.focus(windowID: focusedID)
            for placement in WindowLayout.placements(for: state, availableFrame: screen) {
                #expect(placement.frame.height == 700)
                #expect(placement.frame.midY == screen.midY)
            }
        }
    }
}

@Test func ribbonCentersActualAcceptedHeightsWithoutChangingWidthPreferences() throws {
    let state = WorkspaceState(spaces: [SpaceState(
        windowIDs: ["a", "b", "c"], focusedWindowID: "b",
        widthFractions: ["a": 0.3, "b": 0.5, "c": 0.4]
    )])
    let placements = WindowLayout.placements(for: state, availableFrame: screen,
                                            observedHeights: ["a": 680, "b": 500, "c": 800])
    #expect(placements.map(\.frame.height) == [680, 500, 800])
    #expect(placements.allSatisfy { $0.frame.midY == screen.midY })
    #expect(placements.map(\.frame.width) == [300, 500, 400])
    #expect(state.currentSpace.widthFractions == ["a": 0.3, "b": 0.5, "c": 0.4])
}

@Test func resizedHeightsStayCenteredAcrossFocusAndMaximizeChanges() throws {
    var state = WorkspaceState(spaces: [SpaceState(
        windowIDs: ["editor", "settings"], focusedWindowID: "editor",
        widthFractions: ["editor": 0.8, "settings": 0.5]
    )])
    var preferredHeights: [String: CGFloat] = ["editor": 560, "settings": 480]
    for maximize in [false, true, false] {
        state.maximizeWindows = maximize
        for focusedID in ["settings", "editor"] {
            state.focus(windowID: focusedID)
            let placements = WindowLayout.placements(for: state, availableFrame: screen,
                                                    preferredHeights: preferredHeights)
            for placement in placements {
                #expect(placement.frame.height == (maximize ? screen.height : preferredHeights[placement.windowID]))
                #expect(placement.frame.midY == screen.midY)
            }
            let editor = try #require(placements.first { $0.windowID == "editor" })
            #expect(editor.frame.width == (maximize ? 1000 : 800))
        }
        // A manual vertical resize becomes the height supplied on the next layout.
        if !maximize { preferredHeights["editor"] = 420 }
    }
}

@Test func maximizingRequestsFullHeightWithoutOverwritingPreferredHeightOrAppLimits() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a"])
    let preferredHeights: [String: CGFloat] = ["a": 420]
    state.maximizeWindows = true
    let maximized = try #require(WindowLayout.placements(for: state, availableFrame: screen,
                                                        preferredHeights: preferredHeights).first)
    #expect(maximized.frame.height == screen.height)
    let constrained = try #require(WindowLayout.placements(for: state, availableFrame: screen,
                                                          preferredHeights: preferredHeights,
                                                          observedHeights: ["a": 500]).first)
    #expect(constrained.frame.height == 500)
    #expect(constrained.frame.midY == screen.midY)
    state.maximizeWindows = false
    let restored = try #require(WindowLayout.placements(for: state, availableFrame: screen,
                                                       preferredHeights: preferredHeights).first)
    #expect(restored.frame.height == 420)
    #expect(restored.frame.midY == screen.midY)
}

@Test func ribbonIgnoresInvalidAcceptedHeights() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c", "d"])
    let expected = WindowLayout.placements(for: state, availableFrame: screen)
    let actual = WindowLayout.placements(for: state, availableFrame: screen,
                                        observedHeights: ["a": .nan, "b": .infinity, "c": 0, "d": -1])
    #expect(actual == expected)
}

@Test func scrollingPacksAnAppConstrainedToItsObservedWidth() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["editor", "settings"])
    state.focus(windowID: "settings")
    let display = CGRect(x: 0, y: 39, width: 1800, height: 1130)
    // Live System Settings reproduction: requested 1710 pt, accepted 723 pt.
    let placements = WindowLayout.placements(for: state, availableFrame: display,
                                            observedWidths: ["settings": 723])
    let settings = try #require(placements.first { $0.windowID == "settings" })
    let editor = try #require(placements.first { $0.windowID == "editor" })
    #expect(settings.frame.width == 723)
    #expect(settings.frame.maxX == display.maxX)
    #expect(settings.frame.minX - editor.frame.maxX == 8)
    #expect(display.contains(settings.frame))
}

@Test func scrollingAcceptsAnAppMinimumWiderThanTheRequestedWidth() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["store"])
    let display = CGRect(x: 0, y: 39, width: 1800, height: 1130)
    // Live App Store reproduction: requested 1710 pt, accepted 1720 pt for every pass.
    let placement = try #require(WindowLayout.placements(
        for: state,
        availableFrame: display,
        observedWidths: ["store": 1720]
    ).first)

    #expect(placement.frame.width == 1720)
}

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

@Test func ribbonUsesRememberedWidthsAfterMaximizeIsTurnedOff() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b"])
    state.setWidthFraction(0.5, for: "b")
    state.maximizeWindows = true
    state.maximizeWindows = false
    #expect(state.currentSpace.widthFraction(for: "b") == 0.5)
    state.focus(windowID: "b")
    let scrolling = WindowLayout.placements(for: state, availableFrame: screen)
    #expect(scrolling.first { $0.isFocused }?.frame.width == 500)
    #expect(scrolling.allSatisfy { $0.isVisible })
}

@Test func ribbonIgnoresInvalidObservedWidths() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c", "d"])
    let expected = WindowLayout.placements(for: state, availableFrame: screen)
    let actual = WindowLayout.placements(for: state, availableFrame: screen,
                                        observedWidths: ["a": .nan, "b": .infinity, "c": 0, "d": -1])
    #expect(actual == expected)
}

@Test func scrollingUsesAnOversizedWidthAcceptedByTheApp() throws {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a"])
    let placement = try #require(WindowLayout.placements(
        for: state,
        availableFrame: screen,
        observedWidths: ["a": screen.width * 1.2]
    ).first)
    #expect(placement.frame.width == screen.width * 1.2)
}

@Test func negativeGapCentersTheFocusedWindowAndOverlapsBothNeighbors() throws {
    let display = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let state = WorkspaceState(spaces: [SpaceState(
        windowIDs: ["a", "b", "c"], focusedWindowID: "b",
        widthFractions: ["a": 0.6, "b": 0.6, "c": 0.6]
    )])
    let placements = WindowLayout.placements(for: state, availableFrame: display, gap: -100)
    let focused = try #require(placements.first { $0.isFocused })
    #expect(focused.frame.minX == 200)
    #expect(focused.frame.width == 600)
    #expect(placements[0].frame.intersection(focused.frame).width == 100)
    #expect(placements[2].frame.intersection(focused.frame).width == 100)
    #expect(placements[0].frame.minX < focused.frame.minX)
    #expect(placements[2].frame.maxX > focused.frame.maxX)
    #expect(placements.allSatisfy { $0.isVisible })
}

@Test func extremeNegativeGapKeepsRibbonOrderAndFiniteFrames() {
    var state = WorkspaceState()
    state.reconcile(windowIDs: ["a", "b", "c"])
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: -.greatestFiniteMagnitude)
    #expect(placements[1].frame.minX - placements[0].frame.minX == 1)
    #expect(placements[2].frame.minX - placements[1].frame.minX == 1)
    #expect(placements.allSatisfy { $0.frame.minX.isFinite && $0.frame.width.isFinite })
}

@Test func overlappingRibbonExtentIncludesEarlierWiderWindows() {
    let state = WorkspaceState(spaces: [SpaceState(
        windowIDs: ["a", "b", "c"], focusedWindowID: "c",
        widthFractions: ["a": 0.95, "b": 0.25, "c": 0.25]
    )])
    let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: -800)
    // The widest first window extends beyond the last window. The whole ribbon fits,
    // so focusing the last window must not introduce an unnecessary offset.
    #expect(placements[0].frame.minX == screen.minX)
    #expect(placements[1].frame.minX == screen.minX + 150)
    #expect(placements[2].frame.minX == screen.minX + 151)
}

@Test func maximizeFillsTheViewportWithoutReservingNeighborStrips() throws {
    var state = WorkspaceState(maximizeWindows: true, spaces: [SpaceState(
        windowIDs: ["a", "b", "c"], focusedWindowID: "b",
        widthFractions: ["a": 0.4, "b": 0.6, "c": 0.8]
    )])
    for gap in [CGFloat(-100), 0, 8] {
        let placements = WindowLayout.placements(for: state, availableFrame: screen, gap: gap)
        let focused = try #require(placements.first { $0.isFocused })
        #expect(focused.frame == screen)
        #expect(placements.allSatisfy { $0.frame.width == screen.width })
    }
    #expect(state.currentSpace.widthFraction(for: "b") == 0.6)
    state.maximizeWindows = false
    let restored = WindowLayout.placements(for: state, availableFrame: screen)
    #expect(restored.first { $0.isFocused }?.frame.width == 600)
}

@Test func maximizeStillUsesAnAppsObservedWidthConstraint() throws {
    var state = WorkspaceState(maximizeWindows: true)
    state.reconcile(windowIDs: ["editor", "settings"])
    let placements = WindowLayout.placements(for: state, availableFrame: screen,
                                            observedWidths: ["settings": 520])
    let focused = try #require(placements.first { $0.isFocused })
    #expect(focused.frame.width == 520)
    #expect(focused.frame.maxX == screen.maxX)
    #expect(placements[0].frame.width == screen.width)
    #expect(focused.frame.minX - placements[0].frame.maxX == 0)
}

@Test func maximizingIgnoresSavedGapUntilResizableWidthsReturn() {
    var state = WorkspaceState(maximizeWindows: true,
                               spaces: [SpaceState(windowIDs: ["a", "b", "c"], focusedWindowID: "b")])
    let touching = WindowLayout.placements(for: state, availableFrame: screen, gap: 0)
    for gap in [CGFloat(-200), -55, 8, 40] {
        #expect(WindowLayout.placements(for: state, availableFrame: screen, gap: gap) == touching)
    }
    state.maximizeWindows = false
    let overlapping = WindowLayout.placements(for: state, availableFrame: screen, gap: -55)
    #expect(overlapping[1].frame.minX - overlapping[0].frame.maxX == -55)
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
