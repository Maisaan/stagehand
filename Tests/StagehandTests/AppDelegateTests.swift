import AppKit
import StagehandPlatform
import Testing
@testable import Stagehand

@Test func statusItemClickRoutesLeftAndRightClicks() {
    #expect(statusItemClick(for: .leftMouseUp) == .showControls)
    #expect(statusItemClick(for: .rightMouseUp) == .showMenu)
}

@MainActor
@Test func quickControlsPanelTakesFocusWhenPresentedWithoutPopoverChrome() {
    let panel = QuickControlsPanel(contentView: NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400)))
    defer { panel.close() }

    #expect(!panel.styleMask.contains(.titled))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.canBecomeKey)
    #expect(panel.level == .popUpMenu)

    panel.present(at: CGPoint(x: 100, y: 100))

    #expect(panel.isVisible)
    #expect(panel.isKeyWindow)
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

@MainActor
@Test func settingsWindowContentDoesNotMoveTheWindow() {
    let window = SettingsWindow.make(model: StagehandModel())
    defer { window.close() }

    #expect(!window.isMovableByWindowBackground)
}

@MainActor
@Test func openingSettingsBringsTheAppToTheFrontEveryTime() async throws {
    let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
    let finder = try #require(NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.finder"
    ).first)
    let delegate = AppDelegate(model: StagehandModel())
    var settingsWindow: NSWindow?
    defer {
        settingsWindow?.close()
        if let previouslyActiveApplication,
           previouslyActiveApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previouslyActiveApplication.activate()
        }
    }

    finder.activate()
    try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier }

    delegate.openSettings()
    try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    let openedWindow = try #require(NSApp.windows.first { $0.title == "Stagehand" && $0.isVisible })
    settingsWindow = openedWindow

    finder.activate()
    try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier }

    delegate.openSettings()
    try await waitUntil { NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier }
    #expect(settingsWindow?.isVisible == true)
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
}

/// Space colors accept pasted text. A sign must not pass as a hex digit.
@Test func hexColorParsingRejectsSignsAndWrongLengths() {
    #expect(RGBHexColor.parse("#1E90FF") != nil)
    #expect(RGBHexColor.parse(" 1e90ff ") != nil)
    #expect(RGBHexColor.parse("#+FFFFF") == nil)
    #expect(RGBHexColor.parse("#-FFFFF") == nil)
    #expect(RGBHexColor.parse("#FFF") == nil)
    #expect(RGBHexColor.parse("#GGGGGG") == nil)
}
