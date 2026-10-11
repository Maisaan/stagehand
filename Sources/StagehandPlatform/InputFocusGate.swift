import AppKit
import Carbon
import os
import StagehandCore

/// The buffer is separate from the event tap so token ownership can be tested without
/// monitoring or posting real keyboard input.
struct InputTransferBuffer<Event> {
    private var nextToken: UInt64 = 0
    private var transfers: [(token: UInt64, events: [Event])] = []
    var latestToken: UInt64? { transfers.last?.token }
    var eventCount: Int { transfers.reduce(0) { $0 + $1.events.count } }
    var transferCount: Int { transfers.count }
    var tokens: [UInt64] { transfers.map(\.token) }
    func contains(token: UInt64) -> Bool { transfers.contains { $0.token == token } }
    func isEmpty(token: UInt64) -> Bool { transfers.first { $0.token == token }?.events.isEmpty == true }
    func count(token: UInt64) -> Int { transfers.first { $0.token == token }?.events.count ?? 0 }

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

    /// Drops the oldest transfers that hold no events until at most `limit` remain.
    /// Transfers with events are never dropped here; they own typing.
    mutating func removeOldestEmptyTransfers(keepingAtMost limit: Int) -> [UInt64] {
        var dropped: [UInt64] = []
        while transfers.count > limit,
              let index = transfers.firstIndex(where: { $0.events.isEmpty && $0.token != latestToken }) {
            dropped.append(transfers.remove(at: index).token)
        }
        return dropped
    }
}

private enum KeyDestination {
    case pending(UInt64)
    case delivered(Int32)
    case discarded
}

/// Everything the tap thread and the main actor share. Guarded by `FocusInputGate.core`.
private struct GateState {
    var buffer = InputTransferBuffer<CGEvent>()
    var keyDestinations: [Int64: KeyDestination] = [:]
    var exemptKeys: Set<Int64> = []
    var navigationKeys: Set<Int64> = []
    var shortcutBindings = ShortcutBinding.defaults
    var tapIsAvailable = false
    /// A transfer the tap thread began for typing that followed a trackpad release whose
    /// main-queue delivery was still pending. The next `beginTransfer` adopts it.
    var provisionalToken: UInt64?
    var hasPendingGestureCompletion: (@Sendable () -> Bool)?

    /// Forget held-key bookkeeping. Call whenever the tap stops seeing events, so a key-up
    /// that bypassed the tap cannot route a later press.
    mutating func clearKeys() {
        keyDestinations.removeAll()
        exemptKeys.removeAll()
        navigationKeys.removeAll()
    }

    mutating func discardDestinations(for token: UInt64) {
        for (key, destination) in keyDestinations {
            if case .pending(let pendingToken) = destination, pendingToken == token { keyDestinations[key] = .discarded }
        }
    }

    mutating func removeAllTransfers() -> Int {
        let count = buffer.removeAll()
        for (key, destination) in keyDestinations {
            if case .pending = destination { keyDestinations[key] = .discarded }
        }
        provisionalToken = nil
        return count
    }
}

/// Main-actor work that one routed event produced. The lock must not be held while
/// any of it runs, and the tap thread must not run any of it.
private struct RoutingEffects: @unchecked Sendable {
    var navigationAction: NavigationAction?
    var discardedCount = 0
    var expiredToken: UInt64?
    var provisionalToken: UInt64?
    /// Events for already-verified destinations. Posting stays on the main actor so an
    /// injected replay sink never runs on the tap thread.
    var postings: [(event: CGEvent, pid: Int32)] = []
    var cancelledTokens: [UInt64] = []
    var isEmpty: Bool {
        navigationAction == nil && discardedCount == 0 && expiredToken == nil && provisionalToken == nil
            && postings.isEmpty && cancelledTokens.isEmpty
    }
}

