import AppKit
import Testing
@testable import StagehandPlatform

@Suite(.serialized) @MainActor
struct NativeWindowTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = RibbonWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 680, height: 610),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stagehand test window"
        return window
    }

    @Test func onlyExplicitlyRegisteredWindowsJoinManagement() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        #expect(registry.records.isEmpty)
        let id = registry.register(window: settings)
        #expect(registry.records.map(\.id) == [id])
        #expect(registry.register(window: settings) == id)
    }

    @Test func parkingKeepsMembershipAndPauseRestoresOriginalGeometry() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        let original = registry.frame(windowID: id)
        let requested = CGRect(x: 10_100, y: 10_100, width: 900, height: 700)
        #expect(registry.setFrame(windowID: id, frame: requested))
        #expect(registry.park(windowID: id))
        #expect(!settings.isVisible)
        #expect(registry.records.map(\.id) == [id])
        #expect(registry.frame(windowID: id) == requested)
        registry.restoreAll()
        #expect(settings.isVisible)
        #expect(registry.frame(windowID: id) == original)
    }

    @Test func closingAParkedWindowDoesNotReopenItOnPause() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        #expect(registry.park(windowID: id))
        settings.close()
        registry.restoreAll()
        #expect(registry.records.isEmpty)
        #expect(!settings.isVisible)
    }

    @Test func setFrameUnparksWithoutRequestingKeyboardFocus() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        #expect(registry.park(windowID: id))
        #expect(registry.setFrame(windowID: id, frame: CGRect(x: 10_100, y: 10_100, width: 900, height: 700)))
        #expect(settings.isVisible)
        #expect(!settings.isKeyWindow)
    }
}
