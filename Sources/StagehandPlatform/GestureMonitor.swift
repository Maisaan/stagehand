import AppKit
import Carbon
import Darwin
import os
import StagehandCore

// Private ABI reference: https://github.com/cyanyux/trident/blob/main/Sources/TridentCore/TouchModels.swift
// The runtime checks the layout before starting. Missing symbols disable gestures, not keyboard controls.
private struct RawPoint { var x: Float; var y: Float }
private struct RawVector { var position: RawPoint; var velocity: RawPoint }
private struct RawContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: UInt32
    var finger: Int32
    var hand: Int32
    var normalized: RawVector
    var pressure: Float
    var unused1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: RawVector
    var unused2: Int32
    var unused3: Int32
    var density: Float
}

/// Layout of the private contact record, checked before any frame is read.
private let rawContactStride = 96
private let rawContactNormalizedOffset = 32
private let rawContactAbsoluteOffset = 68
/// MultitouchSupport reports more contacts than any trackpad has only when the frame is corrupt.
private let maximumContactsPerFrame: Int32 = 32
/// Contact states that mean a finger is on the surface: 3 is "make" (just landed), 4 is "touching".
private let touchStateMake: UInt32 = 3
private let touchStateTouching: UInt32 = 4
/// Momentum scroll events that follow a lift within this window belong to the gesture.
private let momentumSuppressionWindow: TimeInterval = 0.15
/// Scroll events are held only while a drag is live and contact frames are still arriving.
/// If the framework stops reporting frames mid-drag, scrolling recovers after this long.
private let scrollSuppressionStaleInterval: TimeInterval = 0.1

/// Rejects contact frames that cannot have come from a working trackpad. The private
/// framework has no contract; after a macOS update it may report garbage with the right
/// struct size, and the recognizer must not act on it.
struct GestureFrameValidator: Sendable {
    struct Touch: Sendable {
        var frame: Int32
        var state: UInt32
        var x: Float
        var y: Float
        var isTouching: Bool
    }

    /// MultitouchSupport states run 0 (not tracking) through 7 (out of range).
    static let maximumTouchState: UInt32 = 7
    /// Positions are normalized 0...1; a small tolerance absorbs edge rounding.
    static let positionTolerance: Float = 0.05
    /// Consecutive corrupt frames before gestures turn themselves off.
    static let maximumBadFrames = 10

    private(set) var badFrames = 0
    private var lastTimestamp: Double = 0
    private var lastFrame: Int32 = 0
    var isExhausted: Bool { badFrames >= Self.maximumBadFrames }

    /// Returns false when the frame must be ignored. A rejected frame also resets the
    /// baseline so one clock reset counts once rather than failing every later frame.
    mutating func accept(timestamp: Double, touches: [Touch]) -> Bool {
        let range = -Self.positionTolerance...(1 + Self.positionTolerance)
        let valid = timestamp.isFinite && timestamp >= lastTimestamp && touches.allSatisfy { touch in
            touch.state <= Self.maximumTouchState && touch.frame >= lastFrame
                && (!touch.isTouching || (touch.x.isFinite && touch.y.isFinite && range.contains(touch.x) && range.contains(touch.y)))
        }
        lastTimestamp = timestamp.isFinite ? timestamp : 0
        lastFrame = touches.map(\.frame).max() ?? lastFrame
        if valid {
            badFrames = 0
        } else {
            badFrames += 1
        }
        return valid
    }
}

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

func shortcutGestureModifiers(for flags: CGEventFlags, bindings: [ShortcutBinding]) -> UInt32? {
    let modifiers = ShortcutBinding.carbonModifiers(for: flags)
    let arrowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    return arrowKeys.contains {
        ShortcutBinding.action(forKey: UInt32($0), modifiers: modifiers, in: bindings) != nil
    } ? modifiers : nil
}

func gestureShortcutAction(
    axis: GestureAxis, displacement: Double, modifiers: UInt32, bindings: [ShortcutBinding],
    reverseDirection: Bool = true
) -> NavigationAction? {
    let displacement = reverseDirection ? -displacement : displacement
    let key: UInt32
    switch axis {
    case .horizontal: key = UInt32(displacement < 0 ? kVK_LeftArrow : kVK_RightArrow)
    case .vertical: key = UInt32(displacement > 0 ? kVK_UpArrow : kVK_DownArrow)
    }
    return ShortcutBinding.action(forKey: key, modifiers: modifiers, in: bindings)
}