/// Buffers keyboard events only during an explicitly requested focus transfer.
/// Call commit only after the destination application's focused window has been verified.
/// Failed transfers discard buffered input with a mandatory UI notification callback rather
/// than send it to an unverified window. This is not protection against secure input mode.
///
/// The event tap runs on its own thread (`KeyboardTapThread`): every keystroke on the system
/// waits for its callback, so the decision to consume or pass an event is made under a lock
/// without touching the main thread. Callbacks and event posting hop to the main actor.
@MainActor
public final class FocusInputGate {
    public var isAvailable: Bool { core.withLockUnchecked { $0.tapIsAvailable } && !isSecureInputEnabled }
    public var isSecureInputEnabled: Bool { secureInputEnabled() }
    /// Events held for transfers that have not been committed or cancelled.
    public var pendingEventCount: Int { core.withLockUnchecked { $0.buffer.eventCount } }
    public var onTransferExpired: ((UInt64) -> Void)?
    public var onInputDiscarded: ((Int) -> Void)?
    public var onAvailabilityChanged: (() -> Void)?
    public var onNavigationAction: ((NavigationAction) -> Void)?
    /// Runs before a key event is routed from `processKeyboardEvent`, and on the main actor
    /// after the tap thread buffered a key into a provisional transfer. The caller must resolve
    /// any pending trackpad release and begin its focus transfer synchronously, leaving
    /// activation to queued work.
    public var onBeforeKeyboardEvent: (() -> Void)?

    /// Stamped into `eventSourceUserData` on replayed events so the tap passes them through ("STGHAND").
    nonisolated static let eventMarker: Int64 = 0x53544748414E44
    /// Total events held across all transfers before the owning transfer is abandoned.
    nonisolated static let maximumBufferedEvents = 128
    /// Transfers without typing beyond this count are dropped oldest first when another begins.
    static let maximumActiveTransfers = 32
    // Focus may need a longer confirmation window when AX is slow. Keep input
    // buffered beyond that window, then discard it if the transfer still stalls.
    static let defaultTransferTimeoutMilliseconds = 4_000
    /// Delays before re-enabling a tap that macOS disabled. The last delay repeats.
    static let tapReenableDelays: [DispatchTimeInterval] = [.milliseconds(250), .seconds(1), .seconds(5)]
    /// How often a pending transfer re-checks Secure Input and tap availability.
    static let availabilityWatchInterval: DispatchTimeInterval = .milliseconds(200)

    private let core = OSAllocatedUnfairLock(uncheckedState: GateState())
    private var deadlines: [UInt64: DispatchWorkItem] = [:]
    private var tapThread: KeyboardTapThread?
    private var tapGeneration: UInt64 = 0
    private var availabilityWatch: DispatchSourceTimer?
    private let transferTimeoutMilliseconds: Int
    private let postEvent: (CGEvent, Int32) -> Void
    private let secureInputEnabled: @Sendable () -> Bool
    private let frontmostProcessIdentifier: () -> Int32?
    /// Tests drive `processKeyboardEvent` directly and must never capture real typing.
    private let installsEventTap: Bool

    public init() {
        transferTimeoutMilliseconds = Self.defaultTransferTimeoutMilliseconds
        postEvent = { event, pid in event.postToPid(pid) }
        secureInputEnabled = { IsSecureEventInputEnabled() }
        frontmostProcessIdentifier = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        installsEventTap = true
    }

    /// Test seam. Secure Input defaults to off so synthetic routing does not depend on
    /// whether a password field happens to be focused on the machine running the tests.
    init(transferTimeoutMilliseconds: Int = defaultTransferTimeoutMilliseconds, installsEventTap: Bool = true,
         secureInputEnabled: @escaping @Sendable () -> Bool = { false },
         frontmostProcessIdentifier: @escaping () -> Int32? = { nil },
         postEvent: @escaping (CGEvent, Int32) -> Void) {
        self.transferTimeoutMilliseconds = transferTimeoutMilliseconds
        self.installsEventTap = installsEventTap
        self.secureInputEnabled = secureInputEnabled
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.postEvent = postEvent
    }

    isolated deinit {
        onAvailabilityChanged = nil
        onInputDiscarded = nil
        stop()
    }

    public func start() {
        guard installsEventTap else {
            core.withLockUnchecked { $0.tapIsAvailable = true }
            onAvailabilityChanged?()
            return
        }
        if tapThread != nil {
            guard !core.withLockUnchecked({ $0.tapIsAvailable }) else { return }
            removeTap()
        }
        guard AXIsProcessTrusted() else {
            setTapAvailable(false)
            return
        }
        let thread = KeyboardTapThread { [weak self] type, event in
            self?.receiveFromTap(type: type, event: event) ?? false
        }
        guard thread.start() else {
            setTapAvailable(false)
            return
        }
        tapThread = thread
        tapGeneration &+= 1
        setTapAvailable(true)
    }

    public func setShortcutBindings(_ bindings: [ShortcutBinding]) {
        core.withLockUnchecked { $0.shortcutBindings = bindings }
    }

