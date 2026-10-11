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
    var pendingEvents = GestureEventBuffer()
    var deliveryScheduled = false
    var scheduleDelivery: (@Sendable () -> Void)?
}

private let gestureCallbackState = OSAllocatedUnfairLock(initialState: GestureCallbackState())
private let traceGestures = ProcessInfo.processInfo.arguments.contains("--trace-gestures")

private let contactCallback: ContactCallback = { _, raw, count, timestamp, _ in
    guard count >= 0, count <= maximumContactsPerFrame, count == 0 || raw != nil else { return 0 }
    var contacts: [GestureContact] = []
    contacts.reserveCapacity(Int(count))
    if let raw {
        let buffer = raw.assumingMemoryBound(to: RawContact.self)
        for index in 0..<Int(count) {
            let touch = buffer[index]
            if touch.state == touchStateMake || touch.state == touchStateTouching {
                contacts.append(GestureContact(id: touch.identifier, x: Double(touch.normalized.position.x), y: Double(touch.normalized.position.y)))
            }
        }
    }
    let snapshot = contacts
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let delivery = gestureCallbackState.withLock { state -> (@Sendable () -> Void)? in
        guard state.enabled else { return nil }
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
        state.suppressScroll = state.recognizer.hasContactSequence
        if wasSuppressing && !state.suppressScroll { state.lastLiftTime = ProcessInfo.processInfo.systemUptime }
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
    var onGesture: ((GestureNavigationEvent) -> Void)?
    private(set) var isRunning = false
    private var framework: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregister: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void)?
    private var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var scrollTap: ScrollTapThread?
    private var generation: UInt64 = 0

    func start(fingerCount: Int = 4, unmodifiedEnabled: Bool, shortcutEnabled: Bool,
               shortcutBindings: [ShortcutBinding], reverseShortcutDirection: Bool) -> String? {
        guard !isRunning else { return nil }
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
                    let events = gestureCallbackState.withLock { state in
                        state.deliveryScheduled = false
                        return state.pendingEvents.drain()
                    }
                    for event in events {
                        guard self.isRunning, self.generation == activeGeneration else { return }
                        self.onGesture?(event)
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
            _ = state.pendingEvents.drain()
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
        if state.suppressScroll { return true }
        return momentum && ProcessInfo.processInfo.systemUptime - state.lastLiftTime < momentumSuppressionWindow
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
