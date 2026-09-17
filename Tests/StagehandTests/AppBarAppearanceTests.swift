import AppKit
import Testing
@testable import Stagehand

@Suite @MainActor
struct AppBarAppearanceTests {
    @Test func appBarUsesTheFocusBorderColor() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays()
        defer { overlays.hide() }

        overlays.setBorderColor(.systemOrange)

        let expected = try #require(NSColor.systemOrange.usingColorSpace(.sRGB))
        let actual = try #require(overlays.hudModel.appBarColor.usingColorSpace(.sRGB))
        #expect(actual.redComponent == expected.redComponent)
        #expect(actual.greenComponent == expected.greenComponent)
        #expect(actual.blueComponent == expected.blueComponent)
    }
}
