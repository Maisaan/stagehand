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

    /// Accepts the period and the current locale's decimal separator, so "2,5" is
    /// 2.5 where the keyboard produces a comma. Grouping separators are rejected
    /// rather than silently dropped.
    nonisolated static func parse(_ text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = Double(trimmed) ?? formatter(locale: locale).number(from: trimmed)?.doubleValue
        guard let value, value.isFinite else { return nil }
        return value
    }

    nonisolated static func format(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        formatter(locale: locale).string(from: NSNumber(value: value)) ?? String(value)
    }

    nonisolated private static func formatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 3
        return formatter
    }

    @Binding var value: Double
    var onCommit: (Double) -> Void

    func makeNSView(context: Context) -> GapTextField {
        GapTextField(value: value, onCommit: commit)
    }

    func updateNSView(_ field: GapTextField, context: Context) {
        field.onCommit = commit
        field.update(value: value)
    }

    private func commit(_ value: Double) {
        self.value = value
        onCommit(value)
    }
}

final class GapTextField: InsetTextField, NSTextFieldDelegate {
    var onCommit: (Double) -> Void
    private var committedValue: Double
    private var outsideClickMonitor: Any?

    init(value: Double, onCommit: @escaping (Double) -> Void) {
        committedValue = GapInput.clamped(value)
        self.onCommit = onCommit
        super.init(frame: .zero)
        delegate = self
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        alignment = .right
        setAccessibilityLabel("Gap between windows in points")
        displayValue(committedValue)
    }

    // periphery:ignore:parameters coder - AppKit requires this initializer; it is never used.
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
            let step: Double = shiftedCommand || NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 10 : 1
            let upward = commandSelector == #selector(NSResponder.moveUp(_:))
                || commandSelector == #selector(NSResponder.moveUpAndModifySelection(_:))
            let direction: Double = upward ? 1 : -1
            let current = GapInput.parse(textView.string) ?? committedValue
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
        guard let value = GapInput.parse(text) else {
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
        let text = GapInput.format(value)
        stringValue = text
        if let editor {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
    }
}