private struct GestureCallbackState {
    var enabled = false
    var unmodifiedEnabled = false
    var shortcutEnabled = false
    var reverseShortcutDirection = true
    var shortcutBindings: [ShortcutBinding] = []
    var shortcutModifiers: UInt32?
    var shortcutAxis: GestureAxis?
    var ignoredUntilLift = false
    var recognizer = NavigationGestureRecognizer()
    var suppressScroll = false
    var lastLiftTime: TimeInterval = 0
    var lastContactFrameTime: TimeInterval = 0
    var frameValidator = GestureFrameValidator()
    /// Set once corrupt frames exhaust the validator; delivered to the monitor on main.
    var failure: String?
    var pendingEvents = GestureEventBuffer()
    var deliveryScheduled = false
    var scheduleDelivery: (@Sendable () -> Void)?
}

private let gestureCallbackState = OSAllocatedUnfairLock(initialState: GestureCallbackState())
private let traceGestures = ProcessInfo.processInfo.arguments.contains("--trace-gestures")

private let contactCallback: ContactCallback = { _, raw, count, timestamp, _ in
    guard count >= 0, count <= maximumContactsPerFrame, count == 0 || raw != nil else { return 0 }
    var contacts: [GestureContact] = []
    var touches: [GestureFrameValidator.Touch] = []
    contacts.reserveCapacity(Int(count))
    touches.reserveCapacity(Int(count))
    if let raw {
        let buffer = raw.assumingMemoryBound(to: RawContact.self)
        for index in 0..<Int(count) {
            let touch = buffer[index]
            let isTouching = touch.state == touchStateMake || touch.state == touchStateTouching
            touches.append(.init(frame: touch.frame, state: touch.state, x: touch.normalized.position.x,
                                 y: touch.normalized.position.y, isTouching: isTouching))
            if isTouching {
                contacts.append(GestureContact(id: touch.identifier, x: Double(touch.normalized.position.x), y: Double(touch.normalized.position.y)))
            }
        }
    }
    let snapshot = contacts
    let frameTouches = touches
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let delivery = gestureCallbackState.withLock { state -> (@Sendable () -> Void)? in
        guard state.enabled else { return nil }
        guard state.frameValidator.accept(timestamp: timestamp, touches: frameTouches) else {
            // Drop the frame and any gesture it was part of. Enough corrupt frames in a
            // row mean the private data layout no longer matches; stop trusting it.
            let wasDragging = state.recognizer.isDragging
            state.recognizer.cancelUntilLift()
            state.suppressScroll = false
            if wasDragging { state.pendingEvents.append(.cancelled) }
            if state.frameValidator.isExhausted {
                state.enabled = false
                state.failure = "Trackpad data from this version of macOS looks invalid, so gestures are off until Stagehand relaunches. Keyboard shortcuts still work."
            }
            if traceGestures {
                NSLog("[DEBUG-gesture] rejected frame t=%.3f raw=%d bad=%d", timestamp, count, state.frameValidator.badFrames)
            }
            guard wasDragging || state.failure != nil, !state.deliveryScheduled else { return nil }
            state.deliveryScheduled = true
            return state.scheduleDelivery
        }
        if state.ignoredUntilLift {
            if snapshot.isEmpty { state.ignoredUntilLift = false }
            return nil
        }
        let modifiers = ShortcutBinding.carbonModifiers(for: flags)
        if !state.recognizer.hasContactSequence && snapshot.count >= state.recognizer.fingerCount {
            state.shortcutModifiers = state.shortcutEnabled
                ? shortcutGestureModifiers(for: flags, bindings: state.shortcutBindings) : nil
            if state.shortcutModifiers == nil && !state.unmodifiedEnabled {
                state.ignoredUntilLift = true
                return nil
            }
        }
        let modifiersChanged = state.shortcutModifiers.map { $0 != modifiers } ?? false
        let modifierCancelled = state.recognizer.isDragging && modifiersChanged
        if state.recognizer.hasContactSequence && modifiersChanged {
            state.recognizer.cancelUntilLift()
            if modifierCancelled { state.pendingEvents.append(.cancelled) }
        }
        let wasSuppressing = state.suppressScroll
        var event = state.recognizer.update(contacts: snapshot, timestamp: timestamp)
        if let shortcutModifiers = state.shortcutModifiers {
            switch event {
            case .began(let axis, let displacement, _):
                state.shortcutAxis = axis
                // A shortcut swipe acts on release like its arrow key. The plain gesture's
                // live ribbon preview follows a different direction and must not run here.
                event = .began(axis: axis, displacement: displacement, mode: .shortcut)
            case .ended(let displacement, let velocity, let action, _):
                let shortcutAction = action.flatMap { _ in
                    state.shortcutAxis.flatMap {
                        gestureShortcutAction(axis: $0, displacement: displacement,
                                              modifiers: shortcutModifiers, bindings: state.shortcutBindings,
                                              reverseDirection: state.reverseShortcutDirection)
                    }
                }
                event = .ended(displacement: displacement, velocity: velocity,
                               action: shortcutAction, mode: .shortcut)
            default: break
            }
        }
        if case .ended = event {
            state.shortcutModifiers = nil
            state.shortcutAxis = nil
        }
        if case .cancelled = event {
            state.shortcutModifiers = nil
            state.shortcutAxis = nil
        }
        if traceGestures, let event {
            switch event {
            case .changed: break
            default:
                NSLog("[DEBUG-gesture] contact t=%.3f raw=%d active=%d event=%@ reason=%@", timestamp, count,
                      snapshot.count, String(describing: event), state.recognizer.cancellationReason ?? "none")
            }
        }
        // Only a recognized drag owns the scroll stream. Fingers that are merely resting,
        // or a sequence that was cancelled, must not block scrolling until a zero-contact
        // frame that may never arrive.
        state.suppressScroll = state.recognizer.isDragging
        let now = ProcessInfo.processInfo.systemUptime
        if !snapshot.isEmpty { state.lastContactFrameTime = now }
        if wasSuppressing && !state.suppressScroll { state.lastLiftTime = now }
        if let event { state.pendingEvents.append(event) }
        guard event != nil || modifierCancelled else { return nil }
        guard !state.deliveryScheduled else { return nil }
        state.deliveryScheduled = true
        return state.scheduleDelivery
    }
    delivery?()
    return 0
}

