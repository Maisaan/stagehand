import CoreGraphics
import Foundation
import StagehandCore
import Testing
@testable import Stagehand
@testable import StagehandPlatform

/// A relaunched app (an update, a crash restart, a quit and reopen) used to join
/// the active space after the focused window, losing the place it had.
struct RelaunchPlacesTests {
    private func record(_ id: String, app: String, pid: Int32, title: String = "") -> WindowRecord {
        WindowRecord(id: id, appName: app, title: title, bundleIdentifier: "test.\(app)", pid: pid,
                     frame: CGRect(x: 0, y: 0, width: 100, height: 100), isResizable: true)
    }

    private let start = Date(timeIntervalSince1970: 1_000)

    /// Removes the windows as the ribbon does, recording them first.
    private func quit(_ records: [WindowRecord], pid: Int32, windows: inout [WindowRecord],
                      state: inout WorkspaceState, restoration: inout WorkspaceRestoration,
                      places: inout RelaunchPlaces, heights: [String: CGFloat] = [:], at time: Date) {
        for window in records {
            let before = state
            _ = removeDestroyedWindow(windowID: window.id, windows: &windows, state: &state,
                                      restoration: &restoration,
                                      trackedWindowIDs: Set(windows.map(\.id)).subtracting([window.id]))
            places.windowsLeft([window], layout: before, preferredHeights: heights, at: time)
        }
        places.applicationTerminated(pid: pid, at: time)
    }

