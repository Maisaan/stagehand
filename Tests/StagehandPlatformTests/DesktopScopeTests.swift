import Testing
@testable import StagehandPlatform

@MainActor @Test func desktopScopeResumesOnlyOnStartingNativeDesktop() {
    var desktop: UInt64? = 41
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(scope.bindToCurrentDesktop())
    #expect(scope.relation == .home)
    desktop = 92
    #expect(scope.refresh() == .away)
    desktop = 41
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeSuspendsWhileUserSessionIsInactive() {
    var sessionIsActive = true
    let scope = DesktopScope(
        currentDesktopID: { 41 },
        userSessionIsActive: { sessionIsActive }
    )
    #expect(scope.bindToCurrentDesktop())

    sessionIsActive = false
    #expect(scope.refresh() == .unknown)

    sessionIsActive = true
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeDoesNotRebindWhenAwayOrDuringUnknownNotification() {
    var desktop: UInt64? = 41
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(scope.bindToCurrentDesktop())
    desktop = nil
    #expect(scope.refresh() == .unknown)
    desktop = 92
    #expect(scope.refresh() == .away)
    #expect(!scope.bindToCurrentDesktop())
    desktop = 41
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeNeverAdoptsDesktopAfterFailedBind() {
    var desktop: UInt64?
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(!scope.bindToCurrentDesktop())
    desktop = 92
    #expect(scope.refresh() == .unknown)
    #expect(scope.bindToCurrentDesktop())
    #expect(scope.relation == .home)
}

@MainActor @Test func desktopScopeResetAllowsExplicitNewHomeAndRejectsZeroID() {
    var desktop: UInt64? = 0
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(!scope.bindToCurrentDesktop())
    desktop = 41
    #expect(scope.bindToCurrentDesktop())
    desktop = 92
    scope.reset()
    #expect(scope.relation == .unknown)
    #expect(scope.refresh() == .unknown)
    #expect(scope.bindToCurrentDesktop())
    desktop = 41
    #expect(scope.refresh() == .away)
    desktop = 0
    #expect(scope.refresh() == .unknown)
    desktop = 92
    #expect(scope.refresh() == .home)
}
