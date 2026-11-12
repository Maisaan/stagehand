import AppKit
import Darwin
import Foundation
import StagehandCore

/// Which native Spaces a window is on, and what kind they are. Read-only private API; see
/// https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h. Accessibility lists only
/// an app's windows on the current Space, so a window in native full screen, which macOS
/// moves to a Space of its own, or a window on a Desktop the user is not on, is missing
/// from its app's window list there.
enum NativeSpaces {
    /// CGSSpaceGetType for a Space made by native full screen. Checked on macOS 27.0.1:
    /// a full-screen 1Password window's Space reported 4, the Desktop 0.
    static let fullScreenSpaceType: Int32 = 4

    struct Space: Equatable, Sendable {
        var id: UInt64
        var type: Int32
    }

    /// Where a window missing from its app's Accessibility list is.
    enum Placement: Equatable, Sendable {
        /// Only on full-screen Spaces: macOS owns it.
        case fullScreen
        /// On a Space the user is not on: unreachable now, not gone.
        case otherSpace
        /// On the current Space, or on no Space: missing for a reason Spaces do not explain.
        case currentSpace, nowhere
        /// WindowServer did not answer.
        case unknown
    }

    private struct Functions: Sendable {
        let spaces: @Sendable (UInt32) -> [Space]?
        let activeSpace: @Sendable () -> UInt64?
    }

    private static let functions: Functions = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionSymbol = dlsym(framework, "CGSMainConnectionID"),
              let spacesSymbol = dlsym(framework, "CGSCopySpacesForWindows"),
              let typeSymbol = dlsym(framework, "CGSSpaceGetType"),
              let activeSymbol = dlsym(framework, "CGSGetActiveSpace") else {
            return Functions(spaces: { _ in nil }, activeSpace: { nil })
        }
        // The framework reference is kept for process lifetime while the pointers are in use.
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        let spacesForWindows = unsafeBitCast(
            spacesSymbol, to: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        let spaceType = unsafeBitCast(typeSymbol, to: (@convention(c) (Int32, UInt64) -> Int32).self)
        let active = unsafeBitCast(activeSymbol, to: (@convention(c) (Int32) -> UInt64).self)
        /// kCGSAllSpacesMask: current and other Spaces.
        let allSpaces: Int32 = 7
        return Functions(
            spaces: { windowNumber in
                let client = connection()
                guard client != 0,
                      let ids = spacesForWindows(client, allSpaces, [NSNumber(value: windowNumber)] as CFArray)?
                          .takeRetainedValue() as? [NSNumber] else { return nil }
                return ids.map { Space(id: $0.uint64Value, type: spaceType(client, $0.uint64Value)) }
            },
            activeSpace: {
                let client = connection()
                guard client != 0 else { return nil }
                let id = active(client)
                return id == 0 ? nil : id
            })
    }()

    /// Every Space the window is on, or nil when WindowServer does not answer or the
    /// private symbols are missing. Empty when the window does not exist.
    static func spaces(windowNumber: UInt32) -> [Space]? { functions.spaces(windowNumber) }

    static func activeSpace() -> UInt64? { functions.activeSpace() }

    /// The Space each display shows. With one display, or with Spaces shared across
    /// displays, that is the active Space alone.
    @MainActor static func currentSpaces() -> Set<UInt64> {
        var current = Set([activeSpace()].compactMap { $0 })
        let displays = ManagedDisplaySpacesReader.connectedDisplays()
        if displays.count > 1, NSScreen.screensHaveSeparateSpaces,
           let displaySpace = ManagedDisplaySpacesReader.currentSpace {
            current.formUnion(displays.compactMap(displaySpace))
        }
        return current
    }