    /// The tap thread asks this before routing a key that no transfer owns. When a trackpad
    /// release is still waiting for main-queue delivery, the key is held until the release
    /// has been resolved, so it cannot reach the window the gesture is leaving.
    public func setPendingGestureCompletionCheck(_ check: (@Sendable () -> Bool)?) {
        core.withLockUnchecked { $0.hasPendingGestureCompletion = check }
    }

    public func stop() {
        cancelAll()
        removeTap()
        core.withLockUnchecked { $0.clearKeys() }
        setTapAvailable(false)
    }

    private func setTapAvailable(_ available: Bool) {
        core.withLockUnchecked { $0.tapIsAvailable = available }
        onAvailabilityChanged?()
    }

    private func removeTap() {
        tapThread?.stop()
        tapThread = nil
        tapGeneration &+= 1
    }

    public func beginTransfer() -> UInt64 {
        let (token, adopted, dropped) = core.withLockUnchecked { state -> (UInt64, Bool, [UInt64]) in
            if let provisional = state.provisionalToken {
                state.provisionalToken = nil
                return (provisional, true, [])
            }
            let token = state.buffer.begin()
            let dropped = state.buffer.removeOldestEmptyTransfers(keepingAtMost: Self.maximumActiveTransfers)
            return (token, false, dropped)
        }
        for token in dropped { deadlines.removeValue(forKey: token)?.cancel() }
        if !adopted { scheduleDeadline(token) }
        startAvailabilityWatch()
        return token
    }

