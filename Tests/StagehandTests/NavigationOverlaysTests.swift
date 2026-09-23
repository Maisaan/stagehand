import AppKit
import Testing
@testable import Stagehand

@MainActor
@Test func focusBorderStaysBetweenNormalAndFloatingWindows() throws {
    let overlays = NavigationOverlays()
    defer { overlays.hide() }

    overlays.updateBorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100), visible: true)

    let border = try #require(overlays.border)
    #expect(border.level.rawValue > NSWindow.Level.normal.rawValue)
    #expect(border.level.rawValue < NSWindow.Level.floating.rawValue)
}
