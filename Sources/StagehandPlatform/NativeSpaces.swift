import Darwin
import Foundation

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

    static func placement(of spaces: [Space]?, activeSpace: UInt64?) -> Placement {
        guard let spaces else { return .unknown }
        guard !spaces.isEmpty else { return .nowhere }
        if spaces.allSatisfy({ $0.type == fullScreenSpaceType }) { return .fullScreen }
        guard let activeSpace else { return .unknown }
        return spaces.contains { $0.id == activeSpace } ? .currentSpace : .otherSpace
    }
}
