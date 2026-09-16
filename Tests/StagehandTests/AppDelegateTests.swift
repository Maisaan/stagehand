import AppKit
import Testing
@testable import Stagehand

@Test @MainActor func commandQClosesTheWindowWithoutQuittingStagehand() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let appMenu = try #require(delegate.makeApplicationMenu().items.first?.submenu)
    let commandQ = try #require(appMenu.items.first { $0.keyEquivalent == "q" })

    #expect(commandQ.title == "Close Stagehand Window")
    #expect(commandQ.action.map(NSStringFromSelector) == "closeSettingsWindow")
    #expect(!appMenu.items.contains { $0.action.map(NSStringFromSelector) == "quit" })
}

@Test @MainActor func statusItemUsesPrimaryClickForTheWindowAndSecondaryClickForItsMenu() {
    #expect(statusItemClick(for: .leftMouseUp) == .openWindow)
    #expect(statusItemClick(for: .rightMouseUp) == .showMenu)
    #expect(statusItemClick(for: nil) == .openWindow)
}

@Test @MainActor func statusMenuKeepsSpacesInASubmenuAndQuitExplicit() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let menu = delegate.makeStatusMenu(state: StatusMenuState(
        isRunning: true,
        isSuspended: false,
        activeSpaceIndex: 1,
        spaces: [(index: 0, windowCount: 1), (index: 1, windowCount: 3)]
    ))

    #expect(menu.items.map(\.title) == ["Open Stagehand", "Pause Stagehand", "", "Spaces", "", "Quit Stagehand"])
    let spaces = try #require(menu.items.first { $0.title == "Spaces" }?.submenu)
    #expect(spaces.items.map(\.title) == ["Space 1 (1 window)", "Space 2 (3 windows)"])
    #expect(spaces.items[1].state == .on)
    let quit = try #require(menu.items.first { $0.title == "Quit Stagehand" })
    #expect(quit.keyEquivalent.isEmpty)
}
