import AppKit
import SwiftUI

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

final class GapTextField: NSTextField, NSTextFieldDelegate {
    var onCommit: (Double) -> Void
    private var committedValue: Double
    private let modifierFlags: () -> NSEvent.ModifierFlags

    init(value: Double, modifierFlags: @escaping () -> NSEvent.ModifierFlags = {
        NSApp.currentEvent?.modifierFlags ?? []
    }, onCommit: @escaping (Double) -> Void) {
        committedValue = GapInput.clamped(value)
        self.modifierFlags = modifierFlags
        self.onCommit = onCommit
        super.init(frame: .zero)
        delegate = self
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        alignment = .right
        placeholderString = "Points"
        setAccessibilityLabel("Gap between windows in points")
        displayValue(committedValue)
    }

    required init?(coder: NSCoder) { return nil }

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
        commit(text: stringValue)
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
