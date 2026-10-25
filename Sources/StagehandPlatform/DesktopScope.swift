import Foundation
import CoreGraphics
import Darwin

public enum DesktopRelation: Equatable, Sendable {
    case home
    case away
    case unknown
}

/// Tracks the native Desktop selected when Stagehand starts. Refreshing never rebinds it.
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
    private let currentDesktopID: () -> UInt64?
    private let userSessionIsActive: () -> Bool
    private let now: () -> ContinuousClock.Instant
    private var homeDesktopID: UInt64?
    private var answeredAt: ContinuousClock.Instant?

    public init() {
        currentDesktopID = { NativeDesktopReader.currentID() }
        userSessionIsActive = { NativeUserSessionReader.isActive() }
        now = { .now }
    }

    public init(currentDesktopID: @escaping () -> UInt64?, userSessionIsActive: @escaping () -> Bool = { true },
                now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.currentDesktopID = currentDesktopID
        self.userSessionIsActive = userSessionIsActive
        self.now = now
    }

    public func bindToCurrentDesktop() -> Bool {
        // Repeated starts must not silently adopt a different Desktop. Only reset permits
        // an explicit new binding, such as after the user has disabled Stagehand.
        if homeDesktopID != nil { return refresh() == .home }
        guard let id = currentDesktopID(), id != 0 else {
            relation = .unknown
            return false
        }
        homeDesktopID = id
        relation = .home
        answeredAt = now()
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
        guard let homeDesktopID, let id = MainThreadActivity.during("desktopScope activeSpace", currentDesktopID),
              id != 0 else {
            relation = .unknown
            answeredAt = nil
            return relation
        }
        relation = id == homeDesktopID ? .home : .away
        answeredAt = now()
        return relation
    }

    /// The Desktop or session may have changed: the next refresh reads again.
    public func invalidate() {
        answeredAt = nil
    }

    public func reset() {
        homeDesktopID = nil
        relation = .unknown
        answeredAt = nil
    }
}

private enum NativeUserSessionReader {
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
    // This intentionally covers only the MVP's single-display configuration.
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
