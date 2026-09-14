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

    @Test func frameChangesArriveDuringEachResizeWithoutWaitingForATimer() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        var changes: [(String, CGRect)] = []
        registry.onFrameChange = { changes.append(($0, $1)) }

        for width in [710.0, 730.0, 750.0] {
            let previousCount = changes.count
            var frame = settings.frame
            frame.size.width = width
            settings.setFrame(frame, display: false, animate: false)
            // No await or run-loop spin: the latest outline frame must already
            // be available before AppKit returns from this resize operation.
            #expect(changes.count > previousCount)
            #expect(changes.last?.0 == id)
            #expect(changes.last?.1 == registry.frame(windowID: id))
        }
    }

    @Test func frameChangesIgnoreUnregisteredWindows() {
        let registry = NativeWindowRegistry()
        let overlay = makeWindow()
        defer { overlay.close() }
        var changeCount = 0
        registry.onFrameChange = { _, _ in changeCount += 1 }
        var frame = overlay.frame
        frame.size.width += 50
        overlay.setFrame(frame, display: false, animate: false)
        #expect(changeCount == 0)
    }
}
