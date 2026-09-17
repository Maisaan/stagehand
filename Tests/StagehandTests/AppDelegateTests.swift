import AppKit
import Testing
@testable import Stagehand

@Test func statusItemClickRoutesLeftAndRightClicks() {
    #expect(statusItemClick(for: .leftMouseUp) == .showControls)
    #expect(statusItemClick(for: .rightMouseUp) == .showMenu)
}

@MainActor
@Test func settingsWindowControlsUseLargeWindowInset() throws {
    let window = SettingsWindow.make(model: StagehandModel())
    defer { window.close() }

    let expectedCenters: [(NSWindow.ButtonType, CGFloat)] = [
        (.closeButton, 26),
        (.miniaturizeButton, 49),
        (.zoomButton, 72)
    ]

    func checkControlPositions() throws {
        for (buttonType, expectedX) in expectedCenters {
            let button = try #require(window.standardWindowButton(buttonType))
            let frame = button.convert(button.bounds, to: nil)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            #expect(abs(center.x - expectedX) <= 1)
            #expect(abs(window.frame.height - center.y - 26) <= 1)
        }
    }

    try checkControlPositions()
    window.setContentSize(NSSize(width: 800, height: 720))
    try checkControlPositions()
    window.setFrame(
        NSRect(origin: window.frame.origin, size: NSSize(width: 780, height: 700)),
        display: false,
        animate: false
    )
    try checkControlPositions()
}
