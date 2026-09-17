import AppKit

/// A managed window can extend beyond the display as part of the scrolling ribbon.
/// AppKit's default titled-window constraints would move it back onto the screen.
@MainActor
public final class RibbonWindow: NSWindow {
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Only explicitly registered windows participate. Stagehand's overlays never enter this registry.
@MainActor
final class NativeWindowRegistry: NSObject {
    var onChange: (() -> Void)?
    var onFrameChange: ((String, CGRect) -> Void)?
    var onFocusedWindowChange: ((String) -> Void)?

    private final class Registration {
        weak var window: NSWindow?
        let id: String
        var originalFrame: CGRect?
        var parked = false
        var closed = false

        init(window: NSWindow, id: String) {
            self.window = window
            self.id = id
        }
    }

    private var windows: [String: Registration] = [:]
    private var nextID = 0

    override init() {
        super.init()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @discardableResult
    func register(window: NSWindow) -> String {
        if let existing = windows.values.first(where: { $0.window === window }) {
            existing.closed = false
            return existing.id
        }
        nextID += 1
        let id = "native:\(nextID)"
        windows[id] = Registration(window: window, id: id)
        return id
    }

    func contains(windowID: String) -> Bool { windows[windowID]?.window != nil }

    var trackedWindowIDs: Set<String> {
        Set(windows.values.filter { !$0.closed && $0.window != nil }.map(\.id))
    }

    var records: [WindowRecord] {
        windows.values.compactMap { entry in
            guard let window = entry.window, !entry.closed, !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen), window.isVisible || entry.parked else { return nil }
            return WindowRecord(id: entry.id, appName: "Stagehand", title: window.title,
                                bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.stagehand.Stagehand",
                                pid: ProcessInfo.processInfo.processIdentifier,
                                frame: accessibilityFrame(window.frame),
                                isResizable: window.styleMask.contains(.resizable))
        }.sorted { $0.id < $1.id }
    }

    var focusedWindowID: String? {
        guard NSApp?.isActive == true else { return nil }
        return windows.values.first { !$0.closed && $0.window?.isKeyWindow == true }?.id
    }

    func frame(windowID: String) -> CGRect? {
        guard let entry = windows[windowID], !entry.closed, let window = entry.window else { return nil }
        return accessibilityFrame(window.frame)
    }

    func windowNumber(for windowID: String) -> CGWindowID? {
        guard let entry = windows[windowID], !entry.closed, let number = entry.window?.windowNumber,
              let identifier = CGWindowID(exactly: number), identifier != kCGNullWindowID else { return nil }
        return identifier
    }

    func isParked(windowID: String) -> Bool {
        windows[windowID]?.parked == true
    }

    func captureOriginalFrame(windowID: String) {
        guard let entry = windows[windowID], !entry.closed, entry.originalFrame == nil else { return }
        entry.originalFrame = entry.window?.frame
    }

    @discardableResult
    func setFrame(windowID: String, frame: CGRect) -> Bool {
        guard let entry = windows[windowID], !entry.closed, let window = entry.window,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0, !window.styleMask.contains(.fullScreen) else { return false }
        captureOriginalFrame(windowID: windowID)
        // Converting between AppKit and AX coordinates is the same vertical reflection in both directions.
        // Update parked windows while hidden so they never reveal the previous ribbon frame.
        window.setFrame(accessibilityFrame(frame), display: true, animate: false)
        guard restore(windowID: windowID) else { return false }
        let actual = accessibilityFrame(window.frame)
        return abs(actual.minX - frame.minX) <= 1 && abs(actual.minY - frame.minY) <= 1 &&
            abs(actual.width - frame.width) <= 1 && abs(actual.height - frame.height) <= 1
    }

    @discardableResult
    func setPosition(windowID: String, position: CGPoint) -> Bool {
        guard position.x.isFinite, position.y.isFinite,
              let entry = windows[windowID], !entry.closed, !entry.parked,
              let window = entry.window, !window.styleMask.contains(.fullScreen) else { return false }
        captureOriginalFrame(windowID: windowID)
        var frame = accessibilityFrame(window.frame)
        frame.origin = position
        window.setFrameOrigin(accessibilityFrame(frame).origin)
        let actual = accessibilityFrame(window.frame).origin
        return abs(actual.x - position.x) <= 1 && abs(actual.y - position.y) <= 1
    }

    @discardableResult
    func park(windowID: String) -> Bool {
        guard let entry = windows[windowID], !entry.closed, let window = entry.window else { return false }
        if entry.parked { return true }
        captureOriginalFrame(windowID: windowID)
        entry.parked = true
        window.orderOut(nil)
        return !window.isVisible
    }

    @discardableResult
    func restore(windowID: String) -> Bool {
        guard let entry = windows[windowID], !entry.closed, let window = entry.window else { return false }
        if entry.parked {
            entry.parked = false
            window.orderFront(nil)
            return window.isVisible
        }
        return true
    }

    func restoreAll() {
        for entry in windows.values {
            guard !entry.closed, let window = entry.window, !window.styleMask.contains(.fullScreen) else { continue }
            if let original = entry.originalFrame {
                window.setFrame(original, display: true, animate: false)
                entry.originalFrame = nil
            }
            _ = restore(windowID: entry.id)
        }
    }

    func focus(windowID: String) async -> Bool {
        guard let entry = windows[windowID], !entry.closed, let window = entry.window,
              restore(windowID: windowID) else { return false }
        // Cooperative activate() can be refused while another app owns focus.
        // Use AppKit's AXFrontmost handler directly, without AX messaging to our own process.
        NSApp.setAccessibilityFrontmost(true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        repeat {
            guard !Task.isCancelled else { return false }
            if NSApp.isActive && window.isKeyWindow { return true }
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }

    func focusObservation(windowID: String) -> WindowFocusReport.NativeObservation {
        WindowFocusReport.NativeObservation(applicationActive: NSApp?.isActive == true,
                                             windowKey: windows[windowID]?.window?.isKeyWindow == true,
                                             frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func accessibilityFrame(_ frame: CGRect) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.values.first(where: { $0.window === window }) else { return }
        if notification.name == NSWindow.willCloseNotification {
            entry.closed = true
            entry.parked = false
            entry.originalFrame = nil
        } else if notification.name == NSWindow.didMoveNotification || notification.name == NSWindow.didResizeNotification {
            onFrameChange?(entry.id, accessibilityFrame(window.frame))
        } else if notification.name == NSWindow.didBecomeKeyNotification,
                  focusedWindowID == entry.id {
            onFocusedWindowChange?(entry.id)
        }
        onChange?()
    }
}
