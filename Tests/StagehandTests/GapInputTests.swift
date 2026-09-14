import AppKit
import Testing
@testable import Stagehand

@Test @MainActor func gapInputArrowCommandsCommitOneStepAndShiftTen() {
    _ = NSApplication.shared
    var changes: [Double] = []
    var flags: NSEvent.ModifierFlags = []
    let field = GapTextField(value: 8, modifierFlags: { flags }) { changes.append($0) }
    let editor = NSTextView()
    editor.string = "8"
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    #expect(editor.string == "9")
    #expect(changes == [9])

    flags = .shift
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDownAndModifySelection(_:))))
    #expect(editor.string == "-1")
    #expect(changes == [9, -1])
    field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    #expect(changes == [9, -1])
}

@Test @MainActor func gapInputCommitsSignedNumbersOnEnterOrBlurAndRestoresInvalidText() {
    _ = NSApplication.shared
    var changes: [Double] = []
    let field = GapTextField(value: 8) { changes.append($0) }
    let editor = NSTextView()
    editor.string = "-"
    field.stringValue = "-"
    field.update(value: 8)
    #expect(field.stringValue == "-")
    #expect(changes.isEmpty)
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(editor.string == "8")
    #expect(changes.isEmpty)

    editor.string = "+12"
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(editor.string == "12")
    #expect(changes == [12])
    field.stringValue = "-125"
    field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    #expect(changes == [12, -125])
    field.stringValue = "nan"
    field.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    #expect(field.stringValue == "-125")
    #expect(changes == [12, -125])
}

@Test @MainActor func gapInputClampsTextAndArrowCommandsToSliderBounds() {
    _ = NSApplication.shared
    var changes: [Double] = []
    let field = GapTextField(value: 39) { changes.append($0) }
    let editor = NSTextView()
    editor.string = "39"
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    #expect(changes == [40])
    editor.string = "-999"
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(editor.string == "-200")
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(changes == [40, -200])
    #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
}