    /// Empty `currentSpaces` means WindowServer did not answer.
    static func placement(of spaces: [Space]?, currentSpaces: Set<UInt64>) -> Placement {
        guard let spaces else { return .unknown }
        guard !spaces.isEmpty else { return .nowhere }
        if spaces.allSatisfy({ $0.type == fullScreenSpaceType }) { return .fullScreen }
        guard !currentSpaces.isEmpty else { return .unknown }
        return spaces.contains { currentSpaces.contains($0.id) } ? .currentSpace : .otherSpace
    }
}

/// Each display's current native Space. With "Displays have separate Spaces" on,
/// CGSGetActiveSpace follows the display with keyboard focus, so it cannot tell a
/// Desktop switch on one display from focus moving to another.
enum ManagedDisplaySpacesReader {
    private struct Functions: Sendable {
        let symbol: String?
        let currentSpace: (@Sendable (DisplayID) -> UInt64?)?
        let managedDisplaySpaces: @Sendable () -> [String: UInt64]
        let displaySpaceLists: @Sendable () -> [[String: Any]]?
    }

    private static let functions: Functions = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionSymbol = dlsym(framework, "CGSMainConnectionID") else {
            return Functions(symbol: nil, currentSpace: nil, managedDisplaySpaces: { [:] }, displaySpaceLists: { nil })
        }
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        let names = ["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"]
        let resolved = names.lazy.compactMap { name in dlsym(framework, name).map { (name, $0) } }.first
        let currentSpace: (@Sendable (DisplayID) -> UInt64?)? = resolved.map { _, pointer in
            let read = unsafeBitCast(pointer, to: (@convention(c) (Int32, CFString) -> UInt64).self)
            return { display in
                let client = connection()
                guard client != 0 else { return nil }
                let id = read(client, display.rawValue as CFString)
                return id == 0 ? nil : id
            }
        }
        let copy = dlsym(framework, "CGSCopyManagedDisplaySpaces").map {
            unsafeBitCast($0, to: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
        }
        let displaySpaceLists: @Sendable () -> [[String: Any]]? = {
            guard let copy else { return nil }
            let client = connection()
            guard client != 0 else { return nil }
            return copy(client)?.takeRetainedValue() as? [[String: Any]]
        }
        let managedDisplaySpaces: @Sendable () -> [String: UInt64] = {
            guard let displays = displaySpaceLists() else { return [:] }
            var spaces: [String: UInt64] = [:]
            for display in displays {
                // "Display Identifier" is the UUID, or "Main" when displays share Spaces.
                guard let identifier = display["Display Identifier"] as? String,
                      let current = display["Current Space"] as? [String: Any],
                      let id = current["ManagedSpaceID"] as? NSNumber else { continue }
                spaces[identifier] = id.uint64Value
            }
            return spaces
        }
        return Functions(symbol: resolved?.0, currentSpace: currentSpace, managedDisplaySpaces: managedDisplaySpaces,
                         displaySpaceLists: displaySpaceLists)
    }()

    /// nil when neither private symbol resolves: per-display tracking is unavailable.
    static var currentSpace: (@Sendable (DisplayID) -> UInt64?)? { functions.currentSpace }

    static var symbol: String? { functions.symbol }

    /// For diagnostics only, keyed by WindowServer's display identifier.
    static func managedDisplaySpaces() -> [String: UInt64] { functions.managedDisplaySpaces() }

    /// Every display's Spaces in Mission Control order, or nil when WindowServer does not answer.
    static func displaySpaces() -> [DisplaySpaces]? { functions.displaySpaceLists().map(DisplaySpaces.parse) }

    /// Online displays, asleep ones included, without the copies of a mirror set, which
    /// have no Spaces of their own.
    static func connectedDisplays() -> [DisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var numbers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &numbers, &count) == .success else { return [] }
        return numbers.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .compactMap { number in
                guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
                      let string = CFUUIDCreateString(nil, uuid) else { return nil }
                return DisplayID(rawValue: string as String)
            }
    }
}

public extension DisplayID {
    /// Display UUIDs are logged by prefix only; names can carry a device owner's name.
    var logPrefix: String { String(rawValue.prefix(8)) }
}
