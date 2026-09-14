import AppKit
import SwiftUI
import StagehandCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var model: StagehandModel?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = StagehandModel()
        self.model = model
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--render-previews"), arguments.indices.contains(index + 1) {
            renderPreviews(directory: arguments[index + 1], model: model)
            return
        }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.onStateChange = { [weak self] in self?.updateMenu() }
        installApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.leadinghalf.inset.filled", accessibilityDescription: "Stagehand")
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

    @objc private func openSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Stagehand"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleRunning() {
        guard let model else { return }
        model.isRunning ? model.pause() : model.start()
    }

    @objc private func changeSpace(_ sender: NSMenuItem) {
        model?.navigate(.goToSpace(index: sender.tag))
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Stagehand")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "Quit Stagehand", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let editMenu = NSMenu(title: "Edit")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }

    /// Render the real native settings views without starting window management or input monitoring.
    private func renderPreviews(directory: String, model: StagehandModel) {
        let originalApp = NSWorkspace.shared.frontmostApplication
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Stagehand Preview"
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.center()
        window.orderFrontRegardless()
        Task { @MainActor in
            do {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for section in ["Workspace", "Controls", "Setup"] {
                    let view = NSHostingView(rootView: SettingsView(model: model, initialTab: section))
                    window.contentView = view
                    window.setContentSize(NSSize(width: 680, height: 610))
                    view.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(250))
                    let destination = output.appendingPathComponent("\(section.lowercased()).png")
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
                print("Preview rendering passed. Window management was not started.")
            } catch {
                print("Preview rendering failed: \(error)")
            }
            window.orderOut(nil)
            _ = originalApp?.activate(options: [])
            NSApp.terminate(nil)
        }
    }

    private func updateMenu() {
        guard let model else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: model.isRunning ? "Space \(model.state.activeSpaceIndex + 1) · \(model.state.layoutMode.rawValue.capitalized)" : "Stagehand is paused", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        if model.isRunning {
            for index in model.state.spaces.indices {
                let count = model.state.spaces[index].windowIDs.count
                let item = NSMenuItem(title: "Space \(index + 1)  ·  \(count) \(count == 1 ? "window" : "windows")",
                                      action: #selector(changeSpace(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == model.state.activeSpaceIndex ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let toggle = NSMenuItem(title: model.isRunning ? "Pause & Restore Windows" : "Start Stagehand", action: #selector(toggleRunning), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stagehand", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }
}
