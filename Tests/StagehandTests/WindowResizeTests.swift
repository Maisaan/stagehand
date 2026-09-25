import CoreGraphics
import Testing
@testable import Stagehand

@Test func topEdgeResizeToScreenBoundaryFillsAvailableHeight() {
    let available = CGRect(x: 0, y: 40, width: 1_000, height: 800)
    let previous = CGRect(x: 0, y: 240, width: 700, height: 400)
    let observed = CGRect(x: 0, y: 40, width: 700, height: 600)

    #expect(preferredHeightAfterResize(previous: previous, observed: observed, available: available) == 800)
}

@Test func ordinaryResizeKeepsTheObservedHeight() {
    let available = CGRect(x: 0, y: 40, width: 1_000, height: 800)
    let previous = CGRect(x: 0, y: 240, width: 700, height: 400)
    let observed = CGRect(x: 0, y: 140, width: 700, height: 500)

    #expect(preferredHeightAfterResize(previous: previous, observed: observed, available: available) == 500)
    let bottomEdgeResize = CGRect(x: 0, y: 40, width: 700, height: 600)
    let alreadyAtTop = CGRect(x: 0, y: 40, width: 700, height: 400)
    #expect(preferredHeightAfterResize(previous: alreadyAtTop, observed: bottomEdgeResize, available: available) == 600)
}
