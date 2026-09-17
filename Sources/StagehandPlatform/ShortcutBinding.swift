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
        [Self.modifierLabel(modifiers), keyLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var isDefault: Bool {
        Self.defaultsByID[id] == self
    }

    public static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey | alphaLock)
    public static let preferenceKey = "shortcutBindings"

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
            .init(id: "reorderPrevious", title: "Move current window left", group: .windowOrder,
                  key: UInt32(kVK_LeftArrow), modifiers: base | command, keyLabel: "←", isEnabled: true,
                  action: .reorderPrevious),
            .init(id: "reorderNext", title: "Move current window right", group: .windowOrder,
                  key: UInt32(kVK_RightArrow), modifiers: base | command, keyLabel: "→", isEnabled: true,
                  action: .reorderNext),
            .init(id: "shrinkWidth", title: "Shrink window width", group: .windowSize,
                  key: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | cmdKey), keyLabel: "1",
                  isEnabled: true, action: .shrinkWidth),
            .init(id: "growWidth", title: "Grow window width", group: .windowSize,
                  key: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | cmdKey), keyLabel: "2",
                  isEnabled: true, action: .growWidth),
            .init(id: "togglePause", title: "Pause or restore windows", group: .stagehand,
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

    public static func load(from userDefaults: UserDefaults = .standard) -> [Self] {
        guard let data = userDefaults.data(forKey: preferenceKey),
              let saved = try? JSONDecoder().decode([SavedBinding].self, from: data) else {
            return defaults
        }
        let savedByID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bindings = defaults.map { defaultBinding in
            guard let value = savedByID[defaultBinding.id],
                  value.key <= UInt32(UInt16.max),
                  value.modifiers & ~supportedModifiers == 0,
                  !value.keyLabel.isEmpty,
                  value.keyLabel.count <= 12 else { return defaultBinding }
            var binding = defaultBinding
            binding.key = value.key
            binding.modifiers = value.modifiers
            binding.keyLabel = value.keyLabel
            binding.isEnabled = value.isEnabled
            return binding
        }
        var usedChords = Set<UInt64>()
        for index in bindings.indices where bindings[index].isEnabled {
            if !usedChords.insert(bindings[index].chord).inserted {
                bindings[index].isEnabled = false
            }
        }
        return bindings
    }

    public static func save(_ bindings: [Self], to userDefaults: UserDefaults = .standard) {
        let saved = bindings.map {
            SavedBinding(id: $0.id, key: $0.key, modifiers: $0.modifiers,
                         keyLabel: $0.keyLabel, isEnabled: $0.isEnabled)
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        userDefaults.set(data, forKey: preferenceKey)
    }

    public static func defaultBinding(id: String) -> Self? {
        defaultsByID[id]
    }

    public static func action(for event: CGEvent, in bindings: [Self] = defaults) -> NavigationAction? {
        let key = UInt32(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = carbonModifiers(for: event.flags)
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

    public static func modifierLabel(_ modifiers: UInt32) -> String {
        var labels: [String] = []
        if modifiers & UInt32(controlKey) != 0 { labels.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { labels.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { labels.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { labels.append("⌘") }
        if modifiers & UInt32(alphaLock) != 0 { labels.append("⇪") }
        return labels.joined(separator: " ")
    }

    var chord: UInt64 {
        UInt64(key) << 32 | UInt64(modifiers)
    }
}
