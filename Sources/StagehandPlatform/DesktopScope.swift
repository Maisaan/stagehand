import AppKit
import CoreGraphics
import Darwin
import StagehandCore

public enum DesktopRelation: Equatable, Sendable {
    case home
    case away
    case unknown
}

/// Where each display's current Space is read from. `currentSpace` is nil when the
/// private per-display symbol is missing.
public struct DisplaySpaceSource {
    public var connectedDisplays: () -> [DisplayID]
    public var screensHaveSeparateSpaces: () -> Bool
    public var currentSpace: ((DisplayID) -> UInt64?)?
    public var readerSymbol: String?
    public var managedDisplaySpaces: () -> [String: UInt64]

    public init(connectedDisplays: @escaping () -> [DisplayID],
                screensHaveSeparateSpaces: @escaping () -> Bool,
                currentSpace: ((DisplayID) -> UInt64?)?,
                readerSymbol: String? = nil,
                managedDisplaySpaces: @escaping () -> [String: UInt64] = { [:] }) {
        self.connectedDisplays = connectedDisplays
        self.screensHaveSeparateSpaces = screensHaveSeparateSpaces
        self.currentSpace = currentSpace
        self.readerSymbol = readerSymbol
        self.managedDisplaySpaces = managedDisplaySpaces
    }

    /// No displays to track: the active Space alone decides, as with one display.
    public static var activeSpaceOnly: DisplaySpaceSource {
        DisplaySpaceSource(connectedDisplays: { [] }, screensHaveSeparateSpaces: { true }, currentSpace: nil)
    }

    @MainActor public static let system = DisplaySpaceSource(
        connectedDisplays: { ManagedDisplaySpacesReader.connectedDisplays() },
        screensHaveSeparateSpaces: { NSScreen.screensHaveSeparateSpaces },
        currentSpace: ManagedDisplaySpacesReader.currentSpace,
        readerSymbol: ManagedDisplaySpacesReader.symbol,
        managedDisplaySpaces: { ManagedDisplaySpacesReader.managedDisplaySpaces() })
}

/// What WindowServer reported when the scope bound its displays.
public struct NativeSpaceReadings: Equatable, Sendable {
    public var activeSpace: UInt64?
    public var displaySpaces: [DisplayID: UInt64]
    public var managedDisplaySpaces: [String: UInt64]
    public var screensHaveSeparateSpaces: Bool
    public var readerSymbol: String?
    public var tracksEachDisplay: Bool
}

/// Tracks the native Desktop each display showed when Stagehand started. Refreshing
/// never rebinds it. The relation is home only when every tracked display is on its
/// home Desktop, so a switch on one display suspends every display.
///
/// A home or away answer is reused for `cacheMaxAge` unless `invalidate()` is
/// called first; the model calls it on every Desktop, session, lock and sleep
/// notification. Unknown is never cached: the lock screen clears its flag
/// after the session notification, so those callers must keep re-reading.
@MainActor
public final class DesktopScope {
    public private(set) var relation = DesktopRelation.unknown
    /// How long a home or away answer stands without a notification. One switch
    /// asks several times; a missed notification costs at most this much.
    public var cacheMaxAge: Duration = .milliseconds(250)
    public var onReadings: ((NativeSpaceReadings) -> Void)?
    private let currentDesktopID: () -> UInt64?
    private let displaySource: DisplaySpaceSource
    private let userSessionIsActive: () -> Bool
    private let now: () -> ContinuousClock.Instant
    /// The active Space at bind, compared while one reading covers every display.
    private var homeDesktopID: UInt64?
    private var trackedDisplays: [DisplayID] = []
    private var displayHomes: [DisplayID: UInt64] = [:]
    private var screensHaveSeparateSpaces = true
    private var answeredAt: ContinuousClock.Instant?

    public init() {
        currentDesktopID = { NativeDesktopReader.currentID() }
        displaySource = .system
        userSessionIsActive = { NativeUserSessionReader.isActive() }
        now = { .now }
    }

    public init(currentDesktopID: @escaping () -> UInt64?, displaySource: DisplaySpaceSource = .activeSpaceOnly,
                userSessionIsActive: @escaping () -> Bool = { true },
                now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.currentDesktopID = currentDesktopID
        self.displaySource = displaySource
        self.userSessionIsActive = userSessionIsActive
        self.now = now
    }

    public var connectedDisplays: [DisplayID] { displaySource.connectedDisplays() }

    public func bindToCurrentDesktop() -> Bool {
        // Repeated starts must not silently adopt a different Desktop. Only reset permits
        // an explicit new binding, such as after the user has disabled Stagehand.
        if homeDesktopID != nil {
            bind(displays: connectedDisplays)
            return refresh() == .home
        }
        screensHaveSeparateSpaces = displaySource.screensHaveSeparateSpaces()
        let displays = connectedDisplays
        let activeSpace = currentDesktopID().flatMap { $0 == 0 ? nil : $0 }
        let displaySpaces = readDisplaySpaces(displays)
        defer { reportReadings(activeSpace: activeSpace, displaySpaces: displaySpaces) }
        guard let activeSpace else {
            relation = .unknown
            return false
        }
        homeDesktopID = activeSpace
        trackedDisplays = displays
        displayHomes = displaySpaces
        relation = .home
        answeredAt = now()
        return true
    }

