import AppKit

/// Tells a drag-and-drop (a file, text, or a link carried to another window) apart from
/// the other things a held left button does: a title-bar drag, a resize, a selection.
///
/// Starting a drag session gives AppKit's drag pasteboard a new change count; nothing
/// else writes it. The count is sampled as each press begins, and a press counts as a
/// drag-and-drop once the count differs. A press whose start Stagehand did not see, or
/// one that began in Stagehand's own windows (the app bar's reorder drag), never counts:
/// a missed event keeps the title-bar behavior instead of fighting a window drag.
@MainActor
final class PointerDragTracker {
    private let buttonDown: () -> Bool
    private let dragChangeCount: () -> Int
    private var monitors: [Any] = []
    /// The drag pasteboard's count when the current press began, or nil.
    private var pressBaseline: Int?
    private var pressCarriesDrop = false

    private static let dragPasteboard = NSPasteboard(name: .drag)

    init(buttonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
         dragChangeCount: @escaping () -> Int = { PointerDragTracker.dragPasteboard.changeCount }) {
        self.buttonDown = buttonDown
        self.dragChangeCount = dragChangeCount
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
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pressEnded()
    }

    func pressBegan(inStagehand: Bool) {
        pressCarriesDrop = false
        pressBaseline = inStagehand ? nil : dragChangeCount()
    }

    func pressEnded() {
        pressCarriesDrop = false
        pressBaseline = nil
    }
}
