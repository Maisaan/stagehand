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

@MainActor @Test func navigationBorderUsesTheTargetWindowRadius() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let small = BorderView.outline(in: bounds, cornerRadius: 10)
    let outline = BorderView.outline(in: bounds, cornerRadius: 26)
    #expect(small.contains(CGPoint(x: 5, y: 5)))
    for point in [CGPoint(x: 5, y: 5), CGPoint(x: 95, y: 5),
                  CGPoint(x: 5, y: 95), CGPoint(x: 95, y: 95)] {
        #expect(!outline.contains(point))
    }
    #expect(outline.contains(CGPoint(x: 50, y: 50)))
    #expect(outline.lineWidth == 2)
    #expect(outline.bounds == CGRect(x: 1, y: 1, width: 98, height: 98))
}

@MainActor @Test func navigationBorderRejectsInvalidRadiiAndPreservesSquareCorners() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let invalidRadii: [CGFloat?] = [nil, .nan, .infinity, -1]
    for invalid in invalidRadii {
        let outline = BorderView.outline(in: bounds, cornerRadius: invalid)
        #expect(outline.contains(CGPoint(x: 5, y: 5)))
        #expect(outline.bounds == CGRect(x: 1, y: 1, width: 98, height: 98))
    }
    let square = BorderView.outline(in: bounds, cornerRadius: 0)
    #expect(square.contains(CGPoint(x: 2, y: 2)))
}

@MainActor @Test func navigationBorderStaysInsideWindowAtDisplayEdges() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let overlays = NavigationOverlays()
    defer { overlays.hide() }
    let frame = CGRect(x: screen.frame.maxX - 300, y: 0, width: 300, height: screen.frame.height)
    overlays.updateBorder(frame: frame, visible: true, cornerRadius: 26)
    let panel = try #require(overlays.border)
    let expected = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
    #expect(panel.frame == expected)
    let view = try #require(panel.contentView)
    let path = BorderView.outline(in: view.bounds, cornerRadius: 26)
    let strokeBounds = path.bounds.insetBy(dx: -path.lineWidth / 2, dy: -path.lineWidth / 2)
    #expect(view.bounds.contains(strokeBounds))
}
