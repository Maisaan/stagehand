import AppKit
import Testing
@testable import StagehandPlatform

@MainActor @Test func windowCornerRadiusAcceptsUniformAndSquareShapes() {
    #expect(WindowCornerRadius.validatedRadius([20, 20, 20, 20]) == 20)
    #expect(WindowCornerRadius.validatedRadius([0, 0, 0, 0]) == 0)
    #expect(WindowCornerRadius.validatedRadius([16]) == 16)
}

@MainActor @Test func windowCornerRadiusRejectsMissingInvalidAndUnsupportedShapes() {
    #expect(WindowCornerRadius.validatedRadius([]) == nil)
    #expect(WindowCornerRadius.validatedRadius([.init(value: Double.nan)]) == nil)
    #expect(WindowCornerRadius.validatedRadius([-1, -1, -1, -1]) == nil)
    #expect(WindowCornerRadius.validatedRadius([16, 16, 0, 0]) == nil)
}

@MainActor @Test func windowCornerRadiusRejectsTheNullWindowIdentity() {
    #expect(WindowCornerRadius.cornerRadius(windowNumber: kCGNullWindowID) == nil)
}
