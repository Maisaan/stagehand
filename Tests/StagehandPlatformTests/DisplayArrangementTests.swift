import CoreGraphics
import StagehandCore
import Testing
@testable import StagehandPlatform

private func screen(_ number: CGDirectDisplayID, _ frame: CGRect, visible: CGRect? = nil,
                    builtIn: Bool = false, scale: CGFloat = 2) -> ScreenDescription {
    ScreenDescription(id: DisplayID(rawValue: "DISPLAY-\(number)"), number: number, frame: frame,
                      visibleFrame: visible ?? frame, isBuiltIn: builtIn, backingScaleFactor: scale,
                      maximumFramesPerSecond: builtIn ? 120 : 60)
}

private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let laptopVisible = CGRect(x: 0, y: 70, width: 1512, height: 880)

@Test func aBuiltInDisplayAloneKeepsItsVisibleFrameWithYFlippedToTheTop() {
    let arrangement = DisplayArrangement(screens: [screen(1, laptop, visible: laptopVisible, builtIn: true)])

    #expect(arrangement.ids == [DisplayID(rawValue: "DISPLAY-1")])
    #expect(arrangement.fallback == DisplayID(rawValue: "DISPLAY-1"))
    #expect(arrangement.builtIn?.number == 1)
    #expect(arrangement.builtIn?.frame == laptop)
    // 32 pt menu bar at the top, 70 pt Dock at the bottom.
    #expect(arrangement.builtIn?.visibleFrame == CGRect(x: 0, y: 32, width: 1512, height: 880))
    #expect(arrangement.builtIn?.backingScaleFactor == 2)
    #expect(arrangement.builtIn?.maximumFramesPerSecond == 120)
}

@Test func framesFlipAgainstTheMenuBarDisplayAndDisplaysRunLeftToRight() {
    let external = screen(2, CGRect(x: 0, y: 0, width: 2560, height: 1440),
                          visible: CGRect(x: 0, y: 0, width: 2560, height: 1415), scale: 1)
    let builtIn = screen(1, CGRect(x: -1512, y: 100, width: 1512, height: 982),
                         visible: CGRect(x: -1512, y: 100, width: 1512, height: 950), builtIn: true)
    let arrangement = DisplayArrangement(screens: [external, builtIn])

    #expect(arrangement.displays.map(\.number) == [1, 2])
    #expect(arrangement.fallback == builtIn.id)
    #expect(arrangement.display(builtIn.id)?.frame == CGRect(x: -1512, y: 358, width: 1512, height: 982))
    #expect(arrangement.display(builtIn.id)?.visibleFrame == CGRect(x: -1512, y: 390, width: 1512, height: 950))
    #expect(arrangement.display(external.id)?.visibleFrame == CGRect(x: 0, y: 25, width: 2560, height: 1415))
    #expect(arrangement.display(external.id)?.backingScaleFactor == 1)
}

@Test func withoutABuiltInDisplayTheMenuBarDisplayIsTheFallback() {
    let primary = screen(3, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let left = screen(4, CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    let arrangement = DisplayArrangement(screens: [primary, left])

    #expect(arrangement.builtIn == nil)
    #expect(arrangement.fallback == primary.id)
    #expect(arrangement.ids == [left.id, primary.id])
}

@Test func noScreensMeansNoDisplaysAndNoFallback() {
    let arrangement = DisplayArrangement(screens: [])

    #expect(arrangement.displays.isEmpty)
    #expect(arrangement.fallback == nil)
    #expect(arrangement.builtIn == nil)
}

@Test func neighborsTouchAnEdgeAndOverlapVertically() {
    let builtIn = screen(1, laptop, builtIn: true)
    let right = screen(2, CGRect(x: 1512.5, y: -200, width: 1920, height: 1080))
    let left = screen(3, CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    let arrangement = DisplayArrangement(screens: [builtIn, right, left])

    #expect(arrangement.neighbor(of: builtIn.id, on: .right)?.id == right.id)
    #expect(arrangement.neighbor(of: builtIn.id, on: .left)?.id == left.id)
    #expect(arrangement.neighbor(of: right.id, on: .left)?.id == builtIn.id)
    #expect(arrangement.neighbor(of: right.id, on: .right) == nil)
}

@Test func aDisplayAcrossAGapOrOnlyTouchingACornerIsNotANeighbor() {
    let builtIn = screen(1, laptop, builtIn: true)
    let apart = screen(2, CGRect(x: 1520, y: 0, width: 1920, height: 1080))
    let corner = screen(3, CGRect(x: -1920, y: 982, width: 1920, height: 1080))
    let arrangement = DisplayArrangement(screens: [builtIn, apart, corner])

    #expect(arrangement.neighbor(of: builtIn.id, on: .right) == nil)
    #expect(arrangement.neighbor(of: builtIn.id, on: .left) == nil)
}
