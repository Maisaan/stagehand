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
                    Text(model.isSuspended ? "Waiting on its Desktop" : model.isRunning ? "Running" : "Paused")
                        .font(.callout.weight(.medium))
                    Text(model.isSuspended ? "Resumes when you return to its Desktop." : model.isRunning ? "Pause restores your original window positions." : "Start to arrange your open windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isRunning ? "Pause & Restore" : "Start Stagehand") {
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
            } header: {
                Text("Ribbon")
            } footer: {
                Text("Use the full available width, or turn off to keep individual widths. Windows retain their resized height and stay centered.")
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
                    Text("Negative values overlap windows, with the active window on top. ↑ / ↓ adjusts by 1 pt, Shift by 10 pt. Press Return or leave the field to apply.")
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
                        .accessibilityLabel("Space \(index + 1), \(model.state.spaces[index].windowIDs.count) windows")
                        .accessibilityAddTraits(index == model.state.activeSpaceIndex ? .isSelected : [])
                    }
                }
                if model.state.currentSpace.windowIDs.isEmpty {
                    Text(model.isRunning ? "This space is empty. Move or add a window from another space." : "Start Stagehand to arrange your open windows.")
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
                Text("Open another space with ⌃⌥ and its number. Shared windows can have a different order in each space.")
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
                    .help(actual.map { "Actual window width. Requested \(requested)%; the app may limit its size. Actual: \($0)%." }
                          ?? "Requested window width.")
            }
            Menu {
                Button("Focus Window") { model.focusWindow(window.id) }
                if window.id == model.state.focusedWindowID {
                    Menu("Move to Space") {
                        ForEach(model.state.spaces.indices.filter { $0 != model.state.activeSpaceIndex }, id: \.self) { index in
                            Button("Space \(index + 1)") { model.navigate(.moveToSpace(index: index, follow: false)) }
                        }
                    }
                    Menu("Add to Another Space") {
                        ForEach(model.state.spaces.indices.filter { !model.state.spaces[$0].windowIDs.contains(window.id) }, id: \.self) { index in
                            Button("Space \(index + 1)") { model.navigate(.shareToSpace(index: index)) }
                        }
                    }
                }
                if model.state.spaces.filter({ $0.windowIDs.contains(window.id) }).count > 1 {
                    Button("Remove from This Space") { model.removeMembership(windowID: window.id) }
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
                Text("Swipe left for the next window, right for the previous one. Swipe up for the next space, down for the previous one. One swipe moves one step.")
            }
            Section {
                Text("Use a different finger count for conflicting macOS gestures, or turn those gestures off in Trackpad settings. Three-finger dragging can also conflict.")
                    .foregroundStyle(.secondary)
            }
            Section {
                shortcut("Previous / next window", keys: "⌃ ⌥ ← / →")
                shortcut("Previous / next space", keys: "⌃ ⌥ ↑ / ↓")
                shortcut("Reorder current window", keys: "⌃ ⌥ ⌘ ← / →")
                shortcut("Go to space", keys: "⌃ ⌥ 1 … 9")
                shortcut("Move window to space", keys: "⌃ ⌥ ⇧ 1 … 9")
                shortcut("Move window and follow", keys: "⌃ ⌥ ⌘ 1 … 9")
                shortcut("Shrink / grow width", keys: "⌥ ⌘ 1 / 2")
                shortcut("Pause and restore windows", keys: "⌃ ⌥ esc")
                shortcut("Open settings", keys: "⌃ ⌥ ,")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Add a window to another space from its menu in the Workspace tab. Shortcuts are fixed in this first version.")
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
                    Label(model.accessibilityGranted ? "Accessibility enabled" : "Accessibility required",
                          systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "lock")
                        .foregroundStyle(model.accessibilityGranted ? Color.green : .secondary)
                    Spacer()
                    Button(model.accessibilityGranted ? "Open Settings…" : "Grant Access…") { model.requestAccessibility() }
                }
                LabeledContent("Input Monitoring") {
                    Button("Open Settings…") {
                        model.requestInputMonitoring()
                        openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
                    }
                }
                Button("Check Permissions Again") { model.refreshPermissions() }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility lets Stagehand move windows. Input Monitoring protects typing while the active window changes.")
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
            Section("Keyboard focus") {
                Text("While switching windows, Stagehand holds typing in memory until it confirms the destination. Nothing is logged or saved. If confirmation fails, it warns you and withholds that input instead of sending it to the wrong app.")
                    .foregroundStyle(.secondary)
            }
            Section("About Stagehand") {
                Text("Built for your Mac’s built-in display and ordinary windows on one macOS Desktop. Native fullscreen is excluded. Layout preferences are saved; space membership lasts for this Stagehand session. Pause or quit to restore original window positions.")
                    .foregroundStyle(.secondary)
                Text("Gesture recognition uses a private macOS trackpad API. If it is unavailable, keyboard navigation still works. Secure Input can prevent keyboard interception.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
