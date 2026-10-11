import Testing
@testable import StagehandCore

@Test func wholeMillisecondsTruncatesSubMillisecondRemainders() {
    #expect(Duration.milliseconds(0).wholeMilliseconds == 0)
    #expect(Duration.milliseconds(1_234).wholeMilliseconds == 1_234)
    #expect(Duration.microseconds(1_999).wholeMilliseconds == 1)
    #expect((Duration.seconds(2) + .milliseconds(5)).wholeMilliseconds == 2_005)
}
