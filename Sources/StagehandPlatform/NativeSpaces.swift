import Darwin
import Foundation

/// Which native Spaces a window is on, and what kind they are. Read-only private API; see
/// https://github.com/NUIKit/CGSInternal/blob/master/CGSSpace.h. Accessibility lists only
/// an app's windows on the current Space, so a window in native full screen, which macOS
/// moves to a Space of its own, is missing from its app's window list everywhere else.
enum NativeSpaces {
    /// CGSSpaceGetType for a Space made by native full screen. Checked on macOS 27.0.1:
    /// a full-screen 1Password window's Space reported 4, the Desktop 0.
    static let fullScreenSpaceType: Int32 = 4

    /// The types of every Space the window is on, or nil when WindowServer does not
    /// answer or the private symbols are missing. Empty when the window does not exist.
    static let spaceTypes: @Sendable (UInt32) -> [Int32]? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionSymbol = dlsym(framework, "CGSMainConnectionID"),
              let spacesSymbol = dlsym(framework, "CGSCopySpacesForWindows"),
              let typeSymbol = dlsym(framework, "CGSSpaceGetType") else {
            return { _ in nil }
        }
        // The framework reference is kept for process lifetime while the pointers are in use.
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        let spacesForWindows = unsafeBitCast(
            spacesSymbol, to: (@convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?).self)
        let spaceType = unsafeBitCast(typeSymbol, to: (@convention(c) (Int32, UInt64) -> Int32).self)
        /// kCGSAllSpacesMask: current and other Spaces.
        let allSpaces: Int32 = 7
        return { windowNumber in
            let client = connection()
            guard client != 0,
                  let spaces = spacesForWindows(client, allSpaces, [NSNumber(value: windowNumber)] as CFArray)?
                      .takeRetainedValue() as? [NSNumber] else { return nil }
            return spaces.map { spaceType(client, $0.uint64Value) }
        }
    }()

    /// The window exists and every Space it is on is a full-screen one.
    static func isInFullScreen(spaceTypes: [Int32]?) -> Bool {
        guard let spaceTypes, !spaceTypes.isEmpty else { return false }
        return spaceTypes.allSatisfy { $0 == fullScreenSpaceType }
    }
}
