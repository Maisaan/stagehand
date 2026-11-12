import Testing
import StagehandCore
@testable import StagehandPlatform

// Each change to the fixture stands for a Desktop or session notification, which
// invalidates the scope's cached answer.

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

/// Two displays with separate Spaces. CGSGetActiveSpace follows keyboard focus, so it
/// changes when focus moves to the other display although neither display switched.
@MainActor
private final class DisplaysFixture {
    static let builtIn = DisplayID(rawValue: "37D8832A-0000-0000-0000-000000000001")
    static let external = DisplayID(rawValue: "9A1F2B3C-0000-0000-0000-000000000002")
    var connected = [builtIn, external]
    var spaces: [DisplayID: UInt64] = [builtIn: 1, external: 5]
    var active: UInt64? = 1
    var separateSpaces = true
    var readerAvailable = true
    var displayReads = 0
    var readings: [NativeSpaceReadings] = []

    func scope(now: @escaping () -> ContinuousClock.Instant = { .now }) -> DesktopScope {
        let source = DisplaySpaceSource(
            connectedDisplays: { self.connected },
            screensHaveSeparateSpaces: { self.separateSpaces },
            currentSpace: readerAvailable ? { self.displayReads += 1; return self.spaces[$0] } : nil,
            readerSymbol: "SLSManagedDisplayGetCurrentSpace")
        let scope = DesktopScope(currentDesktopID: { self.active }, displaySource: source, now: now)
        scope.onReadings = { self.readings.append($0) }
        return scope
    }
}

@MainActor @Test func desktopScopeWithTwoDisplaysIsHomeOnlyWhenBothAreHome() {
    let displays = DisplaysFixture()
    let scope = displays.scope()
    #expect(scope.bindToCurrentDesktop())
    #expect(displays.readings.last?.tracksEachDisplay == true)
    #expect(displays.readings.last?.displaySpaces == [DisplaysFixture.builtIn: 1, DisplaysFixture.external: 5])

    displays.active = 5
    scope.invalidate()
    #expect(scope.refresh() == .home)

    displays.spaces[DisplaysFixture.external] = 6
    scope.invalidate()
    #expect(scope.refresh() == .away)

    displays.spaces[DisplaysFixture.external] = 5
    displays.spaces[DisplaysFixture.builtIn] = 2
    scope.invalidate()
    #expect(scope.refresh() == .away)

    displays.spaces[DisplaysFixture.builtIn] = nil
    scope.invalidate()
    #expect(scope.refresh() == .unknown)

    displays.spaces[DisplaysFixture.builtIn] = 1
    scope.invalidate()
    #expect(scope.refresh() == .home)
}

@MainActor @Test func desktopScopeWithOneDisplayReadsOnlyTheActiveSpace() {
    let displays = DisplaysFixture()
    displays.connected = [DisplaysFixture.builtIn]
    let scope = displays.scope()
    #expect(scope.bindToCurrentDesktop())
    #expect(displays.readings.last?.tracksEachDisplay == false)
    displays.displayReads = 0

    displays.active = 2
    scope.invalidate()
    #expect(scope.refresh() == .away)
    displays.active = 1
    scope.invalidate()
    #expect(scope.refresh() == .home)
    #expect(!scope.bind(displays: [DisplaysFixture.builtIn]))
    #expect(displays.displayReads == 0)
}

@MainActor @Test func desktopScopeBindsADisplayAddedLaterAtItsFirstArrangement() {
    let displays = DisplaysFixture()
    displays.connected = [DisplaysFixture.builtIn]
    let scope = displays.scope()
    #expect(scope.bindToCurrentDesktop())

    displays.connected = [DisplaysFixture.builtIn, DisplaysFixture.external]
    displays.spaces[DisplaysFixture.external] = 8
    displays.active = 8
    #expect(scope.bind(displays: displays.connected))
    #expect(displays.readings.count == 2)
    #expect(scope.refresh() == .home)

    displays.spaces[DisplaysFixture.external] = 9
    scope.invalidate()
    #expect(scope.refresh() == .away)

    // Unplugging the away display returns to one reading, in the remaining display's terms.
    displays.connected = [DisplaysFixture.builtIn]
    displays.active = 1
    #expect(scope.bind(displays: displays.connected))
    #expect(scope.refresh() == .home)
    displays.active = 3
    scope.invalidate()
    #expect(scope.refresh() == .away)
}

@MainActor @Test func desktopScopeUsesTheActiveSpaceWhenDisplaysShareSpaces() {
    let displays = DisplaysFixture()
    displays.separateSpaces = false
    let scope = displays.scope()
    #expect(scope.bindToCurrentDesktop())
    #expect(displays.readings.last?.tracksEachDisplay == false)
    #expect(displays.readings.last?.screensHaveSeparateSpaces == false)
    displays.displayReads = 0

    displays.spaces[DisplaysFixture.external] = 6
    scope.invalidate()
    #expect(scope.refresh() == .home)
    displays.active = 2
    scope.invalidate()
    #expect(scope.refresh() == .away)
    #expect(displays.displayReads == 0)
}

@MainActor @Test func desktopScopeFallsBackToTheActiveSpaceWithoutTheDisplayReader() {
    let displays = DisplaysFixture()
    displays.readerAvailable = false
    let scope = displays.scope()
    #expect(scope.bindToCurrentDesktop())
    #expect(displays.readings.last?.readerSymbol == nil)
    #expect(displays.readings.last?.tracksEachDisplay == false)
    #expect(displays.readings.last?.displaySpaces == [:])

    displays.active = 5
    scope.invalidate()
    #expect(scope.refresh() == .away)
}

@MainActor @Test func desktopScopeKeepsItsCacheWhileTrackingEachDisplay() {
    let displays = DisplaysFixture()
    var clock = ContinuousClock.Instant.now
    let scope = displays.scope(now: { clock })
    #expect(scope.bindToCurrentDesktop())
    displays.displayReads = 0

    displays.spaces[DisplaysFixture.external] = 6
    #expect(scope.refresh() == .home)
    #expect(displays.displayReads == 0)
    clock = clock.advanced(by: scope.cacheMaxAge)
    #expect(scope.refresh() == .away)
    #expect(displays.displayReads == 2)
}

@MainActor @Test func desktopScopeReportsReadingsWhenBindFails() {
    let displays = DisplaysFixture()
    displays.active = nil
    let scope = displays.scope()
    #expect(!scope.bindToCurrentDesktop())
    #expect(displays.readings.count == 1)
    #expect(displays.readings.last?.activeSpace == nil)
    #expect(!scope.bind(displays: [DisplaysFixture.builtIn]))
}
