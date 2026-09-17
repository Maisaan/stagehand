import AppKit
import SwiftUI
import StagehandCore

enum StatusItemClick: Equatable {
    case openWindow
    case showMenu
}

func statusItemClick(for eventType: NSEvent.EventType?) -> StatusItemClick {
    eventType == .rightMouseUp ? .showMenu : .openWindow
}

struct StatusMenuState {
    let isRunning: Bool
    let isSuspended: Bool
    let activeSpaceIndex: Int
    let spaces: [(index: Int, windowCount: Int)]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindow: NSWindow?
    private var model: StagehandModel?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
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
        let model = StagehandModel()
        self.model = model
        if arguments.contains("--diagnose-permissions") {
            print("Accessibility: \(model.accessibilityGranted)")
            NSApp.terminate(nil)
            return
        }
        if let index = arguments.firstIndex(of: "--diagnose-discovery"), arguments.indices.contains(index + 1) {
            Task { @MainActor in
                print(await model.diagnoseDiscovery(probeURL: URL(fileURLWithPath: arguments[index + 1]),
                                                    settlingWindow: arguments.contains("--settling-window")))
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
            Task { @MainActor [weak self] in self?.model?.refreshPermissions() }
        }
        openSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc func openSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = SettingsWindow.make(model: model)
            window.delegate = self
            settingsWindow = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        if let settingsWindow { model.registerSettingsWindow(settingsWindow) }
    }

    @objc func closeSettingsWindow() {
        settingsWindow?.performClose(nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        switch statusItemClick(for: NSApp.currentEvent?.type) {
        case .openWindow:
            openSettings()
        case .showMenu:
            guard let menu = statusMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
        }
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
        let close = appMenu.addItem(
            withTitle: "Close Stagehand Window",
            action: #selector(closeSettingsWindow),
            keyEquivalent: "q"
        )
        close.target = self
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
        let window = SettingsWindow.make(model: model)
        window.title = "Stagehand Preview"
        settingsWindow = window
        window.center()
        window.orderFrontRegardless()
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let sizes = [
                    (suffix: "", size: NSSize(width: 680, height: 610)),
                    (suffix: "-compact", size: NSSize(width: 680, height: 610)),
                    (suffix: "-expanded", size: NSSize(width: 900, height: 760))
                ]
                for section in ["Windows", "Shortcuts", "System"] {
                    for variant in sizes {
                        let view = NSHostingView(rootView: SettingsView(model: model, initialTab: section))
                        window.contentView = view
                        window.setContentSize(variant.size)
                        view.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(250))
                        let destination = output.appendingPathComponent("\(section.lowercased())\(variant.suffix).png")
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
                }
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

        let open = NSMenuItem(title: "Open Stagehand", action: #selector(openSettings), keyEquivalent: "")
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
            ? "Stagehand: waiting for its Desktop"
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
