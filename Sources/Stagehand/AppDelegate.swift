import AppKit
import SwiftUI
import StagehandCore
import StagehandPlatform

enum StatusItemClick: Equatable {
    case showControls
    case showMenu
}

func statusItemClick(for eventType: NSEvent.EventType?) -> StatusItemClick {
    eventType == .rightMouseUp ? .showMenu : .showControls
}

struct StatusMenuState {
    let isRunning: Bool
    let isSuspended: Bool
    let activeSpaceIndex: Int
    let spaces: [(index: Int, windowCount: Int)]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let onboardingCompleteKey = "onboardingComplete"
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var quickControlsPanel: QuickControlsPanel?
    private var quickControlsCloseCompletion: (() -> Void)?
    private var quickControlsOutsideClickMonitor: Any?
    private var quickControlsLocalClickMonitor: Any?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var model: StagehandModel?
    private var activationObserver: NSObjectProtocol?
    /// Held for the process lifetime so a second Stagehand cannot manage the same windows.
    private var instanceLock: InstanceLock?

    override init() {
        super.init()
    }

    init(model: StagehandModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let started = ProcessLaunchDate.launchDate(pid: getpid()) {
            launchFinishedMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        }
        let arguments = ProcessInfo.processInfo.arguments
        // Diagnostics start and pause against disposable windows. They must not
        // save that layout over the user's, nor flip the logging preference.
        let isDiagnosticRun = arguments.contains {
            $0.hasPrefix("--diagnose-") || $0 == "--acceptance" || $0 == "--benchmark" || $0 == "--render-previews"
        }
        if let refusal = claimSingleInstance() {
            refuseToLaunch(refusal, arguments: arguments, diagnostic: isDiagnosticRun)
            return
        }
        // Diagnostics need the same completed AppKit launch as normal operation.
        // A main-actor Task created before NSApplication.run can execute earlier.
        if let index = arguments.firstIndex(of: "--diagnose-focus") ?? arguments.firstIndex(of: "--diagnose-parking"),
           arguments.indices.contains(index + 1) {
            Task { @MainActor in
                await FocusDiagnostics.run(bundleIdentifier: arguments[index + 1],
                                           parkBeforeFocus: arguments[index] == "--diagnose-parking")
                NSApp.terminate(nil)
            }
            return
        }
        let modelBegan = Date()
        let model = StagehandModel(persistence: isDiagnosticRun ? .ephemeral : .standard)
        modelInitMilliseconds = Int(Date().timeIntervalSince(modelBegan) * 1_000)
        self.model = model
        if arguments.contains("--diagnose-permissions") {
            print("Accessibility: \(model.accessibilityGranted)")
            NSApp.terminate(nil)
            return
        }
        if let index = arguments.firstIndex(of: "--diagnose-discovery"), arguments.indices.contains(index + 1) {
            Task { @MainActor in
                print(await model.diagnoseDiscovery(probeURL: URL(fileURLWithPath: arguments[index + 1]),
                                                    settlingWindow: arguments.contains("--settling-window"),
                                                    standaloneDialog: arguments.contains("--standalone-dialog")))
                NSApp.terminate(nil)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--acceptance"), arguments.indices.contains(index + 1) {
            Task { @MainActor in
                let report = await model.diagnoseAcceptance(probeURL: URL(fileURLWithPath: arguments[index + 1]))
                print(report)
                // Launched through LaunchServices so macOS checks Stagehand's own
                // Accessibility grant; stdout is not attached then.
                if let output = self.acceptanceOutputPath(in: arguments) {
                    do {
                        try Data((report + "\n").utf8).write(to: URL(fileURLWithPath: output))
                    } catch {
                        // The runner reads only this file; a silent failure would
                        // look like a hung or passing run.
                        FileHandle.standardError.write(Data(
                            "Stagehand could not write the acceptance report to \(output): \(error.localizedDescription)\n".utf8
                        ))
                        model.shutDown()
                        exit(1)
                    }
                }
                NSApp.terminate(nil)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--benchmark"), arguments.indices.contains(index + 1) {
            Task { @MainActor in
                let report = await model.runBenchmark(probeURL: URL(fileURLWithPath: arguments[index + 1]),
                                                      busy: arguments.contains("--busy"))
                print(report)
                if let output = self.acceptanceOutputPath(in: arguments) {
                    try? Data((report + "\n").utf8).write(to: URL(fileURLWithPath: output))
                }
                NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--diagnose-last-close") {
            Task { @MainActor in
                print(await model.diagnoseLastClose())
                NSApp.terminate(nil)
            }
            return
        }
        if arguments.contains("--diagnose-start") || arguments.contains("--diagnose-ribbon") {
            Task { @MainActor in
                print(await model.diagnoseStartup(includeSettings: arguments.contains("--diagnose-ribbon")))
                NSApp.terminate(nil)
            }
            return
        }
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            renderPreviews(directory: arguments[index + 1], model: model)
            return
        }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.onStateChange = { [weak self] in self?.updateMenu() }
        NSApp.mainMenu = makeApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let url = Bundle.main.url(forResource: "StagehandMenuBar", withExtension: "svg"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 10)
                image.isTemplate = true
                image.accessibilityDescription = "Stagehand"
                button.image = image
            } else if let symbol = NSImage(systemSymbolName: "rectangle.3.group",
                                           accessibilityDescription: "Stagehand") {
                // A binary run outside the bundle (.build) has no resource; a
                // blank status item would hide the only way to pause or quit.
                button.image = symbol
            } else {
                button.title = "SH"
            }
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Stagehand"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateMenu()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model?.refreshPermissions()
                self?.model?.refreshLaunchAtLogin()
            }
        }
        let interrupted = model.recoverInterruptedSession()
        if !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) {
            openOnboarding()
        } else if model.accessibilityGranted && !interrupted {
            model.start()
        }
    }

    /// Nil when this process may manage windows; otherwise the reason it may not.
    /// Two controllers would park and restore each other's windows. The running
    /// application check covers installed copies; the file lock also covers a
    /// binary run from .build, and the kernel drops it if the holder crashes.
    private func claimSingleInstance() -> String? {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let bundleID = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
               .first(where: { $0.processIdentifier != pid && !$0.isTerminated }) {
            return "Another Stagehand (process \(other.processIdentifier)) is already running. Quit it first."
        }
        do {
            instanceLock = try InstanceLock()
            return nil
        } catch InstanceLock.Failure.held {
            let holder = (try? String(contentsOf: InstanceLock.defaultURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            return "Another Stagehand process (\(holder)) holds \(InstanceLock.defaultURL.path). Quit it first."
        } catch {
            // An unwritable Application Support folder should not block the app.
            NSLog("Stagehand could not take its instance lock: %@", error.localizedDescription)
            return nil
        }
    }

    private func refuseToLaunch(_ reason: String, arguments: [String], diagnostic: Bool) {
        NSLog("%@", reason)
        if diagnostic {
            let message = "FAIL: \(reason) No windows were changed."
            print(message)
            if let output = acceptanceOutputPath(in: arguments) {
                try? Data((message + "\n").utf8).write(to: URL(fileURLWithPath: output))
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Stagehand is already running"
            alert.informativeText = reason
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    private func acceptanceOutputPath(in arguments: [String]) -> String? {
        arguments.firstIndex(of: "--acceptance-output").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        removeQuickControlsOutsideClickMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc func openSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = SettingsWindow.make(model: model) { [weak self] in
                self?.openOnboarding()
            }
            window.delegate = self
            settingsWindow = window
        }
        model.refreshPermissions()
        model.refreshLaunchAtLogin()
        NSApp.setActivationPolicy(.regular)
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let didActivate = NSRunningApplication.current.activate(
                from: frontmostApplication,
                options: []
            )
            if !didActivate { NSApp.activate() }
        } else {
            NSApp.activate()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let settingsWindow { model.registerSettingsWindow(settingsWindow) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func openOnboarding() {
        guard let model else { return }
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow.make(model: model) { [weak self] in
                self?.completeOnboarding()
            }
        }
        model.refreshPermissions()
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        switch statusItemClick(for: NSApp.currentEvent?.type) {
        case .showControls:
            toggleQuickControls(relativeTo: sender)
        case .showMenu:
            closeQuickControls()
            guard let menu = statusMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        }
    }

    private func toggleQuickControls(relativeTo button: NSStatusBarButton) {
        if quickControlsPanel?.isVisible == true {
            quickControlsPanel?.dismiss()
            return
        }
        guard let model else { return }
        let panel = quickControlsPanel ?? {
            let hostingView = FirstMouseHostingView(rootView: QuickControlsView(
                model: model,
                openSettings: { [weak self] in
                    self?.closeQuickControls { [weak self] in self?.openSettings() }
                },
                quit: { [weak self] in self?.quit() },
                requestAccessibility: { [weak self] in
                    self?.closeQuickControls { [weak self] in self?.model?.requestAccessibility() }
                }
            ))
            let panel = QuickControlsPanel(contentView: hostingView)
            panel.onDismiss = { [weak self] in self?.quickControlsDidDismiss() }
            quickControlsPanel = panel
            return panel
        }()
        model.refreshPermissions()
        panel.present(relativeTo: button)
        installQuickControlsOutsideClickMonitor()
    }

    private func closeQuickControls(completion: (() -> Void)? = nil) {
        guard let panel = quickControlsPanel, panel.isVisible else {
            completion?()
            return
        }
        quickControlsCloseCompletion = completion
        panel.dismiss()
    }

    private func quickControlsDidDismiss() {
        removeQuickControlsOutsideClickMonitor()
        let completion = quickControlsCloseCompletion
        quickControlsCloseCompletion = nil
        completion?()
    }

    private func installQuickControlsOutsideClickMonitor() {
        if quickControlsOutsideClickMonitor == nil {
            quickControlsOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.closeQuickControls() }
            }
        }
        if quickControlsLocalClickMonitor == nil {
            quickControlsLocalClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self,
                      event.window !== self.quickControlsPanel,
                      event.window !== self.statusItem?.button?.window,
                      !(event.window is NSColorPanel) else { return event }
                self.closeQuickControls()
                return event
            }
        }
    }

    private func removeQuickControlsOutsideClickMonitor() {
        if let quickControlsOutsideClickMonitor {
            NSEvent.removeMonitor(quickControlsOutsideClickMonitor)
        }
        if let quickControlsLocalClickMonitor {
            NSEvent.removeMonitor(quickControlsLocalClickMonitor)
        }
        self.quickControlsOutsideClickMonitor = nil
        self.quickControlsLocalClickMonitor = nil
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
        if model?.accessibilityGranted == true, model?.recoverInterruptedSession() == false { model?.start() }
    }

    @objc func toggleRunning() {
        guard let model else { return }
        model.isRunning ? model.pause() : model.start()
    }

    @objc func changeSpace(_ sender: NSMenuItem) {
        model?.navigate(.goToSpace(index: sender.tag))
    }

    @objc func quit() { NSApp.terminate(nil) }

    func makeApplicationMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Stagehand")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = appMenu.addItem(
            withTitle: "Quit Stagehand",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        let editMenu = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        return main
    }

    /// Render the real native settings views without starting window management or input monitoring.
    private func renderPreviews(directory: String, model: StagehandModel) {
        let originalApp = NSWorkspace.shared.frontmostApplication
        // Keep the preview window conventional. Full-size transparent title bars rely on
        // WindowServer compositing, which `cacheDisplay` cannot capture reliably.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stagehand Preview"
        settingsWindow = window
        window.center()
        window.orderFrontRegardless()
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

                @MainActor func capture(_ view: NSView, filename: String) throws {
                    let destination = output.appendingPathComponent(filename)
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: destination)
                    print("Rendered \(destination.path)")
                }

                @MainActor func render<Content: View>(
                    _ rootView: Content,
                    size: NSSize,
                    filename: String
                ) async throws {
                    let view = NSHostingView(rootView: rootView)
                    window.contentView = view
                    window.setContentSize(size)
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    try capture(view, filename: filename)
                }

                let sizes = [
                    (suffix: "", size: NSSize(width: 700, height: 620)),
                    (suffix: "-expanded", size: NSSize(width: 900, height: 760))
                ]
                for section in SettingsPage.allCases {
                    for variant in sizes {
                        try await render(
                            SettingsView(model: model, initialTab: section),
                            size: variant.size,
                            filename: "\(section.rawValue.lowercased())\(variant.suffix).png"
                        )
                    }
                }

                try await render(
                    OnboardingView(model: model, onComplete: {}),
                    size: NSSize(width: 520, height: 600),
                    filename: "onboarding.png"
                )
                try await render(
                    OnboardingView(model: model, onComplete: {}, initialStep: .overview),
                    size: NSSize(width: 520, height: 600),
                    filename: "onboarding-overview.png"
                )
                try await render(
                    SettingsView(model: model, initialTab: .about, expandAboutDetails: true),
                    size: NSSize(width: 700, height: 620),
                    filename: "about-details-expanded.png"
                )
                try await render(
                    QuickControlsView(
                        model: model,
                        openSettings: {},
                        quit: {},
                        requestAccessibility: {}
                    ),
                    size: NSSize(width: 340, height: 400),
                    filename: "quick-controls.png"
                )

                let onboardingWindow = OnboardingWindow.make(model: model, onComplete: {})
                onboardingWindow.orderFrontRegardless()
                onboardingWindow.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                if let frameView = onboardingWindow.contentView?.superview {
                    try capture(frameView, filename: "onboarding-window.png")
                }
                onboardingWindow.orderOut(nil)
                print("Preview rendering passed. Window management was not started.")
            } catch {
                print("Preview rendering failed: \(error)")
            }
            window.orderOut(nil)
            _ = originalApp?.activate(options: [])
            NSApp.terminate(nil)
        }
    }

    func makeStatusMenu(state: StatusMenuState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let toggle = NSMenuItem(
            title: state.isRunning ? "Pause Stagehand" : "Start Stagehand",
            action: #selector(toggleRunning),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if state.isRunning {
            menu.addItem(.separator())
            let spaces = NSMenu(title: "Spaces")
            for space in state.spaces {
                let noun = space.windowCount == 1 ? "window" : "windows"
                let item = NSMenuItem(
                    title: "Space \(space.index + 1) (\(space.windowCount) \(noun))",
                    action: #selector(changeSpace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = space.index
                item.state = space.index == state.activeSpaceIndex ? .on : .off
                item.isEnabled = !state.isSuspended
                spaces.addItem(item)
            }
            let spacesItem = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
            spacesItem.submenu = spaces
            menu.addItem(spacesItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stagehand", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func updateMenu() {
        guard let model else { return }
        statusItem?.button?.toolTip = model.isSuspended
            ? "Stagehand: waiting for managed desktop"
            : model.isRunning ? "Stagehand: running" : "Stagehand: paused"
        statusMenu = makeStatusMenu(state: StatusMenuState(
            isRunning: model.isRunning,
            isSuspended: model.isSuspended,
            activeSpaceIndex: model.state.activeSpaceIndex,
            spaces: model.state.displayedSpaceIndices.map {
                (index: $0, windowCount: model.state.spaces[$0].windowIDs.count)
            }
        ))
    }
}
