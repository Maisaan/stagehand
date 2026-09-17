import AppKit
import SwiftUI

enum TextInputMetrics {
    static let height: CGFloat = 24
    static let horizontalPadding: CGFloat = 8
}

private final class InsetTextFieldCell: NSTextFieldCell {
    private func textFrame(forBounds bounds: NSRect) -> NSRect {
        let paddedBounds = bounds.insetBy(dx: TextInputMetrics.horizontalPadding, dy: 0)
        let textHeight = super.cellSize(forBounds: paddedBounds).height
        return NSRect(
            x: paddedBounds.minX,
            y: paddedBounds.midY - textHeight / 2,
            width: paddedBounds.width,
            height: textHeight
        )
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: textFrame(forBounds: cellFrame), in: controlView)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: textFrame(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: textFrame(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}

class InsetTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = InsetTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBezeled = false
        drawsBackground = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: TextInputMetrics.height)
    }
}

struct GapInput: NSViewRepresentable {
    static let bounds: ClosedRange<Double> = -200...40

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 8 }
        return min(max(value, bounds.lowerBound), bounds.upperBound)
    }

    @Binding var value: Double
    var onCommit: (Double) -> Void

    func makeNSView(context: Context) -> GapTextField {
        GapTextField(value: value) { value in
            self.value = value
            onCommit(value)
        }
    }

    func updateNSView(_ field: GapTextField, context: Context) {
        field.onCommit = { value in
            self.value = value
            onCommit(value)
        }
        field.update(value: value)
    }
}

final class GapTextField: InsetTextField, NSTextFieldDelegate {
    var onCommit: (Double) -> Void
    private var committedValue: Double
    private let modifierFlags: () -> NSEvent.ModifierFlags
    private var outsideClickMonitor: Any?

    init(value: Double, modifierFlags: @escaping () -> NSEvent.ModifierFlags = {
        NSApp.currentEvent?.modifierFlags ?? []
    }, onCommit: @escaping (Double) -> Void) {
        committedValue = GapInput.clamped(value)
        self.modifierFlags = modifierFlags
        self.onCommit = onCommit
        super.init(frame: .zero)
        delegate = self
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        alignment = .right
        setAccessibilityLabel("Gap between windows in points")
        displayValue(committedValue)
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { monitorOutsideClicks() }
        return accepted
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopMonitoringOutsideClicks() }
        super.viewWillMove(toWindow: newWindow)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        monitorOutsideClicks()
    }

    func update(value: Double) {
        let value = GapInput.clamped(value)
        guard value != committedValue else { return }
        committedValue = value
        displayValue(value, editor: currentEditor() as? NSTextView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            let shiftedCommand = commandSelector == #selector(NSResponder.moveUpAndModifySelection(_:))
                || commandSelector == #selector(NSResponder.moveDownAndModifySelection(_:))
            let step: Double = shiftedCommand || modifierFlags().contains(.shift) ? 10 : 1
            let upward = commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveUpAndModifySelection(_:))
            let direction: Double = upward ? 1 : -1
            let parsed = Double(textView.string.trimmingCharacters(in: .whitespacesAndNewlines))
            let current = parsed.flatMap { $0.isFinite ? $0 : nil } ?? committedValue
            commit(value: current + direction * step, editor: textView)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(text: textView.string, editor: textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        stopMonitoringOutsideClicks()
        commit(text: stringValue)
    }

    private func monitorOutsideClicks() {
        guard outsideClickMonitor == nil, let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(editingWindowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window
        )
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let window = self.window, self.currentEditor() != nil else { return event }
            let isInside = event.window === window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !isInside { window.makeFirstResponder(nil) }
            return event
        }
    }

    private func stopMonitoringOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func editingWindowResignedKey() {
        guard currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    private func commit(text: String, editor: NSTextView? = nil) {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else {
            displayValue(committedValue, editor: editor)
            return
        }
        commit(value: value, editor: editor)
    }

    private func commit(value: Double, editor: NSTextView?) {
        let value = GapInput.clamped(value)
        let changed = value != committedValue
        committedValue = value
        displayValue(value, editor: editor)
        if changed { onCommit(value) }
    }

    private func displayValue(_ value: Double, editor: NSTextView? = nil) {
        let text = value == value.rounded() ? String(Int(value)) : String(value)
        stringValue = text
        if let editor {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
    }
}
