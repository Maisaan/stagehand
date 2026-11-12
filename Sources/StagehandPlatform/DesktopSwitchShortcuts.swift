import AppKit
import Foundation

/// A keyboard shortcut posted as real key events, as if typed.
public struct SpaceSwitchShortcut: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var flags: CGEventFlags

    public init(keyCode: CGKeyCode, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }

    public var displayName: String {
        let modifiers: [(CGEventFlags, String)] = [
            (.maskControl, "Control"), (.maskAlternate, "Option"), (.maskShift, "Shift"), (.maskCommand, "Command")
        ]
        let keyNames: [CGKeyCode: String] = [123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"]
        return (modifiers.filter { flags.contains($0.0) }.map(\.1) + [keyNames[keyCode] ?? "key code \(keyCode)"])
            .joined(separator: "+")
    }

    /// False when CoreGraphics could not make the events.
    public func post() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let events = [true, false].compactMap { CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: $0) }
        guard events.count == 2 else { return false }
        for event in events {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Mission Control's "Move left a space" and "Move right a space".
public enum SpaceSwitchDirection: String, Equatable, Sendable {
    case left, right

    public var opposite: SpaceSwitchDirection { self == .left ? .right : .left }

    var settingName: String { "Move \(rawValue) a space" }

    var symbolicHotKeyID: String { self == .left ? "79" : "81" }
}

public enum SymbolicHotKeyReading: Equatable, Sendable {
    case bound(SpaceSwitchShortcut)
    case disabled
    case unbound
    case missing
}

/// The system keyboard shortcuts in the com.apple.symbolichotkeys preferences. Each entry
/// is `{enabled, value = {parameters = (character, key code, modifier flags)}}`.
public enum SymbolicHotKeys {
    private static let noKeyCode = 65_535
    private static let modifierMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskNumericPad, .maskSecondaryFn
    ]

    public static func current() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
            as? [String: Any]
    }

    public static func reading(_ direction: SpaceSwitchDirection, in hotKeys: [String: Any]?) -> SymbolicHotKeyReading {
        guard let entry = hotKeys?[direction.symbolicHotKeyID] as? [String: Any] else { return .missing }
        guard (entry["enabled"] as? NSNumber)?.boolValue == true else { return .disabled }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3,
              parameters[1].intValue != noKeyCode,
              let keyCode = CGKeyCode(exactly: parameters[1].intValue) else { return .unbound }
        let flags = CGEventFlags(rawValue: parameters[2].uint64Value).intersection(modifierMask)
        return .bound(SpaceSwitchShortcut(keyCode: keyCode, flags: flags))
    }
}

/// One display's Spaces in Mission Control order, as WindowServer lists them.
public struct DisplaySpaces: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public var id: UInt64
        public var isDesktop: Bool

        public init(id: UInt64, isDesktop: Bool) {
            self.id = id
            self.isDesktop = isDesktop
        }
    }

    /// The display's UUID, or "Main" when displays share Spaces.
    public var identifier: String
    public var currentSpaceID: UInt64?
    public var spaces: [Space]

    public init(identifier: String, currentSpaceID: UInt64?, spaces: [Space]) {
        self.identifier = identifier
        self.currentSpaceID = currentSpaceID
        self.spaces = spaces
    }

    /// CGSSpaceGetType's value for an ordinary Desktop.
    private static let desktopType = 0

    static func parse(_ displays: [[String: Any]]) -> [DisplaySpaces] {
        displays.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber
            let spaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = space["ManagedSpaceID"] as? NSNumber else { return nil }
                return Space(id: id.uint64Value, isDesktop: (space["type"] as? NSNumber)?.intValue == desktopType)
            }
            return DisplaySpaces(identifier: identifier, currentSpaceID: current?.uint64Value, spaces: spaces)
        }
    }

    public static func current() -> [DisplaySpaces]? { ManagedDisplaySpacesReader.displaySpaces() }

    public static func identifier(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

public struct DesktopSwitchPlan: Equatable, Sendable {
    public var direction: SpaceSwitchDirection
    public var away: SpaceSwitchShortcut
    public var back: SpaceSwitchShortcut
}

public enum DesktopSwitchReadiness: Equatable, Sendable {
    case ready(DesktopSwitchPlan)
    case notRun(String)

    /// Leaves toward the neighboring Space that exists, rightward when both do, and
    /// needs both directions' shortcuts so it can come back.
    public static func check(displays: [DisplaySpaces]?, builtInIdentifier: String?,
                             hotKeys: [String: Any]?) -> DesktopSwitchReadiness {
        guard let displays else { return .notRun("WindowServer did not list the Desktops") }
        let builtIn = displays.first { display in
            builtInIdentifier.map { display.identifier.caseInsensitiveCompare($0) == .orderedSame } == true
        } ?? (displays.count == 1 ? displays[0] : nil)
        guard let builtIn else { return .notRun("could not find the built-in display's Desktops") }
        guard builtIn.spaces.filter(\.isDesktop).count >= 2 else {
            return .notRun("the built-in display has one Desktop; add a second in Mission Control")
        }
        guard let current = builtIn.currentSpaceID,
              let index = builtIn.spaces.firstIndex(where: { $0.id == current }) else {
            return .notRun("the built-in display's current Desktop is unknown")
        }
        let direction: SpaceSwitchDirection = index + 1 < builtIn.spaces.count ? .right : .left
        let away = SymbolicHotKeys.reading(direction, in: hotKeys)
        let back = SymbolicHotKeys.reading(direction.opposite, in: hotKeys)
        guard case .bound(let awayShortcut) = away else { return .notRun(unusable(direction, away)) }
        guard case .bound(let backShortcut) = back else { return .notRun(unusable(direction.opposite, back)) }
        return .ready(DesktopSwitchPlan(direction: direction, away: awayShortcut, back: backShortcut))
    }

    private static func unusable(_ side: SpaceSwitchDirection, _ reading: SymbolicHotKeyReading) -> String {
        let location = "System Settings > Keyboard > Keyboard Shortcuts > Mission Control"
        switch reading {
        case .bound: return "\"\(side.settingName)\" is usable"
        case .disabled: return "\"\(side.settingName)\" is off in \(location)"
        case .unbound: return "\"\(side.settingName)\" has no key in \(location)"
        case .missing: return "\"\(side.settingName)\" is not in com.apple.symbolichotkeys; turn it off and on in \(location)"
        }
    }
}
