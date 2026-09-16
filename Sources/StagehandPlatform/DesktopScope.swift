import Foundation
import CoreGraphics
import Darwin

public enum DesktopRelation: Equatable, Sendable {
    case home
    case away
    case unknown
}

/// Tracks the native Desktop selected when Stagehand starts. Refreshing never rebinds it.
@MainActor
public final class DesktopScope {
    public private(set) var relation = DesktopRelation.unknown
    private let currentDesktopID: () -> UInt64?
    private let userSessionIsActive: () -> Bool
    private var homeDesktopID: UInt64?

    public init() {
        currentDesktopID = { NativeDesktopReader.currentID() }
        userSessionIsActive = { NativeUserSessionReader.isActive() }
    }

    init(currentDesktopID: @escaping () -> UInt64?, userSessionIsActive: @escaping () -> Bool = { true }) {
        self.currentDesktopID = currentDesktopID
        self.userSessionIsActive = userSessionIsActive
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
        return true
    }

    @discardableResult
    public func refresh() -> DesktopRelation {
        guard userSessionIsActive() else {
            // The session-active notification can arrive before WindowServer clears
            // its locked flag. Keep this retryable instead of treating the lock
            // screen as another Desktop.
            relation = .unknown
            return relation
        }
        guard let homeDesktopID, let id = currentDesktopID(), id != 0 else {
            relation = .unknown
            return relation
        }
        relation = id == homeDesktopID ? .home : .away
        return relation
    }

    public func reset() {
        homeDesktopID = nil
        relation = .unknown
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
