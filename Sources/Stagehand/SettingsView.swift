import AppKit
import Carbon
import SwiftUI
import StagehandCore
import StagehandPlatform

struct SettingsView: View {
    @ObservedObject var model: StagehandModel
    @State private var tab = "Workspace"
    @State private var gapInput: Double
    @State private var selectedSpaceIndex: Int
    @State private var shortcutError: String?

    init(model: StagehandModel, initialTab: String = "Workspace") {
        self.model = model
        _tab = State(initialValue: initialTab)
        _gapInput = State(initialValue: GapInput.clamped(model.gap))
        _selectedSpaceIndex = State(initialValue: model.state.activeSpaceIndex)
        _shortcutError = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $tab) {
                Text("Workspace").tag("Workspace")
                Text("Controls").tag("Controls")
                Text("Setup").tag("Setup")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 330)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
            Form {
                if let warning = model.warning {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(warning).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.dismissWarning() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss warning")
                        }
                    }
                }
                switch tab {
                case "Controls": controls
                case "Setup": setup
                default: workspace
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 12) {
                Circle().fill(model.isSuspended ? Color.orange : model.isRunning ? .green : .secondary)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isSuspended ? "Waiting for its Desktop" : model.isRunning ? "Running" : "Paused")
                        .font(.callout.weight(.medium))
                    Text(model.isSuspended ? "Return to the Desktop where you started Stagehand to resume." : model.isRunning ? "Pausing restores your original window positions." : "Stagehand isn't moving your windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isRunning ? "Pause Stagehand" : "Start Stagehand") {
                    if model.isRunning { model.pause() }
                    else if model.accessibilityGranted { model.start() }
                    else { tab = "Setup"; model.requestAccessibility() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Shortcut unavailable", isPresented: Binding(
            get: { shortcutError != nil },
            set: { if !$0 { shortcutError = nil } }
        )) {
            Button("OK") { shortcutError = nil }
        } message: {
            Text(shortcutError ?? "")
        }
    }

    private var workspace: some View {
        Group {
            Section {
                Toggle("Maximize windows", isOn: Binding(
                    get: { model.state.maximizeWindows }, set: { model.setMaximizeWindows($0) }
                ))
                .toggleStyle(.switch)
            } footer: {
                Text("Each window uses all available width and height. Turn this off to restore its saved size. Some apps set their own size limits.")
            }
            if !model.state.maximizeWindows {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Window gap")
                            Spacer()
                            GapInput(value: $gapInput) { model.gap = $0 }
                                .frame(width: 76, height: 24)
                            Text("pt").foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { gapInput }, set: { gapInput = $0.rounded() }), in: GapInput.bounds) { editing in
                            if !editing, gapInput != model.gap { model.gap = gapInput }
                        }
                        .accessibilityLabel("Gap between windows")
                        HStack {
                            Text("−200 pt overlap")
                            Spacer()
                            Text("40 pt gap")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Negative values overlap windows. The active window stays on top. Use ↑/↓ to adjust by 1 pt or Shift-↑/↓ by 10 pt. Press Return or click elsewhere to apply.")
                }
            }
            Section {
                ColorPicker(
                    "Active border color",
                    selection: Binding(
                        get: { Color(nsColor: model.focusBorderColor) },
                        set: { model.setFocusBorderColor(NSColor($0)) }
                    ),
                    supportsOpacity: false
                )
                ColorPicker(
                    "App bar color",
                    selection: Binding(
                        get: { Color(nsColor: model.appBarColor) },
                        set: { model.setAppBarColor(NSColor($0)) }
                    ),
                    supportsOpacity: false
                )
            } header: {
                Text("Appearance")
            } footer: {
                Text("The border marks the active window when Maximize windows is off. The app bar color marks the active app, space, and drop target.")
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.state.displayedSpaceIndices, id: \.self) { index in
                        Button { selectedSpaceIndex = index } label: {
                            HStack(spacing: 8) {
                                Text("Space \(index + 1)")
                                Text("\(model.state.spaces[index].windowIDs.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(index == selectedSpaceIndex ? Color.accentColor : nil)
                        .disabled(!model.isRunning || model.isSuspended)
                        .accessibilityLabel("Space \(index + 1), \(model.state.spaces[index].windowIDs.count) \(model.state.spaces[index].windowIDs.count == 1 ? "window" : "windows")")
                        .accessibilityAddTraits(index == selectedSpaceIndex ? .isSelected : [])
                    }
                }
                if model.state.spaces[selectedSpaceIndex].windowIDs.isEmpty {
                    Text(model.isRunning ? "No windows in this space. Move or add one from another space." : "No windows yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 45, alignment: .center)
                } else {
                    ForEach(model.state.spaces[selectedSpaceIndex].windowIDs, id: \.self) { id in
                        if let window = model.windows.first(where: { $0.id == id }) {
                            windowRow(window, inSpace: selectedSpaceIndex)
                        }
                    }
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Select a space here to reorder its windows. Switch spaces with ⌃⌥ plus a number. Shared windows can have a different order in each space.")
            }
        }
        .onChange(of: model.state.displayedSpaceIndices) { _, indices in
            if !indices.contains(selectedSpaceIndex) {
                selectedSpaceIndex = model.state.activeSpaceIndex
            }
        }
    }


    private func windowRow(_ window: WindowRecord, inSpace spaceIndex: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
                .accessibilityHidden(true)
            AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName).font(.body.weight(.medium))
                Text(window.title.isEmpty ? "Untitled window" : window.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if spaceIndex == model.state.activeSpaceIndex && window.id == model.state.focusedWindowID {
                Text("Active").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                let requested = model.state.maximizeWindows ? 100 :
                    Int((model.state.spaces[spaceIndex].widthFraction(for: window.id) * 100).rounded())
                let actual = model.actualWidthPercent(for: window)
                Text("\(actual ?? requested)%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help(actual.map { "This app limits the window to \($0)% width. Stagehand requested \(requested)%." }
                          ?? "Requested width: \(requested)%.")
            }
            Menu {
                Button("Focus") { model.focusWindow(window.id, inSpace: spaceIndex) }
                Menu("Move to") {
                    ForEach(model.state.spaces.indices.filter { $0 != spaceIndex }, id: \.self) { index in
                        Button("Space \(index + 1)") {
                            model.moveMembership(windowID: window.id, fromSpaceIndex: spaceIndex,
                                                 toSpaceIndex: index)
                        }
                    }
                }
                Menu("Share with") {
                    ForEach(model.state.spaces.indices.filter { !model.state.spaces[$0].windowIDs.contains(window.id) }, id: \.self) { index in
                        Button("Space \(index + 1)") {
                            model.shareMembership(windowID: window.id, fromSpaceIndex: spaceIndex,
                                                  toSpaceIndex: index)
                        }
                    }
                }
                if model.state.spaces.filter({ $0.windowIDs.contains(window.id) }).count > 1 {
                    Button("Remove from Space \(spaceIndex + 1)") {
                        model.removeMembership(windowID: window.id, fromSpaceIndex: spaceIndex)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.isRunning || model.isSuspended)
            .accessibilityLabel("Actions for \(window.appName)")
        }
        .padding(.vertical, 2)
        .draggable(window.id)
        .dropDestination(for: String.self) { draggedIDs, _ in
            guard let draggedID = draggedIDs.first,
                  let destination = model.state.spaces[spaceIndex].windowIDs.firstIndex(of: window.id),
                  model.state.spaces[spaceIndex].windowIDs.contains(draggedID) else { return false }
            model.reorderWindow(windowID: draggedID, toIndex: destination, spaceIndex: spaceIndex)
            return true
        }
        .accessibilityAction(named: "Move earlier") {
            guard let index = model.state.spaces[spaceIndex].windowIDs.firstIndex(of: window.id) else { return }
            model.reorderWindow(windowID: window.id, toIndex: index - 1, spaceIndex: spaceIndex)
        }
        .accessibilityAction(named: "Move later") {
            guard let index = model.state.spaces[spaceIndex].windowIDs.firstIndex(of: window.id) else { return }
            model.reorderWindow(windowID: window.id, toIndex: index + 1, spaceIndex: spaceIndex)
        }
    }

    private var controls: some View {
        Group {
            Section {
                Toggle("Enable gesture navigation", isOn: $model.gesturesEnabled)
                    .toggleStyle(.switch)
                Button("Trackpad Settings…") { openSettingsPane("com.apple.Trackpad-Settings.extension") }
            } header: {
                Text("Trackpad")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use a three-finger swipe. Swipe left or right to switch windows, and up or down to switch spaces. Each swipe moves one step.")
                    Text("Keep macOS navigation gestures set to four fingers so they don't overlap with Stagehand. Three-finger dragging may still conflict.")
                }
            }
            shortcutSection("Window navigation", groups: [.windowNavigation, .windowOrder, .windowSize])
            shortcutSection("Space navigation", groups: [.spaceNavigation])
            shortcutSection("Switch to space", groups: [.spaceSwitching])
            shortcutSection("Share window", groups: [.spaceSharing])
            shortcutSection("Move window", groups: [.spaceMoving])
            shortcutSection(
                "Stagehand",
                groups: [.stagehand],
                footer: "Click a binding, then press its replacement. Caps Lock can be used with another key. " +
                    "The reset button restores the original binding and turns it on."
            )
        }
    }

    private func shortcutSection(
        _ title: String,
        groups: [ShortcutBinding.Group],
        footer: String? = nil
    ) -> some View {
        Section {
            ForEach(model.shortcutBindings.filter { groups.contains($0.group) }) { binding in
                shortcutRow(binding)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func shortcutRow(_ binding: ShortcutBinding) -> some View {
        HStack(spacing: 10) {
            Toggle(binding.title, isOn: Binding(
                get: { binding.isEnabled },
                set: { enabled in
                    shortcutError = model.setShortcutEnabled(id: binding.id, enabled: enabled)
                }
            ))
            .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            ShortcutRecorder(
                label: binding.label,
                onRecord: { key, modifiers, keyLabel in
                    shortcutError = model.setShortcut(
                        id: binding.id,
                        key: key,
                        modifiers: modifiers,
                        keyLabel: keyLabel
                    )
                },
                onRecordingChange: model.setShortcutRecording
            )
            .frame(width: 104, height: 24)
            Button { model.resetShortcut(id: binding.id) } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(binding.isDefault)
            .help("Reset \(binding.title) to \(ShortcutBinding.defaultBinding(id: binding.id)?.label ?? "its default")")
            .accessibilityLabel("Reset \(binding.title) to default")
        }
    }

    private var setup: some View {
        Group {
            Section {
                HStack {
                    Label("Accessibility", systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "lock")
                        .foregroundStyle(model.accessibilityGranted ? Color.green : .secondary)
                        .accessibilityValue(model.accessibilityGranted ? "Allowed" : "Required")
                    Spacer()
                    Button(model.accessibilityGranted ? "Open Settings…" : "Allow…") { model.requestAccessibility() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility lets Stagehand move windows, block conflicting scroll events during gestures, and protect typing during window switches.")
            }
            if !model.inputIssues.isEmpty {
                Section("Needs attention") {
                    ForEach(Array(model.inputIssues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section {
                HStack {
                    Toggle("Diagnostic logging", isOn: $model.diagnosticLoggingEnabled)
                        .toggleStyle(.switch)
                    Button("Clear Logs", role: .destructive) { model.clearDiagnosticLog() }
                }
                Button("Show Log in Finder") { model.revealDiagnosticLog() }
                    .disabled(!model.diagnosticLoggingEnabled)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Records starts, pauses, window operations, focus checks, and failures. Logs exclude window titles and keyboard input.")
            }
            Section("Typing protection") {
                Text("When you switch windows, Stagehand holds new keystrokes in memory until it confirms the destination. It never logs or saves them. If focus can't be confirmed, Stagehand discards those keystrokes and shows a warning.")
                    .foregroundStyle(.secondary)
            }
            Section("Limits") {
                Text("Stagehand works with standard windows on one built-in display and one macOS Desktop. It ignores native full-screen windows. Layout settings persist, but space membership resets when Stagehand quits. Pause or quit to restore windows to their original positions.")
                    .foregroundStyle(.secondary)
                Text("Gestures use a private macOS trackpad API. If that API is unavailable, keyboard shortcuts still work. Secure Input may prevent Stagehand from protecting keystrokes during a window switch.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let onRecord: (UInt32, UInt32, String) -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.update(label: label, onRecord: onRecord, onRecordingChange: onRecordingChange)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.update(label: label, onRecord: onRecord, onRecordingChange: onRecordingChange)
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) {
        button.stopRecording()
    }
}

private final class ShortcutRecorderButton: NSButton {
    private var bindingLabel = ""
    private var monitor: Any?
    private var onRecord: ((UInt32, UInt32, String) -> Void)?
    private var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        target = self
        action = #selector(toggleRecording)
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("Record shortcut")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        label: String,
        onRecord: @escaping (UInt32, UInt32, String) -> Void,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        bindingLabel = label
        self.onRecord = onRecord
        self.onRecordingChange = onRecordingChange
        if !isRecording { title = label }
        setAccessibilityValue(label)
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        isRecording = true
        title = "Type shortcut"
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.record(event)
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        title = bindingLabel
        onRecordingChange?(false)
    }

    private func record(_ event: NSEvent) {
        let modifiers = carbonModifiers(event.modifierFlags)
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
            stopRecording()
            return
        }
        onRecord?(UInt32(event.keyCode), modifiers, Self.keyLabel(for: event))
        stopRecording()
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.capsLock) { modifiers |= UInt32(alphaLock) }
        return modifiers
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
        switch Int(event.keyCode) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Escape: return "esc"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "home"
        case kVK_End: return "end"
        case kVK_PageUp: return "page up"
        case kVK_PageDown: return "page down"
        default:
            let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let characters, !characters.isEmpty { return characters.uppercased() }
            return "key \(event.keyCode)"
        }
    }
}
