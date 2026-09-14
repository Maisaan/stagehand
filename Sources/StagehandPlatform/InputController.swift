import AppKit
import Carbon
import StagehandCore

struct ShortcutBinding: Sendable {
    var key: UInt32
    var modifiers: UInt32
    var action: NavigationAction
    var label: String

    static let defaults: [Self] = {
        let base = UInt32(controlKey | optionKey)
        let command = UInt32(cmdKey)
        let shift = UInt32(shiftKey)
        var bindings: [Self] = [
            .init(key: UInt32(kVK_LeftArrow), modifiers: base, action: .focusPrevious, label: "⌃⌥←"),
            .init(key: UInt32(kVK_RightArrow), modifiers: base, action: .focusNext, label: "⌃⌥→"),
            .init(key: UInt32(kVK_UpArrow), modifiers: base, action: .previousSpace, label: "⌃⌥↑"),
            .init(key: UInt32(kVK_DownArrow), modifiers: base, action: .nextSpace, label: "⌃⌥↓"),
            .init(key: UInt32(kVK_LeftArrow), modifiers: base | command, action: .reorderPrevious, label: "⌃⌥⌘←"),
            .init(key: UInt32(kVK_RightArrow), modifiers: base | command, action: .reorderNext, label: "⌃⌥⌘→"),
            .init(key: UInt32(kVK_ANSI_1), modifiers: UInt32(optionKey | cmdKey), action: .shrinkWidth, label: "⌥⌘1"),
            .init(key: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | cmdKey), action: .growWidth, label: "⌥⌘2"),
            .init(key: UInt32(kVK_Escape), modifiers: base, action: .togglePause, label: "⌃⌥Escape"),
            .init(key: UInt32(kVK_ANSI_Comma), modifiers: base, action: .showSettings, label: "⌃⌥,"),
        ]
        let numbers = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in numbers.enumerated() {
            bindings.append(.init(key: UInt32(key), modifiers: base, action: .goToSpace(index: index), label: "⌃⌥\(index + 1)"))
            bindings.append(.init(key: UInt32(key), modifiers: base | shift, action: .moveToSpace(index: index, follow: false), label: "⌃⌥⇧\(index + 1)"))
            bindings.append(.init(key: UInt32(key), modifiers: base | command, action: .moveToSpace(index: index, follow: true), label: "⌃⌥⌘\(index + 1)"))
        }
        return bindings
    }()

    static func action(for event: CGEvent) -> NavigationAction? {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        return defaults.first { $0.key == key && $0.modifiers == modifiers }?.action
    }
}

@MainActor
public final class InputController {
    public var onAction: ((NavigationAction) -> Void)?
    public var onStatusChange: (() -> Void)?
    public var gesturesEnabled = false {
        didSet { if isRunning { updateGestures() } }
    }
    public private(set) var issues: [String] = []
    public var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    public var gesturesAvailable: Bool { gestures.isRunning }

    private var isRunning = false
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: NavigationAction] = [:]
    private var shortcutIssues: [String] = []
    private let gestures = GestureMonitor()

    public init() {}

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53544748 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<InputController>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers this handler on the application event loop.
            MainActor.assumeIsolated {
                if let action = controller.actions[identifier.id] { controller.onAction?(action) }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            shortcutIssues = ["Keyboard shortcuts could not start (\(status))."]
            updateGestures()
            return
        }
        for (index, binding) in ShortcutBinding.defaults.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: 0x53544748, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                hotKeys.append(ref)
                actions[id] = binding.action
            } else {
                shortcutIssues.append("\(binding.label) is unavailable. Another app may have registered it (\(result)).")
            }
        }
        updateGestures()
    }

    public func stop() {
        gestures.stop()
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        actions.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isRunning = false
        shortcutIssues = []
        issues = []
        onStatusChange?()
    }

    public func refreshGestureStatus() {
        if isRunning { updateGestures() }
    }

    private func updateGestures() {
        gestures.stop()
        issues = shortcutIssues
        if gesturesEnabled {
            issues += Self.nativeGestureConflicts()
            gestures.onAction = { [weak self] action in self?.onAction?(action) }
            if let issue = gestures.start() { issues.append(issue) }
        }
        onStatusChange?()
    }

    /// macOS does not publish an API for these bindings. These preferences are hints only;
    /// System Settings > Trackpad > More Gestures is authoritative. Nothing is written.
    public static func nativeGestureConflicts() -> [String] {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let keys = [("TrackpadFourFingerHorizSwipeGesture", "horizontal"), ("TrackpadFourFingerVertSwipeGesture", "vertical")]
        var result: [String] = []
        for (key, direction) in keys {
            let values = domains.compactMap { domain -> Int? in
                (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.intValue
            }
            if values.contains(where: { $0 != 0 }) {
                result.append("macOS has a four-finger \(direction) gesture enabled. Reassign or disable it in Trackpad > More Gestures.")
            } else if values.isEmpty {
                result.append("Check Trackpad > More Gestures for four-finger \(direction) conflicts; macOS did not expose that preference.")
            }
        }
        return result
    }
}
