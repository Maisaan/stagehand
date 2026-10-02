import AppKit

// A disposable external app for --diagnose-discovery. Its window appears after the
// workspace launch/activation notifications, and it exits even if the harness stops.
@MainActor
final class DiscoveryProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if ProcessInfo.processInfo.arguments.contains("--standalone-dialog") {
                // An app-modal alert with no other window, like Xcode's component installer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Stagehand discovery probe"
                alert.informativeText = "A standalone dialog with no owning window."
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 620, height: 420),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Stagehand discovery probe"
            window.isReleasedWhenClosed = false
            self.window = window
            let settling = ProcessInfo.processInfo.arguments.contains("--settling-window")
            if settling {
                // AXWindowCreated precedes an app's final window geometry. The window
                // remains ineligible through the first scan, then sends only a resize.
                window.setFrame(NSRect(x: 180, y: 220, width: 1, height: 1), display: false)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if settling {
                try? await Task.sleep(for: .milliseconds(350))
                window.setFrame(NSRect(x: 180, y: 220, width: 620, height: 420), display: true)
            }
            try? await Task.sleep(for: .seconds(10))
            NSApp.terminate(nil)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = DiscoveryProbeDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