    /// Tracks exactly `displays`: a display seen for the first time is bound to the
    /// Desktop it shows now, and a removed one is forgotten. Returns whether the set changed.
    @discardableResult
    public func bind(displays: [DisplayID]) -> Bool {
        guard homeDesktopID != nil, Set(displays) != Set(trackedDisplays) else { return false }
        let wasTrackingEachDisplay = tracksEachDisplay
        let added = displays.filter { !trackedDisplays.contains($0) }
        let addedSpaces = readDisplaySpaces(added)
        trackedDisplays = displays
        displayHomes = displayHomes.filter { displays.contains($0.key) }.merging(addedSpaces) { old, _ in old }
        // Back to one reading: the remaining display's home is in the per-display reader's terms.
        if wasTrackingEachDisplay, !tracksEachDisplay, displays.count == 1, let home = displayHomes[displays[0]] {
            homeDesktopID = home
        }
        answeredAt = nil
        reportReadings(activeSpace: currentDesktopID().flatMap { $0 == 0 ? nil : $0 },
                       displaySpaces: readDisplaySpaces(displays))
        return true
    }

    @discardableResult
    public func refresh() -> DesktopRelation {
        if let answeredAt, relation != .unknown, now() - answeredAt < cacheMaxAge { return relation }
        // Both reads are WindowServer round trips; a loaded WindowServer answers late.
        guard MainThreadActivity.during("desktopScope session", userSessionIsActive) else {
            // The session-active notification can arrive before WindowServer clears
            // its locked flag. Keep this retryable instead of treating the lock
            // screen as another Desktop.
            relation = .unknown
            answeredAt = nil
            return relation
        }
        guard let homeDesktopID else {
            relation = .unknown
            answeredAt = nil
            return relation
        }
        let home: Bool?
        if tracksEachDisplay, let currentSpace = displaySource.currentSpace {
            let displays = trackedDisplays
            let spaces = MainThreadActivity.during("desktopScope displaySpaces") { displays.map(currentSpace) }
            home = spaces.contains { $0 == nil || $0 == 0 }
                ? nil : zip(displays, spaces).allSatisfy { displayHomes[$0] == $1 }
        } else {
            let id = MainThreadActivity.during("desktopScope activeSpace", currentDesktopID)
            home = id == nil || id == 0 ? nil : id == homeDesktopID
        }
        guard let home else {
            relation = .unknown
            answeredAt = nil
            return relation
        }
        relation = home ? .home : .away
        answeredAt = now()
        return relation
    }

    /// The Desktop or session may have changed: the next refresh reads again.
    public func invalidate() {
        answeredAt = nil
    }

    public func reset() {
        homeDesktopID = nil
        trackedDisplays = []
        displayHomes = [:]
        relation = .unknown
        answeredAt = nil
    }

    /// With Spaces shared across displays, or one display, the active Space is every
    /// display's Space. A display whose reading failed at bind keeps that single reading.
    private var tracksEachDisplay: Bool {
        screensHaveSeparateSpaces && trackedDisplays.count > 1 && displaySource.currentSpace != nil
            && trackedDisplays.allSatisfy { displayHomes[$0] != nil }
    }

    private func readDisplaySpaces(_ displays: [DisplayID]) -> [DisplayID: UInt64] {
        guard let currentSpace = displaySource.currentSpace else { return [:] }
        var spaces: [DisplayID: UInt64] = [:]
        for display in displays {
            if let id = currentSpace(display), id != 0 { spaces[display] = id }
        }
        return spaces
    }

    private func reportReadings(activeSpace: UInt64?, displaySpaces: [DisplayID: UInt64]) {
        guard let onReadings else { return }
        onReadings(NativeSpaceReadings(
            activeSpace: activeSpace, displaySpaces: displaySpaces,
            managedDisplaySpaces: displaySource.managedDisplaySpaces(),
            screensHaveSeparateSpaces: screensHaveSeparateSpaces,
            readerSymbol: displaySource.currentSpace == nil ? nil : displaySource.readerSymbol,
            tracksEachDisplay: tracksEachDisplay))
    }
}

enum NativeUserSessionReader {
    static func isActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true
    }
}

@MainActor
private enum NativeDesktopReader {
    // Read-only private API declarations are recorded in:
    // https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h
    // https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c
    // IDs are native Space identities, not their reorderable Mission Control positions.
    // With separate Spaces this follows the display with keyboard focus.
    static let currentID: () -> UInt64? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionSymbol = dlsym(framework, "CGSMainConnectionID"),
              let spaceSymbol = dlsym(framework, "CGSGetActiveSpace") else {
            return { nil }
        }
        // Keep this one framework reference for process lifetime while the function pointers
        // are in use. Loading failure or an unavailable WindowServer returns unknown.
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        let activeSpace = unsafeBitCast(spaceSymbol, to: (@convention(c) (Int32) -> UInt64).self)
        return {
            let client = connection()
            guard client != 0 else { return nil }
            let id = activeSpace(client)
            return id == 0 ? nil : id
        }
    }()
}
