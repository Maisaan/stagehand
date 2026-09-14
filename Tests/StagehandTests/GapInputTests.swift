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

@Test @MainActor func gapInputCommitsAndResignsWhenClickingNonfocusableBackground() throws {
    _ = NSApplication.shared
    var changes: [Double] = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let background = GapClickTarget(frame: window.contentLayoutRect)
    window.contentView = background
    let field = GapTextField(value: 8) { changes.append($0) }
    field.frame = NSRect(x: 20, y: 100, width: 80, height: 24)
    background.addSubview(field)
    window.orderFrontRegardless()
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("-35", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    #expect(changes.isEmpty)

    let click = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 230, y: 20), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    ))
    NSApp.sendEvent(click)

    #expect(window.firstResponder !== editor)
    #expect(field.currentEditor() == nil)
    #expect(changes == [-35])
    #expect(background.clicks == 1)

    // Refocusing without typing must still dismiss on the next outside click.
    #expect(window.makeFirstResponder(field))
    #expect(field.currentEditor() != nil)
    NSApp.sendEvent(click)
    #expect(field.currentEditor() == nil)
    #expect(changes == [-35])
    #expect(background.clicks == 2)
}

@Test @MainActor func gapInputCommitsWhenItsWindowResignsKey() throws {
    _ = NSApplication.shared
    var changes: [Double] = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = GapTextField(value: 8) { changes.append($0) }
    field.frame = NSRect(x: 20, y: 100, width: 80, height: 24)
    window.contentView?.addSubview(field)
    window.makeKeyAndOrderFront(nil)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("-35", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    window.resignKey()
    #expect(field.currentEditor() == nil)
    #expect(changes == [-35])
}

private final class GapClickTarget: NSView {
    private(set) var clicks = 0
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}
