import AppKit

// A disposable external app for --acceptance. It opens text windows and mirrors
// each window's text to a report file so the runner can check where typing landed.
// Arguments: --windows <count> --report <directory> --label <name>
// --busy loads the main thread like a heavy app (Chrome, Electron): 6 ms of work
// every 16 ms, and 150 ms on each activation, so Accessibility replies wait.
@MainActor
final class AcceptanceProbeDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    private var windows: [NSWindow] = []
    private var reports: [ObjectIdentifier: URL] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let count = value("--windows").flatMap(Int.init) ?? 1
        let report = URL(fileURLWithPath: value("--report") ?? NSTemporaryDirectory())
        let label = value("--label") ?? "probe"
        for index in 0..<count {
            let window = NSWindow(contentRect: NSRect(x: 160 + index * 60, y: 200 + index * 40, width: 640, height: 420),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "\(label)-\(index)"
            window.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            let text = scroll.documentView as! NSTextView
            text.delegate = self
            text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            window.contentView = scroll
            window.initialFirstResponder = text
            reports[ObjectIdentifier(text)] = report.appendingPathComponent("\(window.title).txt")
            try? Data().write(to: report.appendingPathComponent("\(window.title).txt"))
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(text)
            windows.append(window)
        }
        NSApp.activate()
        if arguments.contains("--busy") {
            let frameWork = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in Self.spin(milliseconds: 6) }
            RunLoop.main.add(frameWork, forMode: .common)
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in Self.spin(milliseconds: 150) }
        }
        // Never outlive an interrupted runner.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            NSApp.terminate(nil)
        }
    }

    nonisolated static func spin(milliseconds: Double) {
        let end = CFAbsoluteTimeGetCurrent() + milliseconds / 1_000
        while CFAbsoluteTimeGetCurrent() < end {}
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView,
              let url = reports[ObjectIdentifier(text)] else { return }
        try? Data(text.string.utf8).write(to: url, options: .atomic)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AcceptanceProbeDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
