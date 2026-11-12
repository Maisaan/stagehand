import Testing
@testable import Stagehand
@testable import StagehandPlatform

@MainActor
@Test func mainThreadActivityNamesTheOutermostAndInnermostCall() {
    MainThreadActivity.setEnabled(true)
    defer { MainThreadActivity.setEnabled(false) }
    #expect(MainThreadActivity.current == nil)
    MainThreadActivity.during("axCallback AXMoved pid=644") {
        #expect(MainThreadActivity.current == "axCallback AXMoved pid=644")
        MainThreadActivity.during("observe AXMoved pid=644") {}
        MainThreadActivity.during("read AXPosition,AXSize pid=644") {
            #expect(MainThreadActivity.current == "axCallback AXMoved pid=644 > read AXPosition,AXSize pid=644")
        }
    }
    #expect(MainThreadActivity.current == nil)
}

/// A frame write's readback inside a layout names the layout step, the readback and the AX call.
@MainActor
@Test func mainThreadActivityKeepsTheCallerOfTheInnermostCall() {
    MainThreadActivity.setEnabled(true)
    defer { MainThreadActivity.setEnabled(false) }
    MainThreadActivity.during("layout frame write") {
        MainThreadActivity.during("frame write readback") {
            MainThreadActivity.during("read AXPosition,AXSize pid=644") {
                #expect(MainThreadActivity.current
                    == "layout frame write > frame write readback > read AXPosition,AXSize pid=644")
                MainThreadActivity.during("deeper") {
                    #expect(MainThreadActivity.current == "layout frame write > read AXPosition,AXSize pid=644 > deeper")
                }
            }
        }
    }
}

@MainActor
@Test func mainThreadActivityBuildsNoLabelWhileDisabled() {
    MainThreadActivity.setEnabled(false)
    var built = false
    let result = MainThreadActivity.during({ built = true; return "unused" }()) { 7 }
    #expect(result == 7)
    #expect(!built)
}

@Test func stallSummaryListsTheMostSampledLabelsFirst() {
    #expect(MainThreadWatchdog.summary([:]) == "none")
    #expect(MainThreadWatchdog.summary(["unlabeled": 1, "observe AXWindowCreated pid=1": 9, "windowList": 1, "b": 1])
        == "observe AXWindowCreated pid=1 x9, b x1, unlabeled x1")
}

/// change_completed reports how many labeled reads and writes to other apps a change
/// made on the main thread; other labels do not count.
@MainActor
@Test func mainThreadActivityCountsCallsToOtherApps() {
    MainThreadActivity.setEnabled(true)
    defer { MainThreadActivity.setEnabled(false) }
    _ = MainThreadActivity.takeAppCallCount()
    MainThreadActivity.during("read AXPosition,AXSize pid=1") {}
    MainThreadActivity.during("write position pid=1") {}
    MainThreadActivity.during("hudWindow setFrame") {}
    #expect(MainThreadActivity.takeAppCallCount() == 2)
    #expect(MainThreadActivity.takeAppCallCount() == 0)
}
