import AppKit
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct FocusBorderTests {
    @Test func maximizingHidesAnExistingBorderAndRejectsFurtherFrameUpdates() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "maximizeWindows")
        defer {
            if let original { defaults.set(original, forKey: "maximizeWindows") }
            else { defaults.removeObject(forKey: "maximizeWindows") }
        }
        let overlays = NavigationOverlays()
        defer { overlays.hide() }
        let model = StagehandModel(overlays: overlays)
        model.setMaximizeWindows(false)
        model.updateFocusBorder(windowID: "editor", frame: CGRect(x: 100, y: 100, width: 600, height: 500))
        #expect(overlays.border?.isVisible == true)

        model.setMaximizeWindows(true)
        #expect(overlays.border?.isVisible == false)
        model.updateFocusBorder(windowID: "editor", frame: CGRect(x: 0, y: 25, width: 1000, height: 800))
        #expect(overlays.border?.isVisible == false)

        model.setMaximizeWindows(false)
        model.updateFocusBorder(windowID: "editor", frame: CGRect(x: 100, y: 100, width: 600, height: 500))
        #expect(overlays.border?.isVisible == true)
    }
}