    private func scheduleDeadline(_ token: UInt64) {
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deadlines.removeValue(forKey: token)
            // The tap thread may already have cancelled this transfer when macOS disabled the tap.
            guard self.core.withLockUnchecked({ $0.buffer.contains(token: token) }) else { return }
            self.cancelTransfer(token: token)
            self.onTransferExpired?(token)
        }
        deadlines[token] = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(transferTimeoutMilliseconds),
            execute: deadline
        )
    }

    public func commitTransfer(token: UInt64, processIdentifier: Int32) {
        guard processIdentifier > 0 else { cancelTransfer(token: token); return }
        deadlines.removeValue(forKey: token)?.cancel()
        let events = core.withLockUnchecked { state -> [CGEvent] in
            if state.provisionalToken == token { state.provisionalToken = nil }
            let events = state.buffer.take(token: token)
            for (key, destination) in state.keyDestinations {
                if case .pending(let pendingToken) = destination, pendingToken == token {
                    state.keyDestinations[key] = .delivered(processIdentifier)
                }
            }
            return events
        }
        for event in events { post(event, processIdentifier: processIdentifier) }
        stopAvailabilityWatchIfIdle()
    }

    public func cancelTransfer(token: UInt64) {
        deadlines.removeValue(forKey: token)?.cancel()
        let events = core.withLockUnchecked { state -> [CGEvent] in
            if state.provisionalToken == token { state.provisionalToken = nil }
            let events = state.buffer.take(token: token)
            state.discardDestinations(for: token)
            return events
        }
        if !events.isEmpty { onInputDiscarded?(events.count) }
        stopAvailabilityWatchIfIdle()
    }

    /// Only visual-only navigation may be skipped. A transfer that owns typing
    /// must still visit and verify its original destination.
    public func cancelTransferIfEmpty(token: UInt64) -> Bool {
        guard core.withLockUnchecked({ $0.buffer.isEmpty(token: token) }) else { return false }
        cancelTransfer(token: token)
        return true
    }

    public func cancelAll() {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let count = core.withLockUnchecked { $0.removeAllTransfers() }
        stopAvailabilityWatchIfIdle()
        if count > 0 { onInputDiscarded?(count) }
    }

    // MARK: Availability changes during a transfer

    /// Secure Input or a disabled tap lets new keys bypass the gate while held keys would
    /// replay later, reordering typing and splitting key down/up pairs. Drop the held input
    /// instead and warn, and forget held keys so a bypassed key-up cannot route a later press.
    private func startAvailabilityWatch() {
        guard availabilityWatch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.availabilityWatchInterval, repeating: Self.availabilityWatchInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.core.withLockUnchecked({ $0.buffer.transferCount > 0 }) else {
                    self.stopAvailabilityWatchIfIdle()
                    return
                }
                if !self.isAvailable { self.cancelAllForAvailabilityChange() }
            }
        }
        timer.resume()
        availabilityWatch = timer
    }

    private func stopAvailabilityWatchIfIdle() {
        guard core.withLockUnchecked({ $0.buffer.transferCount == 0 }) else { return }
        availabilityWatch?.cancel()
        availabilityWatch = nil
    }

    private func cancelAllForAvailabilityChange() {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        let count = core.withLockUnchecked { state -> Int in
            let count = state.removeAllTransfers()
            state.clearKeys()
            return count
        }
        stopAvailabilityWatchIfIdle()
        if count > 0 { onInputDiscarded?(count) }
        onAvailabilityChanged?()
    }

    // MARK: Tap thread

    /// Runs on the tap thread. Returns true when the event is consumed. Internal so tests
    /// can drive the off-main path with synthetic events.
    nonisolated func receiveFromTap(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Events may have bypassed the tap already. Drop held input, stop protecting,
            // and let the main actor re-enable the tap with backoff.
            let discarded = core.withLockUnchecked { state -> Int in
                state.tapIsAvailable = false
                let count = state.removeAllTransfers()
                state.clearKeys()
                return count
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tapWasDisabled(discardedCount: discarded)
                }
            }
            return false
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return false }
        let secureInput = secureInputEnabled()
        let (consumed, effects) = core.withLockUnchecked { state -> (Bool, RoutingEffects) in
            guard state.tapIsAvailable, !secureInput else {
                var effects = RoutingEffects()
                effects.cancelledTokens = state.buffer.tokens
                effects.discardedCount = state.removeAllTransfers()
                state.clearKeys()
                return (false, effects)
            }
            return Self.route(type: type, event: event, state: &state, allowProvisional: true)
        }
        if !effects.isEmpty {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliver(effects) }
            }
        }
        return consumed
    }

    private func tapWasDisabled(discardedCount: Int) {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines.removeAll()
        stopAvailabilityWatchIfIdle()
        if discardedCount > 0 { onInputDiscarded?(discardedCount) }
        onAvailabilityChanged?()
        scheduleTapReenable(attempt: 0, generation: tapGeneration)
    }

    private func scheduleTapReenable(attempt: Int, generation: UInt64) {
        let delay = Self.tapReenableDelays[min(attempt, Self.tapReenableDelays.count - 1)]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.tapGeneration == generation, let tapThread = self.tapThread else { return }
                tapThread.reenable()
                // Protection resumes only once macOS confirms the tap is enabled again.
                guard tapThread.isEnabled else {
                    self.scheduleTapReenable(attempt: attempt + 1, generation: generation)
                    return
                }
                self.setTapAvailable(true)
            }
        }
    }

    /// Main-actor half of a tap-thread routing decision.
    private func deliver(_ effects: RoutingEffects) {
        for token in effects.cancelledTokens { deadlines.removeValue(forKey: token)?.cancel() }
        if let token = effects.expiredToken { deadlines.removeValue(forKey: token)?.cancel() }
        if let token = effects.provisionalToken {
            scheduleDeadline(token)
            startAvailabilityWatch()
            onBeforeKeyboardEvent?()
            releaseProvisionalTransferIfUnadopted(token)
        }
        if let action = effects.navigationAction { onNavigationAction?(action) }
        for posting in effects.postings { post(posting.event, processIdentifier: posting.pid) }
        if effects.discardedCount > 0 { onInputDiscarded?(effects.discardedCount) }
        if let token = effects.expiredToken { onTransferExpired?(token) }
        stopAvailabilityWatchIfIdle()
    }

    /// No navigation claimed the typing, so it belongs to the window that had focus when it
    /// was typed. Replay it there in order, as passing it through would have done.
    private func releaseProvisionalTransferIfUnadopted(_ token: UInt64) {
        guard core.withLockUnchecked({ $0.provisionalToken == token }) else { return }
        guard let pid = frontmostProcessIdentifier(), pid > 0 else {
            cancelTransfer(token: token)
            return
        }
        commitTransfer(token: token, processIdentifier: pid)
    }

    // MARK: Routing

    /// Returns true when consumed. Separate from tap availability so tests can use synthetic
    /// events and an injected replay sink without starting global capture or posting input.
    func processKeyboardEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else { return false }
        // A trackpad release may already be committed on its callback thread while
        // its main-queue delivery is pending. Enqueue that handoff before this key.
        onBeforeKeyboardEvent?()
        if isSecureInputEnabled {
            if core.withLockUnchecked({ $0.buffer.transferCount > 0 }) { cancelAllForAvailabilityChange() }
            return false
        }
        let (consumed, effects) = core.withLockUnchecked { state in
            Self.route(type: type, event: event, state: &state, allowProvisional: false)
        }
        deliver(effects)
        return consumed
    }

    /// Runs under the lock on either thread. Must not call back into anything that could
    /// wait on the main actor.
    nonisolated private static func route(type: CGEventType, event: CGEvent, state: inout GateState,
                                          allowProvisional: Bool) -> (consumed: Bool, effects: RoutingEffects) {
        var effects = RoutingEffects()
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyUp, state.navigationKeys.remove(key) != nil { return (true, effects) }
        if type == .keyDown, let action = ShortcutBinding.action(for: event, in: state.shortcutBindings) {
            if action != .showSettings, action != .togglePause {
                state.navigationKeys.insert(key)
                // The caller only enqueues work. It must not run AX calls on the event tap.
                // Beginning capture here closes the gap before Carbon dispatches a hotkey.
                // A held chord repeats focus and size steps; space and move steps run once.
                if !isAutorepeat || action.repeatsWhileHeld { effects.navigationAction = action }
                return (true, effects)
            }
            state.exemptKeys.insert(key)
            return (false, effects)
        }
        if state.exemptKeys.contains(key) {
            if type == .keyUp { state.exemptKeys.remove(key) }
            return (false, effects)
        }
        // A fresh press supersedes stale held-key bookkeeping if a key-up was missed while
        // secure input was enabled or the tap was unavailable. Never reroute a new press.
        if type == .keyDown, !isAutorepeat {
            state.keyDestinations.removeValue(forKey: key)
        }
        if let destination = state.keyDestinations[key] {
            if type == .keyUp { state.keyDestinations.removeValue(forKey: key) }
            switch destination {
            case .pending(let token):
                // A held key repeats until the transfer commits, which would fill the buffer
                // in seconds. Hold the first press and its release; the repeats are not lost
                // typing, they are the same key still down.
                if type == .keyDown, isAutorepeat { return (true, effects) }
                capture(event, token: token, state: &state, effects: &effects)
                return (true, effects)
            case .delivered(let pid):
                guard let copy = event.copy() else { return (true, effects) }
                effects.postings.append((copy, pid))
                return (true, effects)
            case .discarded:
                return (true, effects)
            }
        }
        guard type == .keyDown else { return (false, effects) }
        var token = state.buffer.latestToken
        if token == nil, allowProvisional, state.hasPendingGestureCompletion?() == true {
            let provisional = state.buffer.begin()
            state.provisionalToken = provisional
            effects.provisionalToken = provisional
            token = provisional
        }
        guard let token else { return (false, effects) }
        state.keyDestinations[key] = .pending(token)
        capture(event, token: token, state: &state, effects: &effects)
        return (true, effects)
    }

    nonisolated private static func capture(_ event: CGEvent, token: UInt64, state: inout GateState,
                                            effects: inout RoutingEffects) {
        guard state.buffer.eventCount < maximumBufferedEvents, let copy = event.copy() else {
            // Abandon the transfer that owns this key. Report its held events plus the
            // event that could not be buffered as one count.
            let held = state.buffer.take(token: token).count
            state.discardDestinations(for: token)
            if state.provisionalToken == token { state.provisionalToken = nil }
            effects.discardedCount += held + 1
            effects.expiredToken = token
            return
        }
        if !state.buffer.append(copy, token: token) { effects.discardedCount += 1 }
    }

    private func post(_ event: CGEvent, processIdentifier: Int32) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        postEvent(event, processIdentifier)
    }
}

private extension NavigationAction {
    /// Actions a held chord may repeat. Space switches and window moves run once per press.
    var repeatsWhileHeld: Bool {
        switch self {
        case .focusPrevious, .focusNext, .shrinkWidth, .growWidth, .shrinkHeight, .growHeight: true
        default: false
        }
    }
}

private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let thread = Unmanaged<KeyboardTapThread>.fromOpaque(context).takeUnretainedValue()
    return thread.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Hosts the keyboard tap on its own run loop, like the scroll tap in GestureMonitor. The tap
/// sees every key event on the system, so it must never wait behind the main thread.
final class KeyboardTapThread: @unchecked Sendable {
    private let handler: @Sendable (CGEventType, CGEvent) -> Bool
    // Written on the tap thread before `ready` is signaled, then only read.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(handler: @escaping @Sendable (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
    }

    var isEnabled: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        handler(type, event)
    }

    func start() -> Bool {
        // The thread retains this object until its run loop exits after `stop()`.
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: mask,
                                              callback: keyboardTapCallback, userInfo: context) else {
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
        thread.name = "Stagehand keyboard tap"
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
