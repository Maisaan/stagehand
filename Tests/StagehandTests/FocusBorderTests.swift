import AppKit
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct FocusBorderTests {
    @Test func changingTheColorUpdatesAnExistingBorderAndPersistsTheChoice() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "focusBorderColor")
        defer {
            if let original { defaults.set(original, forKey: "focusBorderColor") }
            else { defaults.removeObject(forKey: "focusBorderColor") }
        }
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let model = StagehandModel(overlays: overlays)
        overlays.updateBorder(frame: CGRect(x: 100, y: 100, width: 600, height: 500), visible: true)
        let borderView = try #require(overlays.border?.contentView as? BorderView)

        model.setFocusBorderColor(.systemPink)

        let expected = try #require(NSColor.systemPink.usingColorSpace(.sRGB))
        #expect(borderView.strokeColor.redComponent == expected.redComponent)
        #expect(borderView.strokeColor.greenComponent == expected.greenComponent)
        #expect(borderView.strokeColor.blueComponent == expected.blueComponent)
        let restoredModel = StagehandModel()
        #expect(restoredModel.focusBorderColor.redComponent == expected.redComponent)
        #expect(restoredModel.focusBorderColor.greenComponent == expected.greenComponent)
        #expect(restoredModel.focusBorderColor.blueComponent == expected.blueComponent)
    }

}
