import AppKit
import SwiftUI
import StagehandCore
import StagehandPlatform

struct SettingsView: View {
    @ObservedObject var model: StagehandModel
    @State private var tab = "Workspace"

    init(model: StagehandModel, initialTab: String = "Workspace") {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.leadinghalf.inset.filled")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.mint)
                    .frame(width: 54, height: 54)
                    .background(.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stagehand").font(.system(size: 24, weight: .semibold))
                    Text("Your windows. A little more room.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.isSuspended ? Color.orange : model.isRunning ? .mint : .secondary)
                        .frame(width: 6, height: 6)
                    Text(model.isSuspended ? "Waiting on its Desktop" : model.isRunning ? "Running" : "Paused")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: Capsule())
            }
            .padding(24)

            Picker("Settings section", selection: $tab) {
                Text("Workspace").tag("Workspace")
                Text("Controls").tag("Controls")
                Text("Setup").tag("Setup")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let warning = model.warning {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            Text(warning).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.dismissWarning() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss warning")
                        }
                        .padding(12)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    switch tab {
                    case "Controls": controls
                    case "Setup": setup
                    default: workspace
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(model.isSuspended ? "Stagehand resumes when you return to its macOS Desktop." : model.isRunning ? "Pause returns windows to their original positions." : "Window management starts only when you press Start.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(model.isRunning ? "Pause & Restore" : "Start Stagehand") {
                    if model.isRunning { model.pause() }
                    else if model.accessibilityGranted { model.start() }
                    else { tab = "Setup"; model.requestAccessibility() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .controlSize(.large)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Layout").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 12) {
                    layoutCard(.scrolling, title: "Scrolling", subtitle: "One ribbon. Room to breathe.", symbol: "rectangle.split.3x1")
                    layoutCard(.monocle, title: "Monocle", subtitle: "One window. All the room.", symbol: "rectangle")
                }
            }
            if model.state.layoutMode == .scrolling {
                HStack(spacing: 14) {
                    Text("Window gap").font(.system(size: 12))
                    Slider(value: $model.gap, in: 0...24, step: 2)
                        .accessibilityLabel("Gap between windows")
                    Text("\(Int(model.gap)) pt").font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 40)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Spaces").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Independent order · shared windows")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 76), spacing: 7)], alignment: .leading, spacing: 7) {
                    ForEach(model.state.displayedSpaceIndices, id: \.self) { index in
                        Button { model.navigate(.goToSpace(index: index)) } label: {
                            VStack(spacing: 5) {
                                Text("\(index + 1)").font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Text("\(model.state.spaces[index].windowIDs.count)")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(index == model.state.activeSpaceIndex ? Color.mint.opacity(0.14) : Color.secondary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay {
                                RoundedRectangle(cornerRadius: 9)
                                    .stroke(index == model.state.activeSpaceIndex ? Color.mint.opacity(0.7) : .clear, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.isRunning || model.isSuspended)
                        .accessibilityLabel("Space \(index + 1), \(model.state.spaces[index].windowIDs.count) windows")
                    }
                }
                Text("Open another space with ⌃⌥ and its number.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.state.currentSpace.windowIDs.isEmpty {
                    Text(model.isRunning ? "This space is empty. Move or add a window from another space." : "Start Stagehand to arrange your open windows.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 45, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.state.currentSpace.windowIDs, id: \.self) { id in
                            if let window = model.windows.first(where: { $0.id == id }) {
                                windowRow(window)
                            }
                        }
                    }
                }
            }
        }
    }

    private func layoutCard(_ mode: LayoutMode, title: String, subtitle: String, symbol: String) -> some View {
        Button { model.setLayout(mode) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 24, weight: .light))
                    .foregroundStyle(model.state.layoutMode == mode ? Color.mint : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(model.state.layoutMode == mode ? Color.mint.opacity(0.08) : Color.secondary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(model.state.layoutMode == mode ? Color.mint.opacity(0.6) : Color.secondary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.state.layoutMode == mode ? .isSelected : [])
    }

    private func windowRow(_ window: WindowRecord) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(window.appName).font(.system(size: 11, weight: .medium))
                Text(window.title.isEmpty ? "Untitled window" : window.title)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if window.id == model.state.focusedWindowID {
                Text("Active").font(.system(size: 9, weight: .medium)).foregroundStyle(.mint)
            }
            if model.state.layoutMode == .scrolling {
                Text("\(Int((model.state.currentSpace.widthFraction(for: window.id) * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).frame(width: 22)
            .disabled(!model.isRunning || model.isSuspended)
            .accessibilityLabel("Actions for \(window.appName)")
        }
        .padding(.vertical, 7)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 10) {
                shortcut("Previous / next window", keys: "⌃ ⌥ ← / →")
                shortcut("Previous / next space", keys: "⌃ ⌥ ↑ / ↓")
                shortcut("Reorder current window", keys: "⌃ ⌥ ⌘ ← / →")
                shortcut("Go to space", keys: "⌃ ⌥ 1 … 9")
                shortcut("Move window to space", keys: "⌃ ⌥ ⇧ 1 … 9")
                shortcut("Move window and follow", keys: "⌃ ⌥ ⌘ 1 … 9")
                shortcut("Shrink / grow width", keys: "⌥ ⌘ 1 / 2")
                shortcut("Pause and restore windows", keys: "⌃ ⌥ esc")
                shortcut("Open settings", keys: "⌃ ⌥ ,")
            }
            Divider()
            Toggle("Four-finger navigation", isOn: $model.gesturesEnabled)
                .font(.system(size: 12, weight: .medium))
            Text("Swipe left for the next window, right for the previous one. Swipe up for the next space, down for the previous one. One swipe moves one step.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Before enabling, move conflicting macOS gestures to three fingers or turn them off in Trackpad settings. Three-finger dragging can also conflict.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open Trackpad Settings") { openSettingsPane("com.apple.Trackpad-Settings.extension") }
            Text("Add a window to another space from its menu in the Workspace tab. Shortcuts are fixed in this first version.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A small amount of setup").font(.system(size: 15, weight: .semibold))
            Text("Stagehand moves real application windows. Their menus and keyboard input stay with the active app. It needs Accessibility permission to do this.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Label(model.accessibilityGranted ? "Accessibility enabled" : "Accessibility required",
                      systemImage: model.accessibilityGranted ? "checkmark.circle.fill" : "lock")
                    .foregroundStyle(model.accessibilityGranted ? Color.mint : .secondary)
                Spacer()
                Button("Grant Access") { model.requestAccessibility() }
                Button("Check Again") { model.refreshPermissions() }
            }
            .font(.system(size: 12))
            Divider()
            Text("Keyboard focus protection").font(.system(size: 13, weight: .semibold))
            Text("During a window switch, Stagehand briefly holds typing in memory until the destination is confirmed. Nothing is logged or saved. If focus cannot be confirmed, it warns you and withholds those events instead of typing into the wrong app.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open Input Monitoring Settings") {
                model.requestInputMonitoring()
                openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
            }
            if !model.inputIssues.isEmpty {
                ForEach(Array(model.inputIssues.enumerated()), id: \.offset) { _, issue in
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("MVP boundaries").font(.system(size: 13, weight: .semibold))
            Text("Built for your Mac’s built-in display and ordinary windows on one macOS Desktop. Native fullscreen is excluded. Layout preferences are saved; space membership lasts for this Stagehand session. Pause or quit to restore original window positions.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Four-finger recognition uses a private macOS trackpad API. If it is unavailable, keyboard navigation still works. Secure Input can prevent keyboard interception.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
