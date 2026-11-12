import AppKit
import Carbon
import os

public enum OwnerInputKind: String, CaseIterable, Sendable {
    case keyboard, mouse, scroll, gesture

    private static let eventTypes: [OwnerInputKind: [UInt32]] = [
        .keyboard: [CGEventType.keyDown, .keyUp, .flagsChanged].map(\.rawValue),
        .mouse: [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                 .otherMouseDown, .otherMouseUp, .otherMouseDragged].map(\.rawValue),
        .scroll: [CGEventType.scrollWheel.rawValue],
        .gesture: [NSEvent.EventType.gesture, .beginGesture, .endGesture, .magnify, .swipe, .rotate,
                   .smartMagnify, .pressure, .directTouch].map { UInt32($0.rawValue) }
    ]

    private static let kindByEventType: [UInt32: OwnerInputKind] = Dictionary(
        eventTypes.flatMap { kind, types in types.map { ($0, kind) } }, uniquingKeysWith: { first, _ in first })

    static let eventMask: CGEventMask = kindByEventType.keys.reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1)) }

    init?(eventType: UInt32) {
        guard let kind = Self.kindByEventType[eventType] else { return nil }
        self = kind
    }
}

public struct OwnerInputTally: Equatable, Sendable {
    public private(set) var counts: [OwnerInputKind: Int] = [:]
    public private(set) var secondsToFirstEvent: TimeInterval?

    public init() {}

    public var total: Int { counts.values.reduce(0, +) }

    mutating func record(_ kind: OwnerInputKind, secondsSinceStart: TimeInterval) {
        counts[kind, default: 0] += 1
        secondsToFirstEvent = min(secondsToFirstEvent ?? secondsSinceStart, secondsSinceStart)
    }
}

public enum OwnerInputReading: Equatable, Sendable {
    case observed(OwnerInputTally)
    case unknown(reason: String)

    public var touched: Bool {
        if case .observed(let tally) = self { return tally.total > 0 }
        return false
    }

    public var summary: String {
        switch self {
        case .unknown(let reason):
            return "unknown (\(reason))"
        case .observed(let tally) where tally.total == 0:
            return "none"
        case .observed(let tally):
            let kinds = OwnerInputKind.allCases.compactMap { kind in
                tally.counts[kind].map { "\(kind.rawValue) \($0)" }
            }
            let first = tally.secondsToFirstEvent.map { String(format: ", first at %.1f s", $0) } ?? ""
            return "\(tally.total) (\(kinds.joined(separator: ", ")))\(first)"
        }
    }
}

/// CGEvents carry the process ID of the process that created them, so anything not
/// created by `syntheticSourcePIDs` counts, whatever its source state.
struct OwnerInputRecorder: Sendable {
    let syntheticSourcePIDs: Set<Int64>
    let startedAt: TimeInterval
    private(set) var tally = OwnerInputTally()
    private(set) var blindSpot: String?

    init(syntheticSourcePIDs: Set<Int64>, startedAt: TimeInterval) {
        self.syntheticSourcePIDs = syntheticSourcePIDs
        self.startedAt = startedAt
    }

    mutating func receive(eventType: UInt32, sourcePID: Int64, at uptime: TimeInterval) {
        guard !syntheticSourcePIDs.contains(sourcePID), let kind = OwnerInputKind(eventType: eventType) else { return }
        tally.record(kind, secondsSinceStart: max(0, uptime - startedAt))
    }

    mutating func noteBlindSpot(_ reason: String) {
        if blindSpot == nil { blindSpot = reason }
    }

    /// Input that was seen proves a touch even when some could have been missed.
    var reading: OwnerInputReading {
        if tally.total == 0, let blindSpot { return .unknown(reason: blindSpot) }
        return .observed(tally)
    }
}

/// HIDIdleTime cannot tell a touched run from an untouched one: synthetic events reset it.
public final class OwnerInputMonitor: @unchecked Sendable {
    struct Environment {
        var inputHiddenReason: () -> String?
        var createTap: (CGEventMask, @escaping CGEventTapCallBack, UnsafeMutableRawPointer) -> CFMachPort?
        var setTapEnabled: (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) }

