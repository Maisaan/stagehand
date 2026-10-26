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
