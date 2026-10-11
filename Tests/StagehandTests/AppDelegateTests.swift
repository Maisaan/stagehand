import AppKit
import StagehandPlatform
import Testing
@testable import Stagehand

@Test func statusItemClickRoutesLeftAndRightClicks() {
    #expect(statusItemClick(for: .leftMouseUp) == .showControls)
    #expect(statusItemClick(for: .rightMouseUp) == .showMenu)
}

/// Key window status needs the test process to be the active application.
/// The runner usually starts behind the terminal or editor that launched it,
/// so activate first; when macOS refuses, skip rather than report a false
/// failure. The assertions are unchanged when the process is frontmost.
private let requiresActiveTestProcess = ConditionTrait.enabled(
    "The test process could not become the active application; run from a frontmost terminal to cover key window behavior."
) {
    await MainActor.run { _ = NSApplication.shared }
    return await testProcessIsActive()
}

@MainActor
private func testProcessIsActive(timeout: Duration = .seconds(2)) async -> Bool {
    let app = NSApplication.shared
    if app.activationPolicy() == .prohibited { app.setActivationPolicy(.accessory) }
    app.activate(ignoringOtherApps: true)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let currentPID = ProcessInfo.processInfo.processIdentifier
    func active() -> Bool {
        app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == currentPID
    }
    while !active() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return active()
}

@MainActor
@Test(requiresActiveTestProcess)
func quickControlsPanelTakesFocusWhenPresentedWithoutPopoverChrome() async {
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
@Test func quickControlsPanelDetachesItsContentWhileHidden() {
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 400))
    let panel = QuickControlsPanel(contentView: content)
    defer { panel.close() }

    panel.present(at: CGPoint(x: 100, y: 100))
    #expect(panel.contentView === content)

    panel.dismiss()
    #expect(!panel.isVisible)
    #expect(panel.contentView == nil)

    panel.present(at: CGPoint(x: 100, y: 100))
    #expect(panel.contentView === content)
}

@MainActor
@Test func settingsWindowControlsUseLargeWindowInset() throws {
    let window = SettingsWindow.make(model: testModel())
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
    let window = SettingsWindow.make(model: testModel())
    window.orderFrontRegardless()
    defer { window.close() }

    let windowNumber = try #require(CGWindowID(exactly: window.windowNumber))
    #expect(WindowCornerRadius.cornerRadius(windowNumber: windowNumber) == SettingsWindow.cornerRadius)
}

@MainActor
@Test func settingsWindowContentDoesNotMoveTheWindow() {
    let window = SettingsWindow.make(model: testModel())
    defer { window.close() }

    #expect(!window.isMovableByWindowBackground)
}

@MainActor
@Test func settingsWindowUsesTheDarkAppearanceAndRestoresContentOnReopen() throws {
    let window = SettingsWindow.make(model: testModel())
    defer { window.close() }

    #expect(window.appearance?.name == .darkAqua)
    let content = try #require(window.contentView)

    window.orderFrontRegardless()
    window.close()
    #expect(window.contentView == nil)

    window.orderFrontRegardless()
    #expect(window.contentView === content)
}

@MainActor
@Test func settingsWindowReopensOnScreenAfterItsFrameLeftEveryDisplay() throws {
    let window = SettingsWindow.make(model: testModel())
    defer { window.close() }
    let screens = NSScreen.screens
    try #require(!screens.isEmpty)
    let farRight = screens.map(\.frame.maxX).max()! + 5_000

    window.setFrameOrigin(CGPoint(x: farRight, y: 0))
    #expect(!screens.contains { $0.visibleFrame.intersects(window.frame) })

    window.orderFrontRegardless()
    #expect(screens.contains { $0.visibleFrame.intersects(window.frame) })
}

@MainActor
@Test(requiresActiveTestProcess)
func openingSettingsBringsTheAppToTheFrontEveryTime() async throws {
    let previouslyActiveApplication = NSWorkspace.shared.frontmostApplication
    let finder = try #require(NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.finder"
    ).first)
    let delegate = AppDelegate(model: testModel())
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

/// The gap field accepts the period everywhere and the locale's decimal separator.
@Test func gapParsingAcceptsTheLocaleDecimalSeparator() {
    let german = Locale(identifier: "de_DE")
    let english = Locale(identifier: "en_US")
    #expect(GapInput.parse("2,5", locale: german) == 2.5)
    #expect(GapInput.parse("2.5", locale: german) == 2.5)
    #expect(GapInput.parse("2.5", locale: english) == 2.5)
    #expect(GapInput.parse("2,5", locale: english) == nil)
    #expect(GapInput.parse(" -200 ", locale: english) == -200)
    #expect(GapInput.parse("1,000", locale: english) == nil)
    #expect(GapInput.parse("abc", locale: english) == nil)
    #expect(GapInput.parse("", locale: english) == nil)
    #expect(GapInput.format(8, locale: german) == "8")
    #expect(GapInput.format(2.5, locale: german) == "2,5")
    #expect(GapInput.format(-200, locale: english) == "-200")
}

/// Icons resolve from the SwiftPM resource bundle under swift test and are parsed once.
@MainActor
@Test func phosphorIconsResolveAndAreCached() {
    #expect(PhosphorIconCache.url(for: .gear) != nil)
    let first = PhosphorIconCache.image(for: .gear)
    #expect(first.size == NSSize(width: 16, height: 16))
    #expect(first.isTemplate)
    #expect(PhosphorIconCache.image(for: .gear) === first)
}

@MainActor private func testModel() -> StagehandModel {
    StagehandModel(diagnostics: DiagnosticLogger(
        logURL: FileManager.default.temporaryDirectory.appendingPathComponent("stagehand-test-\(UUID().uuidString).log"),
        enabled: false), persistence: .ephemeral)
}

/// The relaunch helper must wait for this process to exit before opening the
/// bundle, and must pass a path with spaces or quotes as one shell argument.
@Test func onboardingRelaunchScriptWaitsForThePidAndQuotesThePath() {
    let script = OnboardingRelaunch.script(pid: 4242, bundlePath: "/Apps/It's here/Stagehand.app")
    #expect(script.hasPrefix("while kill -0 4242 2>/dev/null; do sleep 0.2; done; open -n "))
    #expect(script.hasSuffix("open -n '/Apps/It'\\''s here/Stagehand.app'"))
}
