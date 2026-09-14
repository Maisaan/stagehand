import AppKit
import StagehandPlatform

@MainActor
enum FocusDiagnostics {
    /// Explicit diagnostic commands only; never types into a window.
    static func run(bundleIdentifier: String, parkBeforeFocus: Bool = false) async {
        let system = WindowSystem()
        system.focusDiagnosticsEnabled = true
        guard system.isAccessibilityTrusted else {
            print("Accessibility permission is missing for this build. No focus attempt was made.")
            return
        }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let windows = system.scanWindows()
        let previousWindowID = system.focusedWindowID()
        defer { if parkBeforeFocus { system.restoreAll() } }
        guard let target = windows.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            print("No eligible on-screen window for \(bundleIdentifier). No focus attempt was made.")
            return
        }
        for iteration in 1...(parkBeforeFocus ? 3 : 1) {
            if parkBeforeFocus {
                let parked = system.park(windowID: target.id)
                print("Park iteration \(iteration): \(parked)")
                guard parked else { break }
            }
            let success = await system.focus(windowID: target.id)
            print("Focus result: \(success)")
            if let report = system.lastFocusReport { print(report.summary) }
            if !success { break }
        }
        if parkBeforeFocus { system.restoreAll() }
        if let previousWindowID, previousWindowID != target.id {
            _ = await system.focus(windowID: previousWindowID)
        } else if previousApp?.processIdentifier != target.pid {
            _ = previousApp?.activate(options: [])
        }
    }
}
