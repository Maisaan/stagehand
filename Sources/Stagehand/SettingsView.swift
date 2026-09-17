import AppKit
import Carbon
import SwiftUI
import StagehandCore
import StagehandPlatform

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case windows = "Windows"
    case shortcuts = "Shortcuts"
    case about = "About"

    var id: Self { self }

    var icon: PhosphorIconName {
        switch self {
        case .general: .gearSix
        case .windows: .cardsThree
        case .shortcuts: .keyboard
        case .about: .info
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .windows: .blue
        case .shortcuts: .indigo
        case .about: .gray
        }
    }

    init(tab: String) {
        switch tab {
        case "Controls", "Shortcuts": self = .shortcuts
        case "Setup", "System", "General": self = .general
        case "About": self = .about
        default: self = .windows
        }
    }
}

private enum ShortcutPage: String, CaseIterable, Identifiable {
    case navigation = "Navigation"
    case arrange = "Layout"
    case spaces = "Spaces"
    case stagehand = "Stagehand"

    var id: Self { self }
}

struct SettingsView: View {
    @ObservedObject var model: StagehandModel
    let showOnboarding: () -> Void
    let expandAboutDetails: Bool
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var page: SettingsPage
    @State private var gapInput: Double
    @State private var selectedSpaceIndex: Int
    @State private var shortcutPage = ShortcutPage.navigation
    @State private var shortcutError: String?
    @State private var launchAtLoginError: String?
    @State private var expandedShortcutGroup: ShortcutBinding.Group?

    init(
        model: StagehandModel,
        initialTab: String = "General",
        showOnboarding: @escaping () -> Void = {},
        expandAboutDetails: Bool = false
    ) {
        self.model = model
        self.showOnboarding = showOnboarding
        self.expandAboutDetails = expandAboutDetails
        _page = State(initialValue: SettingsPage(tab: initialTab))
        _gapInput = State(initialValue: GapInput.clamped(model.gap))
        _selectedSpaceIndex = State(initialValue: model.state.activeSpaceIndex)
        _shortcutError = State(initialValue: nil)
    }

