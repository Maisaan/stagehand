import AppKit
import Testing
@testable import Stagehand

@MainActor @Test func navigationOverlayStaysOnItsDesktopAndOutOfFullscreen() {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer { panel.close() }
    #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.collectionBehavior.contains(.fullScreenNone))
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.ignoresMouseEvents)
}

@MainActor @Test func navigationBorderFitsTahoeCornerCurve() {
    guard #available(macOS 26, *) else { return }
    let outline = BorderView.outline(in: CGRect(x: 0, y: 0, width: 100, height: 100))
    // In the supplied crop, the 10pt green curve cuts across the larger native corner.
    // All four 5pt corner points must be outside a Tahoe-sized outline.
    for point in [CGPoint(x: 5, y: 5), CGPoint(x: 95, y: 5),
                  CGPoint(x: 5, y: 95), CGPoint(x: 95, y: 95)] {
        #expect(!outline.contains(point))
    }
    #expect(outline.contains(CGPoint(x: 50, y: 50)))
    #expect(outline.lineWidth == 2)
    #expect(outline.bounds == CGRect(x: 1, y: 1, width: 98, height: 98))
}
