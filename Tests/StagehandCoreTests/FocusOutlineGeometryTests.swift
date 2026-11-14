import CoreGraphics
import Testing
@testable import StagehandCore

@Test func outlinePanelsHoldTheStrokeAndCornersButNotTheInterior() {
    let window = CGRect(x: 100, y: 50, width: 800, height: 600)
    let panels = FocusOutlineGeometry.panelFrames(window: window, cornerRadius: 16)

    #expect(panels == [
        CGRect(x: 100, y: 50, width: 800, height: 16),
        CGRect(x: 100, y: 634, width: 800, height: 16),
        CGRect(x: 100, y: 66, width: 2, height: 568),
        CGRect(x: 898, y: 66, width: 2, height: 568),
    ])
    #expect(panels.allSatisfy { !$0.intersects(window.insetBy(dx: 16, dy: 16)) })
}

/// Xcode's sign-in sheet hangs below its short Settings window: the bottom edge stops
/// either side of it, and no panel touches the sheet.
@Test func outlinePanelsStopAtASheetThatCrossesTheWindowsEdge() {
    let window = CGRect(x: 0, y: 0, width: 1_000, height: 400)
    let sheet = CGRect(x: 200, y: 40, width: 600, height: 960)
    let panels = FocusOutlineGeometry.panelFrames(window: window, cornerRadius: 16, cutout: sheet)

    #expect(panels.allSatisfy { !$0.intersects(sheet) })
    #expect(panels.contains(CGRect(x: 0, y: 384, width: 200, height: 16)))
    #expect(panels.contains(CGRect(x: 800, y: 384, width: 200, height: 16)))
    #expect(panels.contains(CGRect(x: 0, y: 0, width: 1_000, height: 16)))
}

@Test func outlinePanelsFitATinyWindow() {
    let window = CGRect(x: 0, y: 0, width: 20, height: 10)
    let panels = FocusOutlineGeometry.panelFrames(window: window, cornerRadius: 16)

    #expect(panels == [CGRect(x: 0, y: 0, width: 20, height: 5), CGRect(x: 0, y: 5, width: 20, height: 5)])
    #expect(FocusOutlineGeometry.panelFrames(window: .zero, cornerRadius: 16).isEmpty)
}
