import AppKit
import StagehandPlatform
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

    let expectedControls: [(NSWindow.ButtonType, centerX: CGFloat, isEnabled: Bool)] = [
        (.closeButton, 26, true),
        (.miniaturizeButton, 49, false),
        (.zoomButton, 72, false)
    ]

    func checkControlPositions() throws {
        for (buttonType, expectedX, isEnabled) in expectedControls {
            let button = try #require(window.standardWindowButton(buttonType))
            let frame = button.convert(button.bounds, to: nil)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            #expect(abs(center.x - expectedX) <= 1)
            #expect(abs(window.frame.height - center.y - 26) <= 1)
            #expect(button.isEnabled == isEnabled)
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

@MainActor
@Test func settingsWindowFocusBorderUsesItsVisibleCornerRadius() throws {
    let window = SettingsWindow.make(model: StagehandModel())
    window.orderFrontRegardless()
    defer { window.close() }

    let windowNumber = try #require(CGWindowID(exactly: window.windowNumber))
    #expect(WindowCornerRadius.cornerRadius(windowNumber: windowNumber) == SettingsWindow.cornerRadius)
}
