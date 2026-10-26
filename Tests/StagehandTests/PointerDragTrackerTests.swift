import Testing
@testable import Stagehand

/// A drag session started during a press makes it a drag-and-drop until release.
@MainActor
@Test func aPressBecomesADragAndDropWhenADragSessionStarts() {
    let pointer = FakePointer()
    pointer.buttonDown = true
    pointer.tracker.pressBegan(inStagehand: false)
    #expect(!pointer.tracker.isDragAndDrop)
    pointer.dragChangeCount += 1
    #expect(pointer.tracker.isDragAndDrop)
    #expect(pointer.tracker.isDragAndDrop)

    pointer.tracker.pressEnded()
    #expect(!pointer.tracker.isDragAndDrop)
    // The next press, a title-bar drag, starts from the new count.
    pointer.tracker.pressBegan(inStagehand: false)
    #expect(!pointer.tracker.isDragAndDrop)
}

/// A press Stagehand did not see begin, or one that began in its own windows, is never
/// a drag-and-drop, so a missed event cannot make a window drag look like one.
@MainActor
@Test func anUnseenOrOwnPressIsNotADragAndDrop() {
    let pointer = FakePointer()
    pointer.buttonDown = true
    pointer.dragChangeCount += 1
    #expect(!pointer.tracker.isDragAndDrop)

    pointer.tracker.pressBegan(inStagehand: true)
    pointer.dragChangeCount += 1
    #expect(!pointer.tracker.isDragAndDrop)
}

/// A missed release: finding the button up ends the press, so the old count is not
/// compared against the next press.
@MainActor
@Test func findingTheButtonUpEndsThePress() {
    let pointer = FakePointer()
    pointer.buttonDown = true
    pointer.tracker.pressBegan(inStagehand: false)
    pointer.dragChangeCount += 1
    #expect(pointer.tracker.isDragAndDrop)

    pointer.buttonDown = false
    #expect(!pointer.tracker.isDragAndDrop)
    pointer.buttonDown = true
    #expect(!pointer.tracker.isDragAndDrop)
}

/// Whether macOS kept moving the pointer while a drag was carried: the longest gap
/// between drag events, including the one before the drop, and how far the held finger
/// moved during it.
@MainActor
@Test func aDragAndDropReportsItsLongestPointerGapAndTheHeldFingerTravel() {
    var buttonDown = true, count = 10, time = 100.0, travel = 0.0
    var reports: [[String: String]] = []
    let tracker = PointerDragTracker(buttonDown: { buttonDown }, dragChangeCount: { count },
                                     now: { time }, heldClickTravel: { travel }, dockEventsWithheld: { 7 })
    tracker.onDragAndDropEnded = { reports.append($0) }
    tracker.pressBegan(inStagehand: false)
    count += 1
    #expect(tracker.isDragAndDrop)
    for _ in 0..<3 {
        time += 0.01
        travel += 0.002
        tracker.pointerDragged()
    }
    // The pointer stops while the held finger keeps moving, until the drop.
    time += 1.5
    travel += 0.25
    tracker.pressEnded()
    buttonDown = false
    #expect(reports.count == 1)
    #expect(reports.first?["pointerDragEvents"] == "3")
    #expect(reports.first?["longestPointerGapMilliseconds"] == "1500")
    #expect(reports.first?["heldFingerTravelDuringGap"] == "250")
    #expect(reports.first?["dockControlEventsWithheld"] == "0")

    // A press that never carried a drag-and-drop reports nothing.
    tracker.pressBegan(inStagehand: false)
    tracker.pressEnded()
    #expect(reports.count == 1)
}
