import Testing
@testable import StagehandPlatform

// Each change to the fixture stands for a Desktop or session notification, which
// invalidates the scope's cached answer.

@MainActor @Test func desktopScopeResumesOnlyOnStartingNativeDesktop() {
    var desktop: UInt64? = 41
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(scope.bindToCurrentDesktop())
    #expect(scope.relation == .home)
    desktop = 92
    scope.invalidate()
    #expect(scope.refresh() == .away)
    desktop = 41
    scope.invalidate()
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
    scope.invalidate()
    #expect(scope.refresh() == .unknown)

    sessionIsActive = true
    scope.invalidate()
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeDoesNotRebindWhenAwayOrDuringUnknownNotification() {
    var desktop: UInt64? = 41
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(scope.bindToCurrentDesktop())
    desktop = nil
    scope.invalidate()
    #expect(scope.refresh() == .unknown)
    desktop = 92
    scope.invalidate()
    #expect(scope.refresh() == .away)
    #expect(!scope.bindToCurrentDesktop())
    desktop = 41
    scope.invalidate()
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeNeverAdoptsDesktopAfterFailedBind() {
    var desktop: UInt64?
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(!scope.bindToCurrentDesktop())
    desktop = 92
    scope.invalidate()
    #expect(scope.refresh() == .unknown)
    #expect(scope.bindToCurrentDesktop())
    #expect(scope.relation == .home)
}

@MainActor @Test func desktopScopeResetAllowsExplicitNewHomeAndRejectsZeroID() {
    var desktop: UInt64? = 0
    let scope = DesktopScope(currentDesktopID: { desktop })
    #expect(!scope.bindToCurrentDesktop())
    desktop = 41
    scope.invalidate()
    #expect(scope.bindToCurrentDesktop())
    desktop = 92
    scope.invalidate()
    scope.reset()
    #expect(scope.relation == .unknown)
    #expect(scope.refresh() == .unknown)
    #expect(scope.bindToCurrentDesktop())
    desktop = 41
    scope.invalidate()
    #expect(scope.refresh() == .away)
    desktop = 0
    scope.invalidate()
    #expect(scope.refresh() == .unknown)
    desktop = 92
    scope.invalidate()
    #expect(scope.refresh() == .home)
}

/// One switch asks for the Desktop several times, each a WindowServer round trip.
/// A home or away answer is reused until a notification or the cache age; an
/// unknown answer (the lock screen) is read again every time.
@MainActor @Test func desktopScopeReusesAnAnswerUntilInvalidatedOrAged() {
    var desktop: UInt64? = 41
    var reads = 0
    var clock = ContinuousClock.Instant.now
    let scope = DesktopScope(currentDesktopID: { reads += 1; return desktop }, now: { clock })
    #expect(scope.bindToCurrentDesktop())
    reads = 0

    desktop = 92
    #expect(scope.refresh() == .home)
    #expect(scope.refresh() == .home)
    #expect(reads == 0)

    scope.invalidate()
    #expect(scope.refresh() == .away)
    #expect(reads == 1)

    desktop = 41
    clock = clock.advanced(by: scope.cacheMaxAge)
    #expect(scope.refresh() == .home)
    #expect(reads == 2)

    desktop = nil
    scope.invalidate()
    #expect(scope.refresh() == .unknown)
    #expect(scope.refresh() == .unknown)
    #expect(reads == 4)
}
