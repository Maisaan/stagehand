import CoreGraphics
import Testing
@testable import Stagehand

@Test func heightShortcutsMoveByFivePercentAndClamp() {
    #expect(adjustedWindowHeight(current: 500, available: 1_000, growing: true) == 550)
    #expect(adjustedWindowHeight(current: 500, available: 1_000, growing: false) == 450)
    #expect(adjustedWindowHeight(current: 980, available: 1_000, growing: true) == 1_000)
    #expect(adjustedWindowHeight(current: 270, available: 1_000, growing: false) == 250)
    #expect(adjustedWindowHeight(current: 1_000, available: 1_000, growing: true) == nil)
    #expect(adjustedWindowHeight(current: 250, available: 1_000, growing: false) == nil)
}

@Test func heightShortcutsRejectInvalidGeometry() {
    #expect(adjustedWindowHeight(current: .nan, available: 1_000, growing: true) == nil)
    #expect(adjustedWindowHeight(current: 500, available: .infinity, growing: false) == nil)
}
