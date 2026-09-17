import AppKit
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct FocusBorderTests {
    @Test func hexColorsAcceptPastedValuesAndRejectInvalidInput() throws {
        let color = try #require(RGBHexColor.parse("  12aBeF\n"))
        #expect(abs(color.redComponent - Double(0x12) / 255) < 0.000_001)
        #expect(abs(color.greenComponent - Double(0xAB) / 255) < 0.000_001)
        #expect(abs(color.blueComponent - Double(0xEF) / 255) < 0.000_001)
        #expect(RGBHexColor.format(color) == "#12ABEF")
        #expect(RGBHexColor.parse("#FFF") == nil)
        #expect(RGBHexColor.parse("#12XXEF") == nil)
    }

    @Test func eachSpacePersistsItsOwnColorAndTheActiveColorUpdatesAnExistingBorder() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let legacyKey = "focusBorderColor"
        let colorsKey = "focusBorderColors"
        let originalLegacy = defaults.object(forKey: legacyKey)
        let originalColors = defaults.object(forKey: colorsKey)
        defer {
            if let originalLegacy { defaults.set(originalLegacy, forKey: legacyKey) }
            else { defaults.removeObject(forKey: legacyKey) }
            if let originalColors { defaults.set(originalColors, forKey: colorsKey) }
            else { defaults.removeObject(forKey: colorsKey) }
        }
        defaults.removeObject(forKey: legacyKey)
        defaults.removeObject(forKey: colorsKey)
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let model = StagehandModel(overlays: overlays)
        overlays.updateBorder(frame: CGRect(x: 100, y: 100, width: 600, height: 500), visible: true)
        let borderView = try #require(overlays.border?.contentView as? BorderView)

        model.setFocusBorderColor(.systemPink)
        model.setFocusBorderColor(.systemOrange, forSpace: 2)

        let expectedPink = try #require(NSColor.systemPink.usingColorSpace(.sRGB))
        let expectedOrange = try #require(NSColor.systemOrange.usingColorSpace(.sRGB))
        #expect(borderView.strokeColor.redComponent == expectedPink.redComponent)
        #expect(borderView.strokeColor.greenComponent == expectedPink.greenComponent)
        #expect(borderView.strokeColor.blueComponent == expectedPink.blueComponent)
        let restoredModel = StagehandModel()
        #expect(restoredModel.focusBorderColor(forSpace: 0).redComponent == expectedPink.redComponent)
        #expect(restoredModel.focusBorderColor(forSpace: 0).greenComponent == expectedPink.greenComponent)
        #expect(restoredModel.focusBorderColor(forSpace: 0).blueComponent == expectedPink.blueComponent)
        #expect(restoredModel.focusBorderColor(forSpace: 2).redComponent == expectedOrange.redComponent)
        #expect(restoredModel.focusBorderColor(forSpace: 2).greenComponent == expectedOrange.greenComponent)
        #expect(restoredModel.focusBorderColor(forSpace: 2).blueComponent == expectedOrange.blueComponent)
    }

    @Test func legacyColorBecomesTheDefaultForEverySpace() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let legacyKey = "focusBorderColor"
        let colorsKey = "focusBorderColors"
        let originalLegacy = defaults.object(forKey: legacyKey)
        let originalColors = defaults.object(forKey: colorsKey)
        defer {
            if let originalLegacy { defaults.set(originalLegacy, forKey: legacyKey) }
            else { defaults.removeObject(forKey: legacyKey) }
            if let originalColors { defaults.set(originalColors, forKey: colorsKey) }
            else { defaults.removeObject(forKey: colorsKey) }
        }
        defaults.set([0.2, 0.3, 0.4], forKey: legacyKey)
        defaults.removeObject(forKey: colorsKey)

        let model = StagehandModel()

        for index in 0..<9 {
            let color = model.focusBorderColor(forSpace: index)
            #expect(color.redComponent == 0.2)
            #expect(color.greenComponent == 0.3)
            #expect(color.blueComponent == 0.4)
        }
    }

}
