import AppKit
import Testing
@testable import StagehandPlatform

@Suite(.serialized) @MainActor
struct NativeWindowTests {
    private final class RevealRecordingWindow: NSWindow {
        var framesWhenRevealed: [CGRect] = []

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }

        override func orderFront(_ sender: Any?) {
            framesWhenRevealed.append(frame)
            super.orderFront(sender)
        }
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = RibbonWindow(contentRect: CGRect(x: 10_000, y: 10_000, width: 680, height: 610),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Stagehand test window"
        return window
    }

    @Test func registeredNativeWindowsExposeTheirExactWindowNumber() {
        let system = WindowSystem()
        let window = makeWindow()
        defer { window.close() }
        let id = system.registerOwnWindow(window: window)

        #expect(system.windowNumber(for: id) == CGWindowID(window.windowNumber))
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

    @Test func undiscoveredWindowsRemainTrackedUntilClosed() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        let id = registry.register(window: settings)
        #expect(registry.records.isEmpty)
        #expect(registry.trackedWindowIDs == [id])

        settings.close()
        #expect(registry.records.isEmpty)
        #expect(registry.trackedWindowIDs.isEmpty)
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

    @Test func parkedWindowReceivesItsDestinationFrameBeforeBeingRevealed() {
        _ = NSApplication.shared
        let registry = NativeWindowRegistry()
        let settings = RevealRecordingWindow(
            contentRect: CGRect(x: 10_000, y: 10_000, width: 680, height: 610),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        #expect(registry.park(windowID: id))
        settings.framesWhenRevealed.removeAll()

        let destination = CGRect(x: 10_100, y: 10_100, width: 900, height: 700)
        #expect(registry.setFrame(windowID: id, frame: destination))
        #expect(settings.framesWhenRevealed == [settings.frame])
        #expect(registry.frame(windowID: id) == destination)
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

    @Test func positionChangesPreserveSizeAndDoNotRequestFocus() throws {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        let original = try #require(registry.frame(windowID: id))
        let destination = CGPoint(x: original.minX + 80, y: original.minY + 30)

        #expect(registry.setPosition(windowID: id, position: destination))
        #expect(registry.frame(windowID: id) == CGRect(origin: destination, size: original.size))
        #expect(!settings.isKeyWindow)
        registry.restoreAll()
        #expect(registry.frame(windowID: id) == original)
    }

    @Test func positionChangesDoNotRevealParkedWindows() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        settings.orderFront(nil)
        let id = registry.register(window: settings)
        let original = registry.frame(windowID: id)
        #expect(registry.park(windowID: id))

        #expect(!registry.setPosition(windowID: id, position: CGPoint(x: 20, y: 20)))
        #expect(!settings.isVisible)
        #expect(registry.frame(windowID: id) == original)
    }

    @Test func staleKeyNotificationsDoNotAdoptAnUnfocusedWindow() {
        let registry = NativeWindowRegistry()
        let settings = makeWindow()
        defer { settings.close() }
        _ = registry.register(window: settings)
        var focusedIDs: [String] = []
        registry.onFocusedWindowChange = { focusedIDs.append($0) }

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        #expect(!settings.isKeyWindow)
        #expect(focusedIDs.isEmpty)
    }
}