    var body: some View {
        HStack(spacing: 0) {
            List {
                sidebarRow(.general)
                Section("Settings") {
                    sidebarRow(.windows)
                    sidebarRow(.shortcuts)
                }
                Section("Stagehand") {
                    sidebarRow(.about)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 45)
            .frame(width: 224)
            .background(Color.clear)

            Color.white.opacity(0.08)
                .frame(width: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    SettingsPageHeader(page: page)
                    switch page {
                    case .general: general
                    case .windows: windows
                    case .shortcuts: shortcuts
                    case .about: about
                    }
                }
                .padding(16)
                .frame(maxWidth: 620, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 700, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                if controlActiveState == .inactive {
                    Color.black.opacity(0.64)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(.blue)
        .alert("Shortcut unavailable", isPresented: Binding(
            get: { shortcutError != nil },
            set: { if !$0 { shortcutError = nil } }
        )) {
            Button("OK") { shortcutError = nil }
        } message: {
            Text(shortcutError ?? "")
        }
        .alert("Launch at login unavailable", isPresented: Binding(
            get: { launchAtLoginError != nil },
            set: { if !$0 { launchAtLoginError = nil } }
        )) {
            Button("OK") { launchAtLoginError = nil }
        } message: {
            Text(launchAtLoginError ?? "")
        }
    }

    private func sidebarRow(_ item: SettingsPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 10) {
                SettingsSidebarIcon(symbol: item.icon, color: item.color)
                Text(item.rawValue)
                Spacer(minLength: 0)
                if item == .general, model.warning != nil || !model.inputIssues.isEmpty {
                    PhosphorIcon(.warningCircle)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Needs attention")
                }
            }
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(item == page ? Color.white.opacity(0.08) : Color.clear)
                    .padding(.leading, -8)
                    .padding(.trailing, -4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
    }

    private var general: some View {
        Group {
            SettingsSection("Status") {
                SettingsCard {
                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stagehand")
                            StatusLabel(
                                title: model.isSuspended ? "Waiting for managed desktop" : model.isRunning ? "Running" : "Paused",
                                color: model.isSuspended ? .orange : model.isRunning ? .green : .secondary
                            )
                        }
                    } trailing: {
                        Toggle("Stagehand", isOn: Binding(
                            get: { model.isRunning },
                            set: { enabled in
                                if enabled {
                                    if model.accessibilityGranted { model.start() }
                                    else { model.requestAccessibility() }
                                } else {
                                    model.pause()
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }

                    Divider()

                    SettingsRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility")
                            StatusLabel(
                                title: model.accessibilityGranted ? "Granted" : "Required",
                                color: model.accessibilityGranted ? .green : .orange
                            )
                        }
                    } trailing: {
                        Button(model.accessibilityGranted ? "Open System Settings…" : "Allow…") {
                            if model.accessibilityGranted {
                                openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
                            } else {
                                model.requestAccessibility()
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                        .controlSize(.regular)
                    }
                }
            }

            SettingsSection("Gestures") {
                SettingsCard {
                    SettingsRow {
                        HStack(spacing: 6) {
                            Text("Gesture navigation")
                            PhosphorIcon(.info)
                                .frame(width: 13, height: 13)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .help("Three-finger swipes move between windows and spaces. Set macOS trackpad gestures to four fingers to avoid conflicts.")
                    } trailing: {
                        Toggle("Gesture navigation", isOn: $model.gesturesEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Divider()
                    SettingsRow("Trackpad settings") {
                        Button("Open…") { openSettingsPane("com.apple.Trackpad-Settings.extension") }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 8))
                            .controlSize(.regular)
                    }
                }
            }

            SettingsSection("Startup") {
                SettingsCard {
                    SettingsRow("Launch at login") {
                        Toggle("Launch at login", isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { enabled in
                                do {
                                    try model.setLaunchAtLoginEnabled(enabled)
                                } catch {
                                    launchAtLoginError = "Stagehand couldn't update this setting. \(error.localizedDescription)"
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            } footer: {
                if model.launchAtLoginRequiresApproval {
                    Text("Allow Stagehand in System Settings > General > Login Items.")
                }
            }

            if model.warning != nil || !model.inputIssues.isEmpty {
                SettingsSection("Needs attention") {
                    SettingsCard {
                        if let warning = model.warning {
                            warningRow(warning, dismissible: true)
                        }
                        ForEach(Array(model.inputIssues.enumerated()), id: \.offset) { index, issue in
                            if model.warning != nil || index > 0 { Divider() }
                            warningRow(issue, dismissible: false)
                        }
                    }
                }
            }

            SettingsSection("Diagnostics") {
                SettingsCard {
                    SettingsRow("Diagnostic logging") {
                        Toggle("Diagnostic logging", isOn: $model.diagnosticLoggingEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Divider()
                    HStack(spacing: 0) {
                        SettingsActionButton("Show in Finder") { model.revealDiagnosticLog() }
                            .disabled(!model.diagnosticLoggingEnabled)
                        Divider()
                        SettingsActionButton("Clear Log") { model.clearDiagnosticLog() }
                    }
                    .frame(height: 40)
                }
            }
        }
    }

    private func warningRow(_ message: String, dismissible: Bool) -> some View {
        SettingsRow {
            HStack(spacing: 7) {
                PhosphorIcon(.warning)
                    .frame(width: 16, height: 16)
                Text(message)
            }
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            if dismissible {
                Button { model.dismissWarning() } label: {
                    PhosphorIcon(.x)
                        .frame(width: 12, height: 12)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss warning")
            }
        }
    }

    private var windows: some View {
        Group {
            SettingsSection("Layout") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
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
                    .padding(14)
                }
            }

            SettingsSection("Spaces") {
                SettingsCard {
                    SettingsRow("Space") {
                        Picker("Space", selection: $selectedSpaceIndex) {
                            ForEach(model.state.displayedSpaceIndices, id: \.self) { index in
                                let count = model.state.spaces[index].windowIDs.count
                                Text("Space \(index + 1) · \(count) \(count == 1 ? "window" : "windows")")
                                    .tag(index)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Divider()

                    SettingsRow("Space color") {
                        HStack(spacing: 8) {
                            HexColorInput(color: model.focusBorderColor(forSpace: selectedSpaceIndex)) { color in
                                model.setFocusBorderColor(color, forSpace: selectedSpaceIndex)
                            }
                            .id(selectedSpaceIndex)
                            .frame(width: 104)
                            ColorPicker(
                                "Space \(selectedSpaceIndex + 1) border color",
                                selection: Binding(
                                    get: { Color(nsColor: model.focusBorderColor(forSpace: selectedSpaceIndex)) },
                                    set: { model.setFocusBorderColor(NSColor($0), forSpace: selectedSpaceIndex) }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                        }
                    }

                    Divider()

                    if model.state.spaces[selectedSpaceIndex].windowIDs.isEmpty {
                        Text(model.isRunning ? "No windows in this space." : "Start Stagehand to see windows in this space.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    } else {
                        ForEach(Array(model.state.spaces[selectedSpaceIndex].windowIDs.enumerated()), id: \.element) { index, id in
                            if index > 0 { Divider() }
                            if let window = model.windows.first(where: { $0.id == id }) {
                                windowRow(window, inSpace: selectedSpaceIndex)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 48)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: model.state.displayedSpaceIndices) { _, indices in
            if !indices.contains(selectedSpaceIndex) {
                selectedSpaceIndex = model.state.activeSpaceIndex
            }
        }
        .onChange(of: model.gap) { _, value in
            gapInput = GapInput.clamped(value)
        }
    }


    private func windowRow(_ window: WindowRecord, inSpace spaceIndex: Int) -> some View {
        HStack(spacing: 10) {
            PhosphorIcon(.list)
                .frame(width: 14, height: 14)
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
                let requested = Int((model.state.spaces[spaceIndex].widthFraction(for: window.id) * 100).rounded())
                let actual = model.actualWidthPercent(for: window)
                Text("\(actual ?? requested)%")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help(actual.map { "Current width: \($0)%. Stagehand remembers the size this app accepts." }
                          ?? "Remembered width: \(requested)%.")
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
                PhosphorIcon(.dotsThreeCircle)
                    .frame(width: 16, height: 16)
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

    private var shortcuts: some View {
        SettingsSection("Keyboard shortcuts") {
            VStack(spacing: 12) {
                Picker("Shortcut category", selection: $shortcutPage) {
                    ForEach(ShortcutPage.allCases) { page in
                        Text(page.rawValue).tag(page)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel("Shortcut category")

                SettingsCard {
                    switch shortcutPage {
                    case .navigation:
                        shortcutRows(groups: [.windowNavigation, .spaceNavigation])
                    case .arrange:
                        shortcutRows(groups: [.windowOrder, .windowSize])
                    case .spaces:
                        spaceShortcutGroup("Switch spaces", group: .spaceSwitching)
                        Divider()
                        spaceShortcutGroup("Share current window", group: .spaceSharing)
                        Divider()
                        spaceShortcutGroup("Move current window", group: .spaceMoving)
                    case .stagehand:
                        shortcutRows(groups: [.stagehand])
                    }
                }
            }
        }
    }

    private func shortcutRows(groups: Set<ShortcutBinding.Group>) -> some View {
        let bindings = model.shortcutBindings.filter { groups.contains($0.group) }
        return Group {
            ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                if index > 0 { Divider() }
                shortcutRow(binding)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 42)
            }
        }
    }

    private func spaceShortcutGroup(_ title: String, group: ShortcutBinding.Group) -> some View {
        let bindings = model.shortcutBindings.filter { $0.group == group }
        let isExpanded = expandedShortcutGroup == group
        return VStack(spacing: 0) {
            Button {
                expandedShortcutGroup = isExpanded ? nil : group
            } label: {
                HStack(spacing: 8) {
                    PhosphorIcon(.caretRight)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text(title)
                    Spacer()
                    Text("\(bindings.count) shortcuts")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(spacing: 0) {
                    Divider()
                    ForEach(Array(bindings.enumerated()), id: \.element.id) { index, binding in
                        if index > 0 { Divider() }
                        shortcutRow(binding)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 42)
                    }
                }
            }
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
            if !binding.isDefault {
                Button { model.resetShortcut(id: binding.id) } label: {
                    PhosphorIcon(.arrowCounterClockwise)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .help("Reset \(binding.title) to \(ShortcutBinding.defaultBinding(id: binding.id)?.label ?? "its default")")
                .accessibilityLabel("Reset \(binding.title) to default")
            }
        }
    }

    private var about: some View {
        Group {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 58, height: 58)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stagehand")
                            .font(.title3.weight(.semibold))
                        Text("A trackpad-first window manager")
                            .foregroundStyle(.secondary)
                        Text("Version \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(16)
            }

            SettingsSection("How Stagehand works") {
                SettingsCard {
                    SettingsDisclosureRow("Typing protection", initiallyExpanded: expandAboutDetails) {
                        Text("While switching windows, Stagehand briefly buffers keystrokes until the new window has focus. It never writes them to disk or includes them in logs.")
                    }

                    Divider()

                    SettingsDisclosureRow("Current limits", initiallyExpanded: expandAboutDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Stagehand manages standard windows on the built-in display and one macOS desktop. It ignores full-screen windows.")
                            Text("Pause or quit Stagehand to restore each window to the position and size captured at startup.")
                        }
                    }
                }
            }

            SettingsSection("Onboarding") {
                SettingsCard {
                    SettingsRow("Run onboarding again") {
                        Button("Open…", action: showOnboarding)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 8))
                            .controlSize(.regular)
                    }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private func openSettingsPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsPageHeader: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 8) {
            SettingsSidebarIcon(symbol: page.icon, color: page.color)
            Text(page.rawValue)
                .font(.title2.weight(.semibold))
        }
    }
}

private struct SettingsSection<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            content
            footer
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
        }
    }
}

private extension SettingsSection where Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View, Trailing: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    init(@ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            content
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }
}

private extension SettingsRow where Content == Text {
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init { Text(title) } trailing: { trailing() }
    }
}

private struct SettingsActionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsDisclosureRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool

    init(
        _ title: String,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion
                    ? .linear(duration: 0.1)
                    : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    PhosphorIcon(.caretRight)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                    .padding(.trailing, 4)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .clipped()
        .padding(.horizontal, 12)
    }
}

private struct StatusLabel: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct SettingsSidebarIcon: View {
    let symbol: PhosphorIconName
    let color: Color

    var body: some View {
        PhosphorIcon(symbol)
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
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
    private static weak var activeRecorder: ShortcutRecorderButton?

    private var bindingLabel = ""
    private var monitor: Any?
    private var cancellationObservers: [NSObjectProtocol] = []
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
        Self.activeRecorder?.stopRecording()
        Self.activeRecorder = self
        isRecording = true
        title = "Press shortcut"
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
        if let window {
            cancellationObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            })
        }
        cancellationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRecording() }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.record(event)
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in cancellationObservers { NotificationCenter.default.removeObserver(observer) }
        cancellationObservers.removeAll()
        monitor = nil
        isRecording = false
        if Self.activeRecorder === self { Self.activeRecorder = nil }
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
        case kVK_ANSI_Equal where event.modifierFlags.contains(.shift): return "+"
        default:
            let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let characters, !characters.isEmpty { return characters.uppercased() }
            return "key \(event.keyCode)"
        }
    }
}

enum RGBHexColor {
    static func parse(_ text: String) -> NSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func format(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

struct HexColorInput: View {
    let color: NSColor
    let onCommit: (NSColor) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(color: NSColor, onCommit: @escaping (NSColor) -> Void) {
        self.color = color
        self.onCommit = onCommit
        _text = State(initialValue: RGBHexColor.format(color))
    }

    var body: some View {
        TextField("#RRGGBB", text: $text)
            .font(.body.monospaced())
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($isFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.1), lineWidth: 1)
            }
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: color) { _, color in
                if !isFocused { text = RGBHexColor.format(color) }
            }
    }

    private func commit() {
        guard let parsed = RGBHexColor.parse(text) else {
            text = RGBHexColor.format(color)
            return
        }
        text = RGBHexColor.format(parsed)
        onCommit(parsed)
    }
}
