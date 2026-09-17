import AppKit
import Testing
@testable import Stagehand

@Test func statusItemClickRoutesLeftAndRightClicks() {
    #expect(statusItemClick(for: .leftMouseUp) == .showControls)
    #expect(statusItemClick(for: .rightMouseUp) == .showMenu)
}
