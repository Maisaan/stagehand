import AppKit
import Testing
import StagehandCore
@testable import Stagehand

@Test @MainActor func preferenceRequestPolicyDoesNotBeginInputCaptureOrActivateAWindow() async {
    var captures = 0
    var activations = 0
    let token = LayoutRequestPolicy.preferences.beginInputTransfer {
        captures += 1
        return 1
    }
    let focused = await LayoutRequestPolicy.preferences.confirmFocus(
        windowID: "settings", currentFocus: { "settings" }, activate: { activations += 1; return true }
    )
    #expect(token == nil)
    #expect(captures == 0)
    #expect(focused)
    #expect(activations == 0)

    let changed = await LayoutRequestPolicy.preferences.confirmFocus(
        windowID: "settings", currentFocus: { "other-app" }, activate: { activations += 1; return true }
    )
    #expect(!changed)
    #expect(activations == 0)
}

@Test @MainActor func preferenceRequestUsesActualManagedFocusAndDefersUnknownFocus() {
    let state = WorkspaceState(spaces: [
        SpaceState(windowIDs: ["editor", "settings"], focusedWindowID: "editor"),
        SpaceState(windowIDs: ["browser", "settings"], focusedWindowID: "browser")
    ])
    let aligned = LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: "settings")
    #expect(aligned?.focusedWindowID == "settings")
    #expect(aligned?.activeSpaceIndex == 0)
    #expect(aligned?.spaces[1] == state.spaces[1])
    #expect(LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: nil) == nil)
    #expect(LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: "unmanaged") == nil)

    let otherSpace = LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: "browser")
    #expect(otherSpace?.activeSpaceIndex == 1)
    #expect(otherSpace?.focusedWindowID == "browser")
}

@Test @MainActor func navigationRequestRetainsInputCaptureAndActivation() async {
    var captures = 0
    var activations = 0
    let token = LayoutRequestPolicy.navigation.beginInputTransfer {
        captures += 1
        return 7
    }
    let focused = await LayoutRequestPolicy.navigation.confirmFocus(
        windowID: "editor", currentFocus: { nil }, activate: { activations += 1; return true }
    )
    #expect(token == 7)
    #expect(captures == 1)
    #expect(focused)
    #expect(activations == 1)
}

@Test @MainActor func preferencePolicyLeavesTheNativeFieldEditorFocusedAfterAnArrowCommit() async throws {
    _ = NSApplication.shared
    var captures = 0
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = GapTextField(value: 8) { _ in
        _ = LayoutRequestPolicy.preferences.beginInputTransfer { captures += 1; return 1 }
    }
    window.contentView = field
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
    let confirmed = await LayoutRequestPolicy.preferences.confirmFocus(
        windowID: "settings", currentFocus: { "settings" }, activate: {
            window.makeFirstResponder(nil)
            return true
        }
    )
    #expect(confirmed)
    #expect(captures == 0)
    #expect(window.firstResponder === editor)
    #expect(editor.string == "9")
}
