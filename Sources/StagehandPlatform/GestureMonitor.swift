import AppKit
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

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private struct GestureCallbackState {
    var enabled = false
    var recognizer = FourFingerRecognizer()
    var suppressScroll = false
    var lastLiftTime: TimeInterval = 0
    var onAction: (@Sendable (NavigationAction) -> Void)?
}

private let gestureCallbackState = OSAllocatedUnfairLock(initialState: GestureCallbackState())

private let contactCallback: ContactCallback = { _, raw, count, timestamp, _ in
    guard count >= 0, count <= 32, count == 0 || raw != nil else { return 0 }
    var contacts: [GestureContact] = []
    if let raw {
        let buffer = raw.assumingMemoryBound(to: RawContact.self)
        for index in 0..<Int(count) {
            let touch = buffer[index]
            if touch.state == 3 || touch.state == 4 {
                contacts.append(GestureContact(id: touch.identifier, x: Double(touch.normalized.position.x), y: Double(touch.normalized.position.y)))
            }
        }
    }
    let snapshot = contacts
    let delivery = gestureCallbackState.withLock { state -> ((@Sendable (NavigationAction) -> Void), NavigationAction)? in
        guard state.enabled else { return nil }
        let wasSuppressing = state.suppressScroll
        let action = state.recognizer.update(contacts: snapshot, timestamp: timestamp)
        state.suppressScroll = state.recognizer.hasFourFingerSequence
        if wasSuppressing && !state.suppressScroll { state.lastLiftTime = ProcessInfo.processInfo.systemUptime }
        if let action, let handler = state.onAction { return (handler, action) }
        return nil
    }
    if let (handler, action) = delivery { handler(action) }
    return 0
}

@MainActor
final class GestureMonitor {
    var onAction: ((NavigationAction) -> Void)?
    private(set) var isRunning = false
    private var framework: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregister: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void)?
    private var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var generation: UInt64 = 0

    func start() -> String? {
        guard !isRunning else { return nil }
        guard AXIsProcessTrusted() else { return "Four-finger gestures need Accessibility permission." }
        guard CGPreflightListenEventAccess() else { return "Four-finger gestures need Input Monitoring permission. Enable it in Privacy & Security, then retry." }
        guard MemoryLayout<RawContact>.stride == 96,
              MemoryLayout<RawContact>.offset(of: \.normalized) == 32,
              MemoryLayout<RawContact>.offset(of: \.absolute) == 68 else {
            return "The trackpad data format is unsupported on this system. Keyboard shortcuts remain available."
        }
        guard installScrollTap() else { return "The gesture scroll filter could not start. Check Accessibility and Input Monitoring permissions." }
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
            return "The private macOS trackpad API is unavailable. Keyboard shortcuts remain available."
        }
        let create = unsafeBitCast(createSymbol, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        let register = unsafeBitCast(registerSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        let startDevice = unsafeBitCast(startSymbol, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        unregister = unsafeBitCast(unregisterSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        stopDevice = unsafeBitCast(stopSymbol, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        guard let device = self.device ?? create() else {
            removeScrollTap()
            return "No built-in trackpad was found. Keyboard shortcuts remain available."
        }
        self.device = device
        let activeGeneration = generation
        gestureCallbackState.withLock { state in
            state = GestureCallbackState()
            state.enabled = true
            state.onAction = { [weak self] action in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.generation == activeGeneration else { return }
                    self.onAction?(action)
                }
            }
        }
        register(device, contactCallback)
        isRunning = true
        startDevice(device, 0)
        return nil
    }

    func stop() {
        gestureCallbackState.withLock { $0 = GestureCallbackState() }
        generation &+= 1
        let wasRunning = isRunning
        isRunning = false
        if let device, wasRunning {
            unregister?(device, contactCallback)
            stopDevice?(device)
        }
        // Keep one default-device reference for process lifetime. Releasing a device while
        // its private dequeue thread exits can race the framework's own final release.
        // Reuse this handle on restart instead of allocating/leaking one per preference edit.
        removeScrollTap()
    }

    private func installScrollTap() -> Bool {
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let context {
                    let monitor = Unmanaged<GestureMonitor>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated {
                        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            let suppress = gestureCallbackState.withLock { state in
                guard state.enabled else { return false }
                if state.suppressScroll { return true }
                return momentum && ProcessInfo.processInfo.systemUptime - state.lastLiftTime < 0.15
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeScrollTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }
}
