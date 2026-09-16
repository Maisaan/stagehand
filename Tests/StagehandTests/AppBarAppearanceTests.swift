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

    @Test func developerAnimationControlsUpdateTheAppBarAndPersist() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = [
            "developerControlsEnabled",
            "ribbonAnimationDuration",
            "ribbonAnimationCurve"
        ]
        let originalValues = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = originalValues[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let model = StagehandModel(overlays: overlays)
        let configuration = RibbonAnimationConfiguration(
            duration: 0.34,
            curve: RibbonAnimationCurve(x1: 0.17, y1: 0.68, x2: 0.73, y2: 0.24)
        )

        model.developerControlsEnabled = true
        overlays.hudModel.setAnimationDuration(configuration.duration)
        overlays.hudModel.setAnimationCurve(configuration.curve)

        #expect(overlays.hudModel.developerControlsEnabled)
        #expect(overlays.hudModel.animationConfiguration == configuration)
        let restoredModel = StagehandModel()
        #expect(restoredModel.developerControlsEnabled)
        #expect(restoredModel.ribbonAnimationConfiguration == configuration)
    }

    @Test func legacyAnimationPresetMigratesToCubicBezierControls() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = "ribbonAnimationCurve"
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set("easeOut", forKey: key)

        let model = StagehandModel()

        #expect(model.ribbonAnimationConfiguration.curve == .easeOut)
    }
}
