import AppKit
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct AppBarAppearanceTests {
    @Test func changingTheColorUpdatesTheAppBarAndPersistsTheChoice() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = "appBarColor"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let model = StagehandModel(overlays: overlays)

        model.setAppBarColor(.systemOrange)

        let expected = try #require(NSColor.systemOrange.usingColorSpace(.sRGB))
        #expect(overlays.hudModel.appBarColor == expected)
        let restoredModel = StagehandModel()
        #expect(restoredModel.appBarColor == expected)
    }

}
