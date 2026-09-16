import AppKit
import Testing
@testable import Stagehand

struct NavigationHUDGeometryTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)

    @Test func notchGeometryAttachesWithoutAVisibleGap() {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryLeft: CGRect(x: 0, y: 950, width: 650, height: 32),
            auxiliaryRight: CGRect(x: 862, y: 950, width: 650, height: 32), windowCount: 5)
        #expect(geometry.attachedToNotch)
        #expect(geometry.contentFrame.midX == 756)
        #expect(geometry.contentFrame.maxY == 950)
        #expect(geometry.panelFrame.maxY == 950)
        #expect(geometry.contentFrame.width == 240)
        #expect(geometry.contentFrame.height == 66)
    }

    @Test(arguments: [0, 1, 2, 3]) func smallWindowCountsDoNotReserveEmptySlots(windowCount: Int) {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryLeft: CGRect(x: 0, y: 950, width: 650, height: 32),
            auxiliaryRight: CGRect(x: 862, y: 950, width: 650, height: 32), windowCount: windowCount)
        #expect(geometry.contentFrame.width == 60 + CGFloat(max(1, windowCount)) * 36)
        #expect(geometry.contentFrame.midX == 756)
        #expect(geometry.attachedToNotch)
    }

    @Test func nonNotchedDisplayUsesCompactFloatingFallback() {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 0,
            auxiliaryLeft: nil, auxiliaryRight: nil, windowCount: 1)
        #expect(!geometry.attachedToNotch)
        #expect(geometry.contentFrame.width == 96)
        #expect(geometry.contentFrame.maxY == 944)
        #expect(geometry.contentFrame.midX == screen.midX)
    }

    @Test func developerControlsExpandTheAppBar() {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen,
            visibleFrame: visible,
            safeAreaTop: 32,
            auxiliaryLeft: CGRect(x: 0, y: 950, width: 650, height: 32),
            auxiliaryRight: CGRect(x: 862, y: 950, width: 650, height: 32),
            windowCount: 2,
            showsDeveloperControls: true
        )

        #expect(geometry.contentFrame.width == 500)
        #expect(geometry.contentFrame.height == 108)
        #expect(geometry.attachedToNotch)
    }

    @Test func actualNotchCenterIsUsedOnAnOffsetDisplay() {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen.offsetBy(dx: -1512, dy: 100),
            visibleFrame: visible.offsetBy(dx: -1512, dy: 100), safeAreaTop: 32,
            auxiliaryLeft: CGRect(x: -1512, y: 1050, width: 620, height: 32),
            auxiliaryRight: CGRect(x: -650, y: 1050, width: 650, height: 32), windowCount: 5)
        #expect(geometry.contentFrame.midX == -771)
        #expect(geometry.contentFrame.maxY == 1050)
    }

    @Test func manyWindowsRemainBoundedAndWarningsRemainReadable() {
        let navigation = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 0,
            auxiliaryLeft: nil, auxiliaryRight: nil, windowCount: 100)
        let warning = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryLeft: CGRect(x: 0, y: 950, width: 650, height: 32),
            auxiliaryRight: CGRect(x: 862, y: 950, width: 650, height: 32),
            windowCount: 1, warningHeight: 118)
        #expect(navigation.contentFrame.width == 520)
        #expect(warning.contentFrame.width == 580)
        #expect(warning.contentFrame.height == 118)
        #expect(!warning.attachedToNotch)
    }

    @Test func missingAuxiliaryAreasDoNotInventANotch() {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen, visibleFrame: visible, safeAreaTop: 32,
            auxiliaryLeft: nil, auxiliaryRight: nil, windowCount: 3)
        #expect(!geometry.attachedToNotch)
        #expect(geometry.contentFrame.maxY == 944)
    }
}
