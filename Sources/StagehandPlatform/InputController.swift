import AppKit
import Carbon
import StagehandCore

@MainActor
public final class InputController {
    public var onAction: ((NavigationAction) -> Void)?
    public var onGesture: ((GestureNavigationEvent) -> Void)?
    public var onStatusChange: (() -> Void)?
    /// Answers whether the keyboard tap is consuming navigation chords right now. While it
    /// is, the tap dispatches those actions itself and Carbon must not dispatch them again.
    public var navigationChordsHandledByTap: (() -> Bool)?
    public var gesturesEnabled = false {
        didSet { if isRunning && oldValue != gesturesEnabled { updateGestures() } }
    }
    public var shortcutSwipesEnabled = false {
        didSet { if isRunning && oldValue != shortcutSwipesEnabled { updateGestures() } }
    }
    public var reverseShortcutSwipeDirection = true {
        didSet { if isRunning && oldValue != reverseShortcutSwipeDirection { updateGestures() } }
    }
    public private(set) var issues: [String] = []
    public var gesturesAvailable: Bool { gestures.isRunning }

    static let navigationGestureFingerCount = 3
    /// `defaults write com.example.Stagehand StagehandDisableTrackpadGestures -bool YES` keeps
    /// the private MultitouchSupport framework from loading, as a recovery switch after a
    /// macOS update.
    public static let disableTrackpadGesturesPreferenceKey = GestureMonitor.disablePreferenceKey

    private var isRunning = false
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: NavigationAction] = [:]
    private var shortcutIssues: [String] = []
    /// Saved shortcuts that load turned off. Cleared once the user saves a new set.
    private var shortcutLoadIssues: [String]
    private var shortcutBindings: [ShortcutBinding]
    private var shortcutCaptureActive = false
    private let gestures = GestureMonitor()
    private var wakeObserver: NSObjectProtocol?

    public init(shortcutBindings: [ShortcutBinding] = ShortcutBinding.load(), shortcutLoadIssues: [String] = []) {
        self.shortcutBindings = shortcutBindings
        self.shortcutLoadIssues = shortcutLoadIssues
        gestures.onFailure = { [weak self] _ in self?.refreshGestureStatus() }
    }

    isolated deinit {
        onStatusChange = nil
        stop()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        observeWake()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53544748 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<InputController>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers this handler on the application event loop.
            MainActor.assumeIsolated {
                guard let action = controller.actions[identifier.id] else { return }
                let tapHandles = controller.navigationChordsHandledByTap?() ?? false
                if InputController.shouldDispatchHotKey(action, tapHandlesNavigation: tapHandles) { controller.onAction?(action) }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            shortcutIssues = ["Stagehand couldn't register its keyboard shortcuts. Error \(status)."]
            updateGestures()
            return
        }
        registerHotKeys()
    }

    /// Settings and pause chords always pass through the tap, so Carbon owns them. Every
    /// other chord is consumed by the tap whenever it is available, which is the only time
    /// the same press could reach both paths.
    static func shouldDispatchHotKey(_ action: NavigationAction, tapHandlesNavigation: Bool) -> Bool {
        if action == .showSettings || action == .togglePause { return true }
        return !tapHandlesNavigation
    }

    public func setShortcutBindings(_ bindings: [ShortcutBinding]) {
        shortcutBindings = bindings
        shortcutLoadIssues = []
        if eventHandler != nil { registerHotKeys() }
    }

    public func setShortcutCaptureActive(_ active: Bool) {
        guard shortcutCaptureActive != active else { return }
        shortcutCaptureActive = active
        if eventHandler != nil { registerHotKeys() }
    }

    private func registerHotKeys() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        actions.removeAll()
        shortcutIssues.removeAll()
        guard !shortcutCaptureActive else {
            updateGestures()
            return
        }
        for (index, binding) in shortcutBindings.filter(\.isEnabled).enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: 0x53544748, id: id), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref {
                hotKeys.append(ref)
                actions[id] = binding.action
            } else {
                shortcutIssues.append("\(binding.label) isn't available because another app may already use it. Error \(result).")
            }
        }
        updateGestures()
    }

    public func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
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

    /// Gestures can stop arriving after sleep. Rebuild the monitor with a fresh device.
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.gestures.stop()
                self.gestures.invalidateDevice()
                self.updateGestures()
            }
        }
    }

    /// Call before routing a physical keyboard event. The caller must resolve the gesture
    /// and begin any focus transfer synchronously, leaving activation to queued work.
    public func takePendingGestureCompletion() -> GestureNavigationCompletion? {
        gestures.takePendingGestureCompletion()
    }

    /// Safe from any thread, for the keyboard tap's routing decision. Gesture state is
    /// process-wide, so this does not need the controller instance.
    nonisolated public static func hasPendingGestureCompletion() -> Bool {
        GestureMonitor.hasPendingGestureCompletion()
    }

    /// Cancel a preview without rearming its still-held contacts. The caller owns
    /// geometry cleanup; this only prevents a later release from navigating again.
    public func cancelGestureSequence() {
        gestures.cancelGestureSequence()
    }

    private func updateGestures() {
        gestures.stop()
        issues = shortcutLoadIssues + shortcutIssues
        if gesturesEnabled || shortcutSwipesEnabled {
            issues += Self.nativeGestureConflicts()
            gestures.onGesture = { [weak self] event in
                guard let self else { return }
                if let onGesture = self.onGesture { onGesture(event) }
                else if case .ended(_, _, let action?, _) = event { self.onAction?(action) }
            }
            if let issue = gestures.start(
                fingerCount: Self.navigationGestureFingerCount,
                unmodifiedEnabled: gesturesEnabled,
                shortcutEnabled: shortcutSwipesEnabled,
                shortcutBindings: shortcutBindings,
                reverseShortcutDirection: reverseShortcutSwipeDirection
            ) { issues.append(issue) }
        }
        onStatusChange?()
    }

    /// macOS does not publish an API for these bindings. These preferences are hints only;
    /// System Settings > Trackpad > More Gestures is authoritative. Nothing is written.
    public static func nativeGestureConflicts() -> [String] {
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let keys = [("TrackpadThreeFingerHorizSwipeGesture", "horizontal"), ("TrackpadThreeFingerVertSwipeGesture", "vertical")]
        var result: [String] = []
        for (key, direction) in keys {
            let values = domains.compactMap { domain -> Int? in
                (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.intValue
            }
            if values.contains(where: { $0 != 0 }) {
                result.append("macOS already uses a three-finger \(direction) gesture. Set it to four fingers in System Settings > Trackpad > More Gestures.")
            } else if values.isEmpty {
                result.append("Check System Settings > Trackpad > More Gestures for a three-finger \(direction) conflict. macOS did not report this setting.")
            }
        }
        return result
    }
}