@MainActor
final class GestureMonitor {
    /// Hidden preference that keeps the private framework from being loaded at all.
    static let disablePreferenceKey = "StagehandDisableTrackpadGestures"

    var onGesture: ((GestureNavigationEvent) -> Void)?
    /// Called on main after corrupt frames turned gestures off. `start()` keeps returning
    /// the message for the rest of the process.
    var onFailure: ((String) -> Void)?
    private(set) var isRunning = false
    private var dataFailure: String?
    private var framework: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregister: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void)?
    private var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var scrollTap: ScrollTapThread?
    private var generation: UInt64 = 0

    func start(fingerCount: Int = 4, unmodifiedEnabled: Bool, shortcutEnabled: Bool,
               shortcutBindings: [ShortcutBinding], reverseShortcutDirection: Bool) -> String? {
        guard !isRunning else { return nil }
        if UserDefaults.standard.bool(forKey: Self.disablePreferenceKey) {
            return "Trackpad gestures are turned off by the \(Self.disablePreferenceKey) setting. Keyboard shortcuts still work."
        }
        if let dataFailure { return dataFailure }
        guard AXIsProcessTrusted() else { return "Allow Stagehand in Accessibility settings to use gestures." }
        guard MemoryLayout<RawContact>.stride == rawContactStride,
              MemoryLayout<RawContact>.offset(of: \.normalized) == rawContactNormalizedOffset,
              MemoryLayout<RawContact>.offset(of: \.absolute) == rawContactAbsoluteOffset else {
            return "This version of macOS does not expose trackpad data Stagehand can use. Keyboard shortcuts still work."
        }
        guard installScrollTap() else { return "Gesture navigation couldn't start. Re-enable Accessibility for Stagehand, then try again." }
        // Keep the framework loaded for process lifetime: a late framework callback must never
        // jump into unloaded code. Only one built-in trackpad is in scope for the MVP.
        if framework == nil { framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL) }
        guard let framework,
              let createSymbol = dlsym(framework, "MTDeviceCreateDefault"),
              let registerSymbol = dlsym(framework, "MTRegisterContactFrameCallback"),
              let unregisterSymbol = dlsym(framework, "MTUnregisterContactFrameCallback"),
              let startSymbol = dlsym(framework, "MTDeviceStart"),
              let stopSymbol = dlsym(framework, "MTDeviceStop") else {
            removeScrollTap()
            return "Gesture navigation isn't available on this version of macOS. Keyboard shortcuts still work."
        }
        let create = unsafeBitCast(createSymbol, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        let register = unsafeBitCast(registerSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        let startDevice = unsafeBitCast(startSymbol, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        unregister = unsafeBitCast(unregisterSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        stopDevice = unsafeBitCast(stopSymbol, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        guard let device = self.device ?? create() else {
            removeScrollTap()
            return "Stagehand couldn't find a built-in trackpad. Keyboard shortcuts still work."
        }
        self.device = device
        let activeGeneration = generation
        gestureCallbackState.withLock { state in
            state = GestureCallbackState()
            state.recognizer = NavigationGestureRecognizer(fingerCount: fingerCount)
            state.enabled = true
            state.unmodifiedEnabled = unmodifiedEnabled
            state.shortcutEnabled = shortcutEnabled
            state.shortcutBindings = shortcutBindings
            state.reverseShortcutDirection = reverseShortcutDirection
            state.scheduleDelivery = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.generation == activeGeneration else { return }
                    let (events, failure) = gestureCallbackState.withLock { state in
                        state.deliveryScheduled = false
                        return (state.pendingEvents.drain(), state.failure)
                    }
                    for event in events {
                        guard self.isRunning, self.generation == activeGeneration else { return }
                        self.onGesture?(event)
                        // The handoff ran synchronously and began its transfer if it navigated.
                        // Only now may the keyboard tap stop treating this release as pending.
                        if case .ended = event {
                            gestureCallbackState.withLock { $0.pendingEvents.completionDelivered() }
                        }
                    }
                    if let failure, self.isRunning, self.generation == activeGeneration {
                        self.dataFailure = failure
                        self.stop()
                        self.onFailure?(failure)
                    }
                }
            }
        }
        register(device, contactCallback)
        isRunning = true
        startDevice(device, 0)
        return nil
    }

    func stop() {
        if traceGestures, isRunning { NSLog("[DEBUG-gesture] monitor stopped") }
        gestureCallbackState.withLock { $0 = GestureCallbackState() }
        generation &+= 1
        let wasRunning = isRunning
        isRunning = false
        // Deliver cancellation synchronously before changing settings or dropping queued phases.
        if wasRunning { onGesture?(.cancelled) }
        if let device, wasRunning {
            unregister?(device, contactCallback)
            stopDevice?(device)
        }
        // Keep one default-device reference for process lifetime. Releasing a device while
        // its private dequeue thread exits can race the framework's own final release.
        // Reuse this handle on restart instead of allocating/leaking one per preference edit.
        removeScrollTap()
    }

    /// After sleep the framework's device handle may stop delivering frames. Forget it so
    /// the next start creates a fresh one. The old handle is intentionally not released
    /// (see `stop()`); one leaked reference per wake is the price of not racing the
    /// framework's dequeue thread.
    func invalidateDevice() {
        guard !isRunning else { return }
        device = nil
    }

    func takePendingGestureCompletion() -> GestureNavigationCompletion? {
        guard isRunning else { return nil }
        return gestureCallbackState.withLock { state in
            guard state.enabled else { return nil }
            return state.pendingEvents.takeCompletion()
        }
    }

    /// Safe from any thread. The keyboard tap uses it to hold typing that follows a release
    /// whose main-queue delivery has not run yet.
    nonisolated static func hasPendingGestureCompletion() -> Bool {
        gestureCallbackState.withLock { $0.enabled && $0.pendingEvents.hasCompletion }
    }

    func cancelGestureSequence() {
        if traceGestures { NSLog("[DEBUG-gesture] sequence interrupted by app") }
        gestureCallbackState.withLock { state in
            state.recognizer.cancelUntilLift()
            state.pendingEvents.removeAll()
        }
    }

    private func installScrollTap() -> Bool {
        let scrollTap = ScrollTapThread()
        guard scrollTap.start() else { return false }
        self.scrollTap = scrollTap
        return true
    }

    private func removeScrollTap() {
        scrollTap?.stop()
        scrollTap = nil
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, context in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let context { Unmanaged<ScrollTapThread>.fromOpaque(context).takeUnretainedValue().reenable() }
        return Unmanaged.passUnretained(event)
    }
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    let suppress = gestureCallbackState.withLock { state in
        guard state.enabled else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if state.suppressScroll, now - state.lastContactFrameTime < scrollSuppressionStaleInterval { return true }
        return momentum && now - state.lastLiftTime < momentumSuppressionWindow
    }
    return suppress ? nil : Unmanaged.passUnretained(event)
}

/// Hosts the scroll tap on its own run loop. The tap filters every scroll event on
/// the system, so it must not wait behind Accessibility calls on the main thread.
/// Its callback only reads `gestureCallbackState`, which is lock-protected.
private final class ScrollTapThread: @unchecked Sendable {
    // Written on the tap thread before `ready` is signaled, then only read.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    func start() -> Bool {
        // The thread retains this object until its run loop exits after `stop()`.
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: scrollTapCallback, userInfo: context) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // Invalidating the tap from another thread does not wake this run loop, so
            // `stop()` also stops it. The validity check covers a stop that lands first.
            while CFMachPortIsValid(tap),
                  CFRunLoopRunInMode(.defaultMode, 1e10, false) != .stopped {}
        }
        thread.name = "Stagehand scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return tap != nil
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}
