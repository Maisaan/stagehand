import AppKit
import StagehandPlatform

@MainActor
enum FocusDiagnostics {
    /// Explicit diagnostic command only; does not resize, park, or type into any window.
    static func run(bundleIdentifier: String) async {
        let system = WindowSystem()
        system.focusDiagnosticsEnabled = true
        guard system.isAccessibilityTrusted else {
            print("Accessibility permission is missing for this build. No focus attempt was made.")
            return
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let windows = system.scanWindows()
        let previousWindowID = system.focusedWindowID()
        guard let target = windows.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            print("No eligible on-screen window for \(bundleIdentifier). No focus attempt was made.")
            return
        }
        let success = await system.focus(windowID: target.id)
        print("Focus result: \(success)")
        if let report = system.lastFocusReport { print(report.summary) }
        if let previousWindowID, previousWindowID != target.id {
            _ = await system.focus(windowID: previousWindowID)
        } else if previousApp?.processIdentifier != target.pid {
            _ = previousApp?.activate(options: [])
        }
    }
}
