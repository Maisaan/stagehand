import AppKit
import Carbon
import StagehandCore

/// The buffer is separate from the event tap so token ownership can be tested without
/// monitoring or posting real keyboard input.
struct InputTransferBuffer<Event> {
    private var nextToken: UInt64 = 0
    private var transfers: [(token: UInt64, events: [Event])] = []
    var latestToken: UInt64? { transfers.last?.token }
    var eventCount: Int { transfers.reduce(0) { $0 + $1.events.count } }

    mutating func begin() -> UInt64 {
        nextToken &+= 1
        transfers.append((nextToken, []))
        return nextToken
    }

    @discardableResult
    mutating func append(_ event: Event, token: UInt64) -> Bool {
        guard let index = transfers.firstIndex(where: { $0.token == token }) else { return false }
        transfers[index].events.append(event)
        return true
    }

    mutating func take(token: UInt64) -> [Event] {
        guard let index = transfers.firstIndex(where: { $0.token == token }) else { return [] }
        return transfers.remove(at: index).events
    }

    mutating func removeAll() -> Int {
        let count = eventCount
        transfers.removeAll()
        return count
    }
}

/// Buffers keyboard events only during an explicitly requested focus transfer.
/// Call commit only after the destination application's focused window has been verified.
/// Failed transfers discard buffered input with a mandatory UI notification callback rather
/// than send it to an unverified window. This is not protection against secure input mode.
@MainActor
public final class FocusInputGate {
    public var isAvailable: Bool { tapIsAvailable && !IsSecureEventInputEnabled() }
    public var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }
    public var onTransferExpired: ((UInt64) -> Void)?
    public var onInputDiscarded: ((Int) -> Void)?
    public var onAvailabilityChanged: (() -> Void)?
    public var onNavigationAction: ((NavigationAction) -> Void)?

    private enum KeyDestination {
        case pending(UInt64)
        case delivered(Int32)
        case discarded
    }

    private var buffer = InputTransferBuffer<CGEvent>()
    private var tapIsAvailable = false
    private var deadlines: [UInt64: DispatchWorkItem] = [:]
    private var keyDestinations: [Int64: KeyDestination] = [:]
    private var exemptKeys: Set<Int64> = []
    private var navigationKeys: Set<Int64> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let eventMarker: Int64 = 0x53544748414E44
    private let maximumEvents = 128
    private let postEvent: (CGEvent, Int32) -> Void

    public init() {
        postEvent = { event, pid in event.postToPid(pid) }
    }

    init(postEvent: @escaping (CGEvent, Int32) -> Void) {
        self.postEvent = postEvent
    }

    public func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            tapIsAvailable = false
            onAvailabilityChanged?()
            return
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let gate = Unmanaged<FocusInputGate>.fromOpaque(context).takeUnretainedValue()
            let shouldPass = MainActor.assumeIsolated { gate.receive(type: type, event: event) != nil }
            return shouldPass ? Unmanaged.passUnretained(event) : nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            tapIsAvailable = false
            onAvailabilityChanged?()
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapIsAvailable = true
        onAvailabilityChanged?()
    }

    public func stop() {
        cancelAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        keyDestinations.removeAll()
        exemptKeys.removeAll()
        navigationKeys.removeAll()
        tapIsAvailable = false
        onAvailabilityChanged?()
    }

    public func beginTransfer() -> UInt64 {
        let token = buffer.begin()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cancelTransfer(token: token)
            self.onTransferExpired?(token)
        }
        deadlines[token] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: deadline)
        return token
    }

    public func commitTransfer(token: UInt64, processIdentifier: Int32) {
        guard processIdentifier > 0 else { cancelTransfer(token: token); return }
        deadlines.removeValue(forKey: token)?.cancel()
        let events = buffer.take(token: token)
        for (key, destination) in keyDestinations {
            if case .pending(let pendingToken) = destination, pendingToken == token { keyDestinations[key] = .delivered(processIdentifier) }
        }
        for event in events { post(event, processIdentifier: processIdentifier) }
    }

    public func cancelTransfer(token: UInt64) {
        deadlines.removeValue(forKey: token)?.cancel()
        let events = buffer.take(token: token)
        for (key, destination) in keyDestinations {
            if case .pending(let pendingToken) = destination, pendingToken == token { keyDestinations[key] = .discarded }
        }
        if !events.isEmpty { onInputDiscarded?(events.count) }
    }

    public func cancelAll() {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let count = buffer.removeAll()
        for (key, destination) in keyDestinations {
            if case .pending = destination { keyDestinations[key] = .discarded }
        }
        if count > 0 { onInputDiscarded?(count) }
    }

    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelAll()
            // Leave protection unavailable until the controller explicitly retries. A timeout
            // means events may have bypassed the tap; pretending protection continued is unsafe.
            tapIsAvailable = false
            onAvailabilityChanged?()
            return Unmanaged.passUnretained(event)
        }
        guard isAvailable else { return Unmanaged.passUnretained(event) }
        return processKeyboardEvent(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when consumed. Separate from tap availability so tests can use synthetic
    /// events and an injected replay sink without starting global capture or posting input.
    func processKeyboardEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != eventMarker else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, navigationKeys.remove(key) != nil { return true }
        if type == .keyDown, let action = ShortcutBinding.action(for: event) {
            if action != .showSettings, action != .togglePause, let onNavigationAction {
                navigationKeys.insert(key)
                // The caller only enqueues work. It must not run AX calls on the event tap.
                // Beginning capture here closes the gap before Carbon dispatches a hotkey.
                onNavigationAction(action)
                return true
            }
            exemptKeys.insert(key)
            return false
        }
        if exemptKeys.contains(key) {
            if type == .keyUp { exemptKeys.remove(key) }
            return false
        }
        // A fresh press supersedes stale held-key bookkeeping if a key-up was missed while
        // secure input was enabled or the tap was unavailable. Never reroute a new press.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            keyDestinations.removeValue(forKey: key)
        }
        if let destination = keyDestinations[key] {
            if type == .keyUp { keyDestinations.removeValue(forKey: key) }
            switch destination {
            case .pending(let token):
                capture(event, token: token)
                return true
            case .delivered(let pid):
                post(event, processIdentifier: pid)
                return true
            case .discarded:
                return true
            }
        }
        guard type == .keyDown, let token = buffer.latestToken else { return false }
        keyDestinations[key] = .pending(token)
        capture(event, token: token)
        return true
    }

    private func capture(_ event: CGEvent, token: UInt64) {
        guard buffer.eventCount < maximumEvents, let copy = event.copy() else {
            // Include the event that could not be buffered in the reported count.
            cancelTransfer(token: token)
            onInputDiscarded?(1)
            onTransferExpired?(token)
            return
        }
        if !buffer.append(copy, token: token) { onInputDiscarded?(1) }
    }

    private func post(_ event: CGEvent, processIdentifier: Int32) {
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        postEvent(event, processIdentifier)
    }
}