    @Test func relaunchedWindowReturnsBetweenItsNeighbors() {
        let left = record("left", app: "left", pid: 1)
        let gone = record("old", app: "updated", pid: 2)
        let right = record("right", app: "right", pid: 3)
        var windows = [left, gone, right]
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["left", "old", "right"], focusedWindowID: "old",
                       widthFractions: ["old": 0.5])
        ])
        var restoration = WorkspaceRestoration()
        var places = RelaunchPlaces()
        quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration,
             places: &places, heights: ["old": 600], at: start)
        state.focus(windowID: "right")

        let relaunched = record("new", app: "updated", pid: 20)
        let placements = places.place(windows + [relaunched], state: &state, restoration: &restoration,
                                      at: start.addingTimeInterval(5))

        #expect(placements.map(\.windowID) == ["new"])
        #expect(placements.first?.preferredHeight == 600)
        #expect(state.currentSpace.windowIDs == ["left", "new", "right"])
        #expect(state.currentSpace.widthFraction(for: "new") == 0.5)
        #expect(places.rememberedBundleIdentifiers.isEmpty)
    }

    /// The app was alone in space 2, which closed when it quit; the space reopens
    /// between its old neighbors and the later space moves back up.
    @Test func relaunchReopensTheSpaceItsAppLeftEmpty() {
        let first = record("first", app: "first", pid: 1)
        let gone = record("old", app: "updated", pid: 2)
        let third = record("third", app: "third", pid: 3)
        var windows = [first, gone, third]
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["first"]),
            SpaceState(windowIDs: ["old"]),
            SpaceState(windowIDs: ["third"])
        ], activeSpaceIndex: 2)
        var restoration = WorkspaceRestoration()
        var places = RelaunchPlaces()
        quit([gone], pid: 2, windows: &windows, state: &state, restoration: &restoration,
             places: &places, at: start)
        #expect(state.spaces[1].windowIDs == ["third"])
        #expect(state.activeSpaceIndex == 1)

        let placements = places.place(windows + [record("new", app: "updated", pid: 20)], state: &state,
                                      restoration: &restoration, at: start.addingTimeInterval(5))

        #expect(placements.first?.openedSpaceIndices == [1])
        #expect(state.spaces.prefix(3).map(\.windowIDs) == [["first"], ["new"], ["third"]])
        #expect(state.activeSpaceIndex == 2)
    }

    /// Windows of one app return to their own places, matched by title, even when
    /// they were neighbors and come back in another order.
    @Test func severalWindowsReturnToTheirOwnPlacesByTitle() {
        let other = record("other", app: "other", pid: 1)
        let mail = record("mail", app: "browser", pid: 2, title: "Mail")
        let docs = record("docs", app: "browser", pid: 2, title: "Docs")
        var windows = [mail, other, docs]
        var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["mail", "docs", "other"])])
        var restoration = WorkspaceRestoration()
        var places = RelaunchPlaces()
        quit([mail, docs], pid: 2, windows: &windows, state: &state, restoration: &restoration,
             places: &places, at: start)
        #expect(state.currentSpace.windowIDs == ["other"])

        let restored = [record("docs2", app: "browser", pid: 20, title: "Docs"),
                        record("mail2", app: "browser", pid: 20, title: "Mail")]
        _ = places.place(windows + restored, state: &state, restoration: &restoration,
                         at: start.addingTimeInterval(5))

        #expect(state.currentSpace.windowIDs == ["mail2", "docs2", "other"])
    }

    /// A window closed long before its app quit is not reopened by the relaunch,
    /// and a window the relaunched app opens well after the others takes the
    /// usual placement.
    @Test func onlyWindowsClosedByTheQuitAndClaimedPromptlyReturn() {
        let other = record("other", app: "other", pid: 1)
        let early = record("early", app: "browser", pid: 2)
        let late = record("late", app: "browser", pid: 2)
        var windows = [early, other, late]
        var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["early", "other", "late"])])
        var restoration = WorkspaceRestoration()
        var places = RelaunchPlaces()
        let before = state
        _ = removeDestroyedWindow(windowID: "early", windows: &windows, state: &state,
                                  restoration: &restoration, trackedWindowIDs: ["other", "late"])
        places.windowsLeft([early], layout: before, preferredHeights: [:], at: start)
        let quitTime = start.addingTimeInterval(RelaunchPlaces.quitInterval + 1)
        quit([late], pid: 2, windows: &windows, state: &state, restoration: &restoration,
             places: &places, at: quitTime)

        let first = record("first", app: "browser", pid: 20)
        _ = places.place(windows + [first], state: &state, restoration: &restoration,
                         at: quitTime.addingTimeInterval(1))
        #expect(state.currentSpace.windowIDs == ["other", "first"])
        #expect(places.rememberedBundleIdentifiers.isEmpty)
    }

    @Test func leftoverPlacesExpireAfterTheRelaunchBurst() {
        let other = record("other", app: "other", pid: 1)
        let one = record("one", app: "browser", pid: 2)
        let two = record("two", app: "browser", pid: 2)
        var windows = [one, two, other]
        var state = WorkspaceState(spaces: [SpaceState(windowIDs: ["one", "two", "other"])])
        var restoration = WorkspaceRestoration()
        var places = RelaunchPlaces()
        quit([one, two], pid: 2, windows: &windows, state: &state, restoration: &restoration,
             places: &places, at: start)

        let back = record("back", app: "browser", pid: 20)
        _ = places.place(windows + [back], state: &state, restoration: &restoration,
                         at: start.addingTimeInterval(1))
        #expect(places.rememberedBundleIdentifiers == ["test.browser"])
        let later = record("later", app: "browser", pid: 20)
        let placements = places.place(windows + [back, later], state: &state, restoration: &restoration,
                                      at: start.addingTimeInterval(2 + RelaunchPlaces.claimInterval))
        #expect(placements.isEmpty)
        #expect(places.rememberedBundleIdentifiers.isEmpty)
    }

    @Test func openingASpaceKeepsRememberedMembershipsAligned() {
        var state = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["a"]), SpaceState(windowIDs: ["b", "minimized"])
        ])
        var restoration = WorkspaceRestoration()
        restoration.reconcile(state: &state, windowIDs: ["a", "b"], trackedWindowIDs: ["a", "b", "minimized"])
        #expect(restoration.openSpace(state: &state, at: 1))
        #expect(state.spaces[1].windowIDs.isEmpty)
        restoration.reconcile(state: &state, windowIDs: ["a", "b", "minimized"],
                              trackedWindowIDs: ["a", "b", "minimized"])
        #expect(state.spaces[2].windowIDs == ["b", "minimized"])
    }
}
