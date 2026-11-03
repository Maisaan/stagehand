import AppKit
import os

/// TEMPORARY, for the browser back/forward leak (2026-11-03); remove once it is fixed.
///
/// Records trackpad contact frames and every scroll and gesture event the input tap
/// decides, in order, to `~/Library/Logs/Stagehand/input-recording.csv`, so a real session
/// can be replayed through `GestureCallbackState` in tests (`InputReplayTests`). Off unless
/// the `StagehandRecordInput` default is true when gestures start. Finger positions and
/// event timing only; the file stays on this Mac.
///
/// Lines:
/// - `F,now,mtTimestamp,flags,buttonDown,id:frame:state:x:y;...` one contact frame.
/// - `E,now,eventTime,cgType,phase,momentumPhase,dx,dy,targetPID,withheld,nsPhase,touches`
///   one tap event; `touches` lists `id:phase:x:y` for gesture events.
enum InputRecorder {
    static let preferenceKey = "StagehandRecordInput"
    static let maximumBytes = 200_000_000

    nonisolated(unsafe) private(set) static var isEnabled = false
    private static let pending = OSAllocatedUnfairLock(initialState: [String]())
    private static let queue = DispatchQueue(label: "Stagehand input recorder", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var written = 0

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Stagehand/input-recording.csv")
    }

    /// Called on main when gestures start. Appends to an existing recording.
    static func startIfRequested() {
        guard UserDefaults.standard.bool(forKey: preferenceKey), timer == nil else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let fileHandle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? fileHandle.seekToEnd()
        handle = fileHandle
        written = Int((try? fileHandle.offset()) ?? 0)
        append("# start uptime=\(ProcessInfo.processInfo.systemUptime) date=\(Date())")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 0.5, repeating: 0.5)
        source.setEventHandler { flush() }
        source.resume()
        timer = source
        isEnabled = true
    }

    static func stop() {
        guard isEnabled else { return }
        isEnabled = false
        queue.sync {
            flush()
            timer?.cancel()
            timer = nil
            try? handle?.close()
            handle = nil
        }
    }

    private static func append(_ line: String) {
        pending.withLock { $0.append(line) }
    }

    /// On `queue`.
    private static func flush() {
        let lines = pending.withLock { lines -> [String] in
            defer { lines.removeAll(keepingCapacity: true) }
            return lines
        }
        guard !lines.isEmpty, let handle, written < maximumBytes else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        handle.write(data)
        written += data.count
        if written >= maximumBytes { isEnabled = false }
    }

    static func recordFrame(now: TimeInterval, timestamp: Double, flags: CGEventFlags, buttonDown: Bool,
                            touches: [(id: Int32, frame: Int32, state: UInt32, x: Float, y: Float)]) {
        let contacts = touches.map { "\($0.id):\($0.frame):\($0.state):\($0.x):\($0.y)" }.joined(separator: ";")
        append("F,\(now),\(timestamp),\(flags.rawValue),\(buttonDown ? 1 : 0),\(contacts)")
    }

    static func recordEvent(_ event: CGEvent, type: CGEventType, now: TimeInterval, eventTime: TimeInterval?,
                            withheld: Bool) {
        var phase: Int64 = 0, momentum: Int64 = 0, dx: Double = 0, dy: Double = 0
        if type == .scrollWheel {
            phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        }
        let pid = event.getIntegerValueField(.eventTargetUnixProcessID)
        var nsPhase = ""
        var touchList = ""
        if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue) {
            autoreleasepool {
                guard let nsEvent = NSEvent(cgEvent: event) else { nsPhase = "nil"; return }
                nsPhase = String(nsEvent.phase.rawValue)
                touchList = nsEvent.touches(matching: .any, in: nil).map { touch in
                    "\(touch.identity.hash):\(touch.phase.rawValue):\(touch.normalizedPosition.x):\(touch.normalizedPosition.y)"
                }.joined(separator: ";")
            }
        }
        let time = eventTime.map { String($0) } ?? ""
        append("E,\(now),\(time),\(type.rawValue),\(phase),\(momentum),\(dx),\(dy),\(pid),\(withheld ? 1 : 0),\(nsPhase),\(touchList)")
    }
}
