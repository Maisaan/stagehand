import AppKit
import Testing
@testable import StagehandPlatform

@Test func appsWithRegularWindowsAreEligibleEvenWhenTheyRunAsMenuBarAccessories() {
    #expect(canManageWindows(for: .regular, hasVisibleOrTrackedWindow: false))
    #expect(canManageWindows(for: .accessory, hasVisibleOrTrackedWindow: true))
    #expect(!canManageWindows(for: .accessory, hasVisibleOrTrackedWindow: false))
    #expect(!canManageWindows(for: .prohibited, hasVisibleOrTrackedWindow: true))
}