        static var live: Environment {
            Environment(
                inputHiddenReason: {
                    if !AXIsProcessTrusted() { return "no Accessibility permission, so keys are hidden from the tap" }
                    if IsSecureEventInputEnabled() { return "Secure Keyboard Entry is on, so keys are hidden from the tap" }
                    return nil
                },
                createTap: { mask, callback, context in
                    // HID level sees real input before any session tap, Stagehand's included, can hold or drop it.
                    CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: callback, userInfo: context)
                }
            )
        }
    }

    private let environment: Environment
    private let syntheticSourcePIDs: Set<Int64>
    private let recorder: OSAllocatedUnfairLock<OwnerInputRecorder?> = .init(initialState: nil)
    // Written on the tap thread before `ready` is signaled, then only read.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private var started = false
    private var finalReading: OwnerInputReading?

    public convenience init(syntheticSourcePIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]) {
        self.init(syntheticSourcePIDs: syntheticSourcePIDs, environment: .live)
    }

    init(syntheticSourcePIDs: Set<pid_t>, environment: Environment) {
        self.syntheticSourcePIDs = Set(syntheticSourcePIDs.map(Int64.init))
        self.environment = environment
    }

    /// Call once, from the thread that will call `stop()`.
    public func start() {
        guard !started else { return }
        started = true
        var initial = OwnerInputRecorder(syntheticSourcePIDs: syntheticSourcePIDs,
                                         startedAt: ProcessInfo.processInfo.systemUptime)
        if let hidden = environment.inputHiddenReason() { initial.noteBlindSpot(hidden) }
        let recorderAtStart = initial
        recorder.withLock { $0 = recorderAtStart }
        // The thread retains this object until its run loop exits after `stop()`.
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = environment.createTap(OwnerInputKind.eventMask, ownerInputTapCallback, context) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            environment.setTapEnabled(tap, true)
            ready.signal()
            // Invalidating the tap from another thread does not wake this run loop, so
            // `stop()` also stops it. The validity check covers a stop that lands first.
            while CFMachPortIsValid(tap),
                  CFRunLoopRunInMode(.defaultMode, 1e10, false) != .stopped {}
        }
        thread.name = "Stagehand owner input tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if tap == nil { noteBlindSpot("the input tap could not be created") }
    }

    public func stop() -> OwnerInputReading {
        if let finalReading { return finalReading }
        if let hidden = environment.inputHiddenReason() { noteBlindSpot(hidden) }
        // Close the recording before teardown: disabling the tap makes macOS call back with tapDisabledByUserInput.
        let reading = recorder.withLock { recording in
            defer { recording = nil }
            return recording?.reading
        } ?? .unknown(reason: "the monitor was not started")
        finalReading = reading
        if let tap {
            environment.setTapEnabled(tap, false)
            CFMachPortInvalidate(tap)
            if let runLoop { CFRunLoopStop(runLoop) }
        }
        return reading
    }

    fileprivate func receive(eventType: UInt32, sourcePID: Int64, at uptime: TimeInterval) {
        recorder.withLock { $0?.receive(eventType: eventType, sourcePID: sourcePID, at: uptime) }
    }

    fileprivate func tapWasDisabled(_ type: CGEventType) {
        let reason = type == .tapDisabledByTimeout
            ? "the input tap timed out and macOS paused it during the run"
            : "macOS disabled the input tap for user input during the run"
        let stillRecording = recorder.withLock { recording in
            recording?.noteBlindSpot(reason)
            return recording != nil
        }
        if stillRecording, let tap { environment.setTapEnabled(tap, true) }
    }

    private func noteBlindSpot(_ reason: String) {
        recorder.withLock { $0?.noteBlindSpot(reason) }
    }
}

private let ownerInputTapCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<OwnerInputMonitor>.fromOpaque(context).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.tapWasDisabled(type)
    } else {
        let now = ProcessInfo.processInfo.systemUptime
        monitor.receive(eventType: type.rawValue, sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                        at: eventUptime(event.timestamp, now: now) ?? now)
    }
    return Unmanaged.passUnretained(event)
}
