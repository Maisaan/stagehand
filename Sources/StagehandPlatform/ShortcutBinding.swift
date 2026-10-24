import AppKit
import Carbon
import StagehandCore

public struct ShortcutBinding: Identifiable, Equatable, Sendable {
    public enum Group: String, Hashable, Sendable {
        case windowNavigation
        case spaceNavigation
        case windowOrder
        case spaceSwitching
        case spaceSharing
        case spaceMoving
        case windowSize
        case stagehand
    }

    public let id: String
    public let title: String
    public let group: Group
    public var key: UInt32
    public var modifiers: UInt32
    public var keyLabel: String
    public var isEnabled: Bool
    public let action: NavigationAction

    public var label: String {
        let displayedModifiers = keyLabel == "+" ? modifiers & ~UInt32(shiftKey) : modifiers
        return [Self.modifierLabel(displayedModifiers), keyLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var isDefault: Bool {
        Self.defaultsByID[id] == self
    }

    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey | alphaLock)
    /// A chord needs one of these. Shift and Caps Lock alone would capture ordinary typing.
    static let requiredModifiers = UInt32(controlKey | optionKey | cmdKey)
    /// Virtual key codes above this are not keyboard keys.
    static let maximumVirtualKeyCode: UInt32 = 0x7F
    /// Chords macOS owns. Consuming them would hide quitting, closing, switching, and Spotlight.
    static let systemChords: [(key: UInt32, modifiers: UInt32, label: String)] = [
        (UInt32(kVK_ANSI_Q), UInt32(cmdKey), "⌘ Q"),
        (UInt32(kVK_ANSI_W), UInt32(cmdKey), "⌘ W"),
        (UInt32(kVK_Tab), UInt32(cmdKey), "⌘ Tab"),
        (UInt32(kVK_Space), UInt32(cmdKey), "⌘ Space"),
        (UInt32(kVK_ANSI_H), UInt32(cmdKey), "⌘ H"),
        (UInt32(kVK_ANSI_M), UInt32(cmdKey), "⌘ M"),
        (UInt32(kVK_ANSI_Q), UInt32(controlKey | cmdKey), "⌃ ⌘ Q"),
        (UInt32(kVK_Escape), UInt32(optionKey | cmdKey), "⌥ ⌘ Esc"),
    ]
    public static let preferenceKey = "shortcutBindings"
    private static let preferenceVersionKey = "shortcutBindingsVersion"
    private static let preferenceVersion = 1

    public static let defaults: [Self] = {
        let base = UInt32(controlKey | optionKey)
        let command = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        var bindings: [Self] = [
            .init(id: "focusPrevious", title: "Previous window", group: .windowNavigation,
                  key: UInt32(kVK_LeftArrow), modifiers: base, keyLabel: "←", isEnabled: true,
                  action: .focusPrevious),
            .init(id: "focusNext", title: "Next window", group: .windowNavigation,
                  key: UInt32(kVK_RightArrow), modifiers: base, keyLabel: "→", isEnabled: true,
                  action: .focusNext),
            .init(id: "previousSpace", title: "Previous space", group: .spaceNavigation,
                  key: UInt32(kVK_UpArrow), modifiers: base, keyLabel: "↑", isEnabled: true,
                  action: .previousSpace),
            .init(id: "nextSpace", title: "Next space", group: .spaceNavigation,
                  key: UInt32(kVK_DownArrow), modifiers: base, keyLabel: "↓", isEnabled: true,
                  action: .nextSpace),
            .init(id: "moveWindowUpSpace", title: "Move current window up one space", group: .spaceNavigation,
                  key: UInt32(kVK_UpArrow), modifiers: base | command, keyLabel: "↑", isEnabled: true,
                  action: .moveWindowUpSpace),
            .init(id: "moveWindowDownSpace", title: "Move current window down one space", group: .spaceNavigation,
                  key: UInt32(kVK_DownArrow), modifiers: base | command, keyLabel: "↓", isEnabled: true,
                  action: .moveWindowDownSpace),
            .init(id: "reorderPrevious", title: "Move current window left", group: .windowOrder,
                  key: UInt32(kVK_LeftArrow), modifiers: base | command, keyLabel: "←", isEnabled: true,
                  action: .reorderPrevious),
            .init(id: "reorderNext", title: "Move current window right", group: .windowOrder,
                  key: UInt32(kVK_RightArrow), modifiers: base | command, keyLabel: "→", isEnabled: true,
                  action: .reorderNext),
            .init(id: "shrinkWidth", title: "Shrink window width", group: .windowSize,
                  key: UInt32(kVK_ANSI_Minus), modifiers: base, keyLabel: "-",
                  isEnabled: true, action: .shrinkWidth),
            .init(id: "growWidth", title: "Grow window width", group: .windowSize,
                  key: UInt32(kVK_ANSI_Equal), modifiers: base | shift, keyLabel: "+",
                  isEnabled: true, action: .growWidth),
            .init(id: "shrinkHeight", title: "Shrink window height", group: .windowSize,
                  key: UInt32(kVK_ANSI_Minus), modifiers: base | command, keyLabel: "-",
                  isEnabled: true, action: .shrinkHeight),
            .init(id: "growHeight", title: "Grow window height", group: .windowSize,
                  key: UInt32(kVK_ANSI_Equal), modifiers: base | command | shift, keyLabel: "+",
                  isEnabled: true, action: .growHeight),
            .init(id: "nextWidthPreset", title: "Next width preset", group: .windowSize,
                  key: UInt32(kVK_ANSI_0), modifiers: base, keyLabel: "0",
                  isEnabled: true, action: .nextWidthPreset),
            .init(id: "previousWidthPreset", title: "Previous width preset", group: .windowSize,
                  key: UInt32(kVK_ANSI_0), modifiers: base | shift, keyLabel: "0",
                  isEnabled: true, action: .previousWidthPreset),
            .init(id: "togglePause", title: "Start or pause Stagehand", group: .stagehand,
                  key: UInt32(kVK_Escape), modifiers: base, keyLabel: "esc", isEnabled: true,
                  action: .togglePause),
            .init(id: "showSettings", title: "Open settings", group: .stagehand,
                  key: UInt32(kVK_ANSI_Comma), modifiers: base, keyLabel: ",", isEnabled: true,
                  action: .showSettings),
        ]
        let numbers = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                       kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in numbers.enumerated() {
            let number = index + 1
            bindings.append(.init(
                id: "goToSpace.\(number)", title: "Switch to space \(number)", group: .spaceSwitching,
                key: UInt32(key), modifiers: base, keyLabel: "\(number)", isEnabled: true,
                action: .goToSpace(index: index)
            ))
            bindings.append(.init(
                id: "shareToSpace.\(number)", title: "Share window with space \(number)", group: .spaceSharing,
                key: UInt32(key), modifiers: base | shift, keyLabel: "\(number)", isEnabled: true,
                action: .shareToSpace(index: index)
            ))
            bindings.append(.init(
                id: "moveToSpace.\(number)", title: "Move window to space \(number)", group: .spaceMoving,
                key: UInt32(key), modifiers: base | command, keyLabel: "\(number)", isEnabled: true,
                action: .moveToSpace(index: index, follow: true)
            ))
        }
        return bindings
    }()

    private struct SavedBinding: Codable {
        let id: String
        let key: UInt32
        let modifiers: UInt32
        let keyLabel: String
        let isEnabled: Bool
    }

    private static let defaultsByID = Dictionary(uniqueKeysWithValues: defaults.map { ($0.id, $0) })

    /// The user-facing reason a chord cannot be a Stagehand shortcut, or nil when it can.
    public static func validationIssue(key: UInt32, modifiers: UInt32, keyLabel: String) -> String? {
        guard key <= maximumVirtualKeyCode else { return "That key isn't supported." }
        guard modifiers & ~supportedModifiers == 0 else { return "That modifier isn't supported." }
        guard modifiers & requiredModifiers != 0 else {
            return "Add Control, Option, or Command to the shortcut. Shift and Caps Lock only work together with one of those."
        }
        let withoutCapsLock = modifiers & ~UInt32(alphaLock)
        if let system = systemChords.first(where: { $0.key == key && $0.modifiers == withoutCapsLock }) {
            return "\(system.label) is a macOS shortcut and can't be reassigned."
        }
        guard !keyLabel.isEmpty, keyLabel.count <= 12 else { return "That key isn't supported." }
        return nil
    }

    /// Caps Lock is optional when matching, so two chords that differ only by Caps Lock
    /// would both fire for the same press.
    public static func conflict(in bindings: [Self], key: UInt32, modifiers: UInt32, excluding id: String) -> Self? {
        let chord = Self.chord(key: key, modifiers: modifiers)
        return bindings.first { $0.id != id && $0.isEnabled && $0.chordIgnoringCapsLock == chord }
    }

    public struct LoadResult: Sendable {
        public let bindings: [ShortcutBinding]
        /// Saved bindings that were turned off or replaced, in user-facing words.
        public let issues: [String]
    }

    /// Saved chords that fail validation revert to their default chord and are turned off,
    /// so a stale or hand-edited preference can never capture ordinary typing or a system chord.
    public static func loadReportingIssues(from userDefaults: UserDefaults = .standard) -> LoadResult {
        guard let data = userDefaults.data(forKey: preferenceKey) else {
            return LoadResult(bindings: defaults, issues: [])
        }
        guard let saved = try? JSONDecoder().decode([SavedBinding].self, from: data) else {
            return LoadResult(bindings: defaults, issues: ["Saved shortcuts couldn't be read, so the defaults are in use."])
        }
        var issues: [String] = []
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shouldMigrateLegacyWidthBindings = userDefaults.integer(forKey: preferenceVersionKey) < preferenceVersion
        var migrated = false
        var bindings = defaults.map { defaultBinding in
            guard let value = savedByID[defaultBinding.id] else { return defaultBinding }
            var binding = defaultBinding
            if let issue = validationIssue(key: value.key, modifiers: value.modifiers, keyLabel: value.keyLabel) {
                binding.isEnabled = false
                issues.append("\(defaultBinding.title) was turned off because its saved shortcut isn't allowed. \(issue)")
                return binding
            }
            if shouldMigrateLegacyWidthBindings,
               Self.isLegacyWidthDefault(id: value.id, key: value.key, modifiers: value.modifiers) {
                migrated = true
            } else {
                binding.key = value.key
                binding.modifiers = value.modifiers
                binding.keyLabel = value.keyLabel
            }
            binding.isEnabled = value.isEnabled
            return binding
        }
        var usedChords: [UInt64: String] = [:]
        for index in bindings.indices where bindings[index].isEnabled {
            let chord = bindings[index].chordIgnoringCapsLock
            if let owner = usedChords[chord] {
                bindings[index].isEnabled = false
                issues.append("\(bindings[index].title) was turned off because \(bindings[index].label) is also assigned to \(owner).")
            } else {
                usedChords[chord] = bindings[index].title
            }
        }
        if migrated { save(bindings, to: userDefaults) }
        return LoadResult(bindings: bindings, issues: issues)
    }

    public static func save(_ bindings: [Self], to userDefaults: UserDefaults = .standard) {
        let saved = bindings.map {
            SavedBinding(id: $0.id, key: $0.key, modifiers: $0.modifiers,
                         keyLabel: $0.keyLabel, isEnabled: $0.isEnabled)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        userDefaults.set(data, forKey: preferenceKey)
        userDefaults.set(preferenceVersion, forKey: preferenceVersionKey)
    }

    public static func defaultBinding(id: String) -> Self? {
        defaultsByID[id]
    }

    public static func action(for event: CGEvent, in bindings: [Self] = defaults) -> NavigationAction? {
        let key = UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = carbonModifiers(for: event.flags)
        return action(forKey: key, modifiers: modifiers, in: bindings)
    }

    static func action(forKey key: UInt32, modifiers: UInt32, in bindings: [Self]) -> NavigationAction? {
        if let exact = bindings.first(where: {
            $0.isEnabled && $0.key == key && $0.modifiers == modifiers
        }) {
            return exact.action
        }
        guard modifiers & UInt32(alphaLock) != 0 else { return nil }
        let withoutCapsLock = modifiers & ~UInt32(alphaLock)
        return bindings.first {
            $0.isEnabled && $0.key == key && $0.modifiers == withoutCapsLock
        }?.action
    }

    public static func carbonModifiers(for flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock) }
        return modifiers
    }

    static func modifierLabel(_ modifiers: UInt32) -> String {
        var labels: [String] = []
        if modifiers & UInt32(controlKey) != 0 { labels.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { labels.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { labels.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { labels.append("⌘") }
        if modifiers & UInt32(alphaLock) != 0 { labels.append("⇪") }
        return labels.joined(separator: " ")
    }

    var chordIgnoringCapsLock: UInt64 {
        Self.chord(key: key, modifiers: modifiers)
    }

    private static func chord(key: UInt32, modifiers: UInt32) -> UInt64 {
        UInt64(key) << 32 | UInt64(modifiers & ~UInt32(alphaLock))
    }

    private static func isLegacyWidthDefault(id: String, key: UInt32, modifiers: UInt32) -> Bool {
        switch id {
        case "shrinkWidth":
            key == UInt32(kVK_ANSI_1) && modifiers == UInt32(optionKey | cmdKey)
        case "growWidth":
            key == UInt32(kVK_ANSI_2) && modifiers == UInt32(optionKey | cmdKey)
        default:
            false
        }
    }
}
