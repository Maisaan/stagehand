import AppKit
import StagehandPlatform

/// Tells a drag-and-drop (a file, text, or a link carried to another window) apart from
/// the other things a held left button does: a title-bar drag, a resize, a selection.
///
/// Starting a drag session gives AppKit's drag pasteboard a new change count; nothing
/// else writes it. The count is sampled as each press begins, and a press counts as a
/// drag-and-drop once the count differs. A press whose start Stagehand did not see, or
/// one that began in Stagehand's own windows (a reorder in Settings), never counts:
/// a missed event keeps the title-bar behavior instead of fighting a window drag.
@MainActor
final class PointerDragTracker {
    private let buttonDown: () -> Bool
    private let dragChangeCount: () -> Int
    private var monitors: [Any] = []
    /// The drag pasteboard's count when the current press began, or nil.
    private var pressBaseline: Int?
    private var pressCarriesDrop = false
    private let now: () -> TimeInterval
    private let heldClickTravel: () -> Double
    private let dockEventsWithheld: () -> Int
    private let syntheticPointerEvents: () -> Int
    /// The current press, for the summary logged when a drag-and-drop ends.
    private var press: PressRecord?

    /// Whether the pointer kept moving while the drag was carried. macOS can stop sending
    /// pointer events for a held click once it takes the fingers beside it for a gesture
    /// of its own; the held finger's travel during the longest gap tells that apart from
    /// a finger that was resting.
    private struct PressRecord {
        let began: TimeInterval
        let dockEventsAtStart: Int
        let syntheticPointerEventsAtStart: Int
        var synthesisAtStart = SyntheticPointerStats()
        var dragEvents = 0
        /// Drags Stagehand posted itself; they do not end a gap in macOS's.
        var syntheticDragsSeen = 0
        var lastDrag: TimeInterval
        var travelAtLastDrag: Double
        var longestGap: TimeInterval = 0
        var travelDuringLongestGap: Double = 0

        mutating func pointerMoved(at time: TimeInterval, travel: Double) {
            closeGap(at: time, travel: travel)
            dragEvents += 1
            lastDrag = time
            travelAtLastDrag = travel
        }

        mutating func closeGap(at time: TimeInterval, travel: Double) {
            guard time - lastDrag > longestGap else { return }
            longestGap = time - lastDrag
            travelDuringLongestGap = travel - travelAtLastDrag
        }
    }

    /// Called with the summary of each press that carried a drag-and-drop, as it ends.
    var onDragAndDropEnded: (([String: String]) -> Void)?

    private static let dragPasteboard = NSPasteboard(name: .drag)

    /// Counts since `start`; the maxima were reset when the press began.
    static func synthesisDetails(_ stats: SyntheticPointerStats, since start: SyntheticPointerStats) -> [String: String] {
        ["syntheticReanchors": String(stats.reanchors - start.reanchors),
         "syntheticSubPointFrames": String(stats.subPointFrames - start.subPointFrames),
         "syntheticLongestFrameGapMilliseconds": String(Int(stats.longestFrameGapMilliseconds)),
         "syntheticSlowestPostMicroseconds": String(Int(stats.slowestPostMicroseconds))]
    }

    init(buttonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
         dragChangeCount: @escaping () -> Int = { PointerDragTracker.dragPasteboard.changeCount },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         heldClickTravel: @escaping () -> Double = { InputController.heldClickTravel() },
         dockEventsWithheld: @escaping () -> Int = { InputController.withheldDockControlEventCount() },
         syntheticPointerEvents: @escaping () -> Int = { InputController.syntheticPointerEventCount() }) {
        self.syntheticPointerEvents = syntheticPointerEvents
        self.buttonDown = buttonDown
        self.dragChangeCount = dragChangeCount
        self.now = now
        self.heldClickTravel = heldClickTravel
        self.dockEventsWithheld = dockEventsWithheld
    }

    var isButtonDown: Bool { buttonDown() }

    /// The left button is held and a drag session began during this press. Reads the
    /// pasteboard (one round trip to its server) at most until the answer is yes.
    var isDragAndDrop: Bool {
        guard buttonDown() else {
            pressEnded()
            return false
        }
        if pressCarriesDrop { return true }
        guard let pressBaseline else { return false }
        pressCarriesDrop = dragChangeCount() != pressBaseline
        return pressCarriesDrop
    }

    func start() {
        guard monitors.isEmpty else { return }
        let down: NSEvent.EventTypeMask = [.leftMouseDown]
        let up: NSEvent.EventTypeMask = [.leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: down, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pressBegan(inStagehand: false) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: down, handler: { [weak self] event in
            self?.pressBegan(inStagehand: true)
            return event
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: up, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pressEnded() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: up, handler: { [weak self] event in
            self?.pressEnded()
            return event
        }) { monitors.append(monitor) }
        let dragged: NSEvent.EventTypeMask = [.leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: dragged, handler: { [weak self] event in
            let synthetic = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == InputController.syntheticPointerTag
            MainActor.assumeIsolated { self?.pointerDragged(synthetic: synthetic) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: dragged, handler: { [weak self] event in
            self?.pointerDragged()
            return event
        }) { monitors.append(monitor) }
    }

    func pointerDragged(synthetic: Bool = false) {
        if synthetic {
            press?.syntheticDragsSeen += 1
            return
        }
        press?.pointerMoved(at: now(), travel: heldClickTravel())
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pressEnded()
    }

    func pressBegan(inStagehand: Bool) {
        pressCarriesDrop = false
        pressBaseline = inStagehand ? nil : dragChangeCount()
        let time = now()
        let synthesisAtStart = InputController.syntheticPointerStats(reset: true)
        press = PressRecord(began: time, dockEventsAtStart: dockEventsWithheld(),
                            syntheticPointerEventsAtStart: syntheticPointerEvents(),
                            lastDrag: time, travelAtLastDrag: heldClickTravel())
        press?.synthesisAtStart = synthesisAtStart
    }

    func pressEnded() {
        // A press nothing asked about during it still gets its summary.
        if !pressCarriesDrop, press != nil, let pressBaseline, dragChangeCount() != pressBaseline {
            pressCarriesDrop = true
        }
        if pressCarriesDrop, var press {
            let time = now()
            press.closeGap(at: time, travel: heldClickTravel())
            onDragAndDropEnded?([
                "durationMilliseconds": String(Int((time - press.began) * 1_000)),
                "pointerDragEvents": String(press.dragEvents),
                "longestPointerGapMilliseconds": String(Int(press.longestGap * 1_000)),
                // Thousandths of the trackpad's width.
                "heldFingerTravelDuringGap": String(Int(press.travelDuringLongestGap * 1_000)),
                "dockControlEventsWithheld": String(dockEventsWithheld() - press.dockEventsAtStart),
                // Pointer drags Stagehand posted while macOS had the touch locked, and
                // how many of them came back through the event monitor.
                "syntheticPointerEvents": String(syntheticPointerEvents() - press.syntheticPointerEventsAtStart),
                "syntheticDragsSeen": String(press.syntheticDragsSeen)
            ].merging(Self.synthesisDetails(InputController.syntheticPointerStats(reset: false),
                                            since: press.synthesisAtStart)) { current, _ in current })
        }
        press = nil
        pressCarriesDrop = false
        pressBaseline = nil
    }
}
