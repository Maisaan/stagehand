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
            "ribbonAnimationCurve",
            "ribbonGestureTracking",
            "ribbonGestureCommitProgress",
            "ribbonGestureFlickDistance",
            "ribbonGestureFlickVelocity",
            "ribbonGestureEdgeResistance",
            "interfaceAnimationConfiguration"
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
            curve: RibbonAnimationCurve(x1: 0.17, y1: 0.68, x2: 0.73, y2: 0.24),
            tracking: 5.2,
            commitProgress: 0.42,
            flickDistance: 0.035,
            flickVelocity: 0.7,
            edgeResistance: 85
        )
        let interfaceConfiguration = InterfaceAnimationConfiguration(
            hudEnterDuration: 0.24,
            hudExitDuration: 0.12,
            attachedHUDTravel: 16,
            floatingHUDTravel: 9,
            hiddenHUDScale: 0.965,
            feedbackDuration: 0.11,
            pressedScale: 0.95,
            focusRevealDuration: 0.2,
            focusRevealOpacity: 0.6
        )

        model.developerControlsEnabled = true
        overlays.hudModel.setAnimationDuration(configuration.duration)
        overlays.hudModel.setAnimationCurve(configuration.curve)
        overlays.hudModel.setGestureTracking(configuration.tracking)
        overlays.hudModel.setGestureCommitProgress(configuration.commitProgress)
        overlays.hudModel.setGestureFlickDistance(configuration.flickDistance)
        overlays.hudModel.setGestureFlickVelocity(configuration.flickVelocity)
        overlays.hudModel.setGestureEdgeResistance(configuration.edgeResistance)
        model.setInterfaceAnimationConfiguration(interfaceConfiguration)

        #expect(overlays.hudModel.developerControlsEnabled)
        #expect(overlays.hudModel.animationConfiguration == configuration)
        let restoredModel = StagehandModel()
        #expect(restoredModel.developerControlsEnabled)
        #expect(restoredModel.ribbonAnimationConfiguration == configuration)
        #expect(restoredModel.interfaceAnimationConfiguration == interfaceConfiguration)
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
