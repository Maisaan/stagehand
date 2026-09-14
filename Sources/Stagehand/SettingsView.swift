import AppKit
import SwiftUI
import StagehandCore
import StagehandPlatform

struct SettingsView: View {
    @ObservedObject var model: StagehandModel
    @State private var tab = "Workspace"
    @State private var gapInput: Double

    init(model: StagehandModel, initialTab: String = "Workspace") {
        self.model = model
        _tab = State(initialValue: initialTab)
        _gapInput = State(initialValue: GapInput.clamped(model.gap))
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.state.displayedSpaceIndices, id: \.self) { index in
                        Button { model.navigate(.goToSpace(index: index)) } label: {
                            HStack(spacing: 8) {
                                Text("Space \(index + 1)")
                                Text("\(model.state.spaces[index].windowIDs.count)")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(index == model.state.activeSpaceIndex ? Color.accentColor : nil)
                        .disabled(!model.isRunning || model.isSuspended)
                        .accessibilityLabel("Space \(index + 1), \(model.state.spaces[index].windowIDs.count) \(model.state.spaces[index].windowIDs.count == 1 ? "window" : "windows")")
                        .accessibilityAddTraits(index == model.state.activeSpaceIndex ? .isSelected : [])
                    }
                }
                if model.state.currentSpace.windowIDs.isEmpty {
                    Text(model.isRunning ? "No windows in this space. Move or add one from another space." : "No windows yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 45, alignment: .center)
                } else {
                    ForEach(model.state.currentSpace.windowIDs, id: \.self) { id in
                        if let window = model.windows.first(where: { $0.id == id }) {
                            windowRow(window)
                        }
                    }
                }
            } header: {
                Text("Spaces")
            } footer: {
                Text("Switch spaces with ⌃⌥ plus a number. Shared windows can have a different order in each space.")
            }
        }
    }


    private func windowRow(_ window: WindowRecord) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName).font(.body.weight(.medium))
                Text(window.title.isEmpty ? "Untitled window" : window.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if window.id == model.state.focusedWindowID {
                Text("Active").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                let requested = model.state.maximizeWindows ? 100 :
                    Int((model.state.currentSpace.widthFraction(for: window.id) * 100).rounded())
                let actual = model.actualWidthPercent(for: window)
                Text("\(actual ?? requested)%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help(actual.map { "This app limits the window to \($0)% width. Stagehand requested \(requested)%." }
                          ?? "Requested width: \(requested)%.")
            }
            Menu {
                Button("Focus") { model.focusWindow(window.id) }
                if window.id == model.state.focusedWindowID {
                    Menu("Move to") {
                        ForEach(model.state.spaces.indices.filter { $0 != model.state.activeSpaceIndex }, id: \.self) { index in
                            Button("Space \(index + 1)") { model.navigate(.moveToSpace(index: index, follow: false)) }
                        }
                    }
                    Menu("Share with") {
                        ForEach(model.state.spaces.indices.filter { !model.state.spaces[$0].windowIDs.contains(window.id) }, id: \.self) { index in
                            Button("Space \(index + 1)") { model.navigate(.shareToSpace(index: index)) }
                        }
                    }
                }
                if model.state.spaces.filter({ $0.windowIDs.contains(window.id) }).count > 1 {
                    Button("Remove from this space") { model.removeMembership(windowID: window.id) }
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
    }

    private var controls: some View {
        Group {
            Section {
                Toggle("Gesture navigation", isOn: $model.gesturesEnabled)
                    .toggleStyle(.switch)
                HStack {
                    Text("Swipe with")
                    Spacer()
                    Picker("Fingers", selection: $model.gestureFingerCount) {
                        Text("Three fingers").tag(3)
                        Text("Four fingers").tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(!model.gesturesEnabled)
                    .accessibilityLabel("Navigation gesture fingers")
                }
                Button("Trackpad Settings…") { openSettingsPane("com.apple.Trackpad-Settings.extension") }
            } header: {
                Text("Trackpad")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Swipe left for the next window and right for the previous one. Swipe up for the next space and down for the previous one. Each swipe moves one step.")
                    Text("If macOS uses the same finger count, choose the other count here or turn off the conflicting gesture in Trackpad settings. Three-finger dragging may also conflict.")
                }
            }
            Section {
                shortcut("Previous or next window", keys: "⌃ ⌥ ← / →")
                shortcut("Previous or next space", keys: "⌃ ⌥ ↑ / ↓")
                shortcut("Move current window left or right", keys: "⌃ ⌥ ⌘ ← / →")
                shortcut("Switch to space", keys: "⌃ ⌥ 1 … 9")
                shortcut("Share window with space", keys: "⌃ ⌥ ⇧ 1 … 9")
                shortcut("Move window and switch spaces", keys: "⌃ ⌥ ⌘ 1 … 9")
                shortcut("Shrink or grow window width", keys: "⌥ ⌘ 1 / 2")
                shortcut("Pause and restore windows", keys: "⌃ ⌥ esc")
                shortcut("Open settings", keys: "⌃ ⌥ ,")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Right-click an app in the app bar to share or remove it. Shortcuts can't be changed yet.")
            }
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
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
                Toggle("Diagnostic logging", isOn: $model.diagnosticLoggingEnabled)
                    .toggleStyle(.switch)
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
