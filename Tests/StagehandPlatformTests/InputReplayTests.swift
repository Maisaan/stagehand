import AppKit
import Foundation
import Testing
@testable import StagehandPlatform

/// TEMPORARY, with `InputRecorder`: replays a recorded session through the current
/// `GestureCallbackState` and writes an annotated timeline.
///
///     STAGEHAND_REPLAY=~/Library/Logs/Stagehand/input-recording.csv \
///     STAGEHAND_REPLAY_OUT=/path/report.txt swift test --filter InputReplay
///
/// `STAGEHAND_REPLAY_FROM` / `_TO` limit the report to an uptime range. Each event line
/// shows the recorded decision and the replayed one (`W` withheld, `P` passed); `!` marks
/// a difference. With the recording's build, there should be none.
@Test(.enabled(if: ProcessInfo.processInfo.environment["STAGEHAND_REPLAY"] != nil))
func inputReplay() throws {
    let environment = ProcessInfo.processInfo.environment
    let path = (environment["STAGEHAND_REPLAY"]! as NSString).expandingTildeInPath
    let from = environment["STAGEHAND_REPLAY_FROM"].flatMap(Double.init) ?? 0
    let to = environment["STAGEHAND_REPLAY_TO"].flatMap(Double.init) ?? .infinity
    let text = try String(contentsOfFile: path, encoding: .utf8)

    var state = GestureCallbackState()
    state.enabled = true
    state.recognizer = NavigationGestureRecognizer(fingerCount: 3)
    state.unmodifiedEnabled = true
    state.shortcutBindings = ShortcutBinding.defaults

    var report: [String] = []
    var mismatches = 0
    var events = 0
    var lastCount = -1
    var frame: Int32 = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix("#") {
            // A new recording session: gestures restarted with fresh state.
            state = GestureCallbackState()
            state.enabled = true
            state.recognizer = NavigationGestureRecognizer(fingerCount: 3)
            state.unmodifiedEnabled = true
            state.shortcutBindings = ShortcutBinding.defaults
            report.append(String(line))
            continue
        }
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let now = Double(fields[1]) else { continue }
        let inRange = now >= from && now <= to
        if fields[0] == "F" {
            let timestamp = Double(fields[2]) ?? 0
            let flags = CGEventFlags(rawValue: UInt64(fields[3]) ?? 0)
            let buttonDown = fields[4] == "1"
            var contacts: [GestureContact] = []
            var touches: [GestureFrameValidator.Touch] = []
            for item in fields[5].split(separator: ";") {
                let parts = item.split(separator: ":").map(String.init)
                guard parts.count == 5, let id = Int32(parts[0]), let touchFrame = Int32(parts[1]),
                      let touchState = UInt32(parts[2]), let x = Float(parts[3]), let y = Float(parts[4]) else { continue }
                let touching = touchState == 3 || touchState == 4
                touches.append(.init(frame: touchFrame, state: touchState, x: x, y: y, isTouching: touching))
                if touching { contacts.append(GestureContact(id: id, x: Double(x), y: Double(y))) }
                frame = max(frame, touchFrame)
            }
            let before = state.recognizer.isDragging
            _ = state.process(contacts: contacts, touches: touches, rawCount: Int32(touches.count), flags: flags,
                              timestamp: timestamp, now: now, buttonDown: buttonDown)
            let owned = state.ownership.ownsSequence
            if inRange, contacts.count != lastCount || before != state.recognizer.isDragging {
                report.append(String(format: "%.4f F contacts=%d owned=%@ dragging=%@", now, contacts.count,
                                      owned ? "y" : "n", state.recognizer.isDragging ? "y" : "n"))
            }
            lastCount = contacts.count
        } else if fields[0] == "E", fields.count >= 12 {
            let eventTime = Double(fields[2])
            let cgType = UInt32(fields[3]) ?? 0
            let phase = Int64(fields[4]) ?? 0
            let momentum = Int64(fields[5]) ?? 0
            let recordedWithheld = fields[9] == "1"
            let kind: SuppressibleInputEvent = if cgType == CGEventType.scrollWheel.rawValue {
                .scroll(phase: phase, momentumPhase: momentum)
            } else if cgType == dockControlEventType {
                .dockControl
            } else if cgType == UInt32(NSEvent.EventType.beginGesture.rawValue) {
                .gestureStart
            } else {
                .gesture
            }
            let withheld = state.suppress(kind, now: now, rawType: cgType, eventTime: eventTime)
            events += 1
            if withheld != recordedWithheld { mismatches += 1 }
            guard inRange else { continue }
            let tail = state.ownership.inLiftTail(now: now) ? " tail" : ""
            let lag = eventTime.map { String(format: " made%+.1fms", ($0 - now) * 1000) } ?? ""
            let what = cgType == CGEventType.scrollWheel.rawValue
                ? "scroll phase=\(phase) momentum=\(momentum) dx=\(fields[6]) dy=\(fields[7])"
                : "type=\(cgType) nsPhase=\(fields[10]) touches=\(fields[11])"
            report.append(String(format: "%.4f E %@%@%@ %@ pid=%@%@%@", now,
                                  recordedWithheld ? "W" : "P", withheld ? "W" : "P",
                                  withheld != recordedWithheld ? "!" : " ", what, fields[8], lag, tail))
        }
    }
    report.append("events=\(events) mismatches=\(mismatches) \(state.appInputLeaks.summary)")
    if let out = environment["STAGEHAND_REPLAY_OUT"] {
        try report.joined(separator: "\n").write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    } else {
        print(report.suffix(200).joined(separator: "\n"))
    }
    if environment["STAGEHAND_REPLAY_EXPECT_MATCH"] != nil { #expect(mismatches == 0) }
}
