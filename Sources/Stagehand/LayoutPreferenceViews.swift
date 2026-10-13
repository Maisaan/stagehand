import AppKit
import StagehandCore
import StagehandPlatform
import SwiftUI

/// Edits the width presets as whole percentages, for example "50, 75, 100".
/// The value commits on Return or when the field loses focus. Text that holds
/// no usable percentage is discarded and the saved presets are shown again.
struct WidthPresetsCard: View {
    @ObservedObject var model: StagehandModel
    @State private var text: String
    @FocusState private var isEditing: Bool

    init(model: StagehandModel) {
        self.model = model
        _text = State(initialValue: Self.format(model.widthPresets))
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Width presets")
                    Spacer()
                    TextField("50, 75, 100", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 160)
                        .focused($isEditing)
                        .onSubmit(commit)
                        .onChange(of: isEditing) { _, editing in
                            if !editing { commit() }
                        }
                        .accessibilityLabel("Width presets as percentages")
                    Text("%").foregroundStyle(.secondary)
                }
                Text(presetShortcutHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .onChange(of: model.widthPresets) { _, presets in
            if !isEditing { text = Self.format(presets) }
        }
    }

    private var presetShortcutHint: String {
        let next = model.shortcutBindings.first { $0.id == "nextWidthPreset" }
        let previous = model.shortcutBindings.first { $0.id == "previousWidthPreset" }
        let nextLabel = next.map { $0.isEnabled ? $0.label : "an enabled shortcut" } ?? "a shortcut"
        let previousLabel = previous.map { $0.isEnabled ? $0.label : "an enabled shortcut" } ?? "a shortcut"
        return "\(nextLabel) steps the active window to the next wider preset and \(previousLabel) to the next narrower one, wrapping at the ends. Percentages from 25 to 100."
    }

    private func commit() {
        let parsed = Self.parse(text)
        if parsed.isEmpty {
            text = Self.format(model.widthPresets)
            return
        }
        let presets = SpaceState.normalizedWidthPresets(parsed)
        if presets != model.widthPresets { model.widthPresets = presets }
        text = Self.format(presets)
    }

    /// Percentages separated by commas, spaces, or semicolons. Values outside the
    /// supported range are clamped by `normalizedWidthPresets`; other text is ignored.
    nonisolated static func parse(_ text: String) -> [Double] {
        text.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
            .filter(\.isFinite)
            .map { $0 / 100 }
    }

    nonisolated static func format(_ presets: [Double]) -> String {
        presets.map { String(Int(($0 * 100).rounded())) }.joined(separator: ", ")
    }
}

/// Apps whose windows may keep a wider strip on screen when parked. For an app that
/// clamps its windows onscreen, the default 64-point limit fails the layout and
/// pauses Stagehand; a listed app parks as far as it allows instead.
struct ParkedEdgeCard: View {
    @ObservedObject var model: StagehandModel
    @State private var widthText: String
    @FocusState private var isEditingWidth: Bool

    init(model: StagehandModel) {
        self.model = model
        _widthText = State(initialValue: String(Int(model.wideParkedEdgeWidth)))
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Visible edge for listed apps")
                        Spacer()
                        TextField("240", text: $widthText)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .frame(width: 76)
                            .focused($isEditingWidth)
                            .onSubmit(commitWidth)
                            .onChange(of: isEditingWidth) { _, editing in
                                if !editing { commitWidth() }
                            }
                            .accessibilityLabel("Visible parked edge in points")
                        Text("pt").foregroundStyle(.secondary)
                    }
                    Text("Some apps keep part of every window on screen, so Stagehand cannot park them past the edge and pauses. A listed app may leave up to this much visible instead, from \(Int(StagehandModel.wideParkedEdgeWidthBounds.lowerBound)) to \(Int(StagehandModel.wideParkedEdgeWidthBounds.upperBound)) points. The strip stays behind the active window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)

                Divider()

                if model.wideParkedEdgeBundleIdentifiers.isEmpty {
                    Text("No apps listed.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 42)
                } else {
                    ForEach(Array(model.wideParkedEdgeBundleIdentifiers.enumerated()), id: \.element) { index, bundleIdentifier in
                        if index > 0 { Divider() }
                        appRow(bundleIdentifier)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 42)
                    }
                }

                Divider()

                HStack {
                    Menu("Add app") {
                        let candidates = Self.runningApplicationChoices(excluding: model.wideParkedEdgeBundleIdentifiers)
                        if candidates.isEmpty {
                            Text("No other running apps")
                        }
                        ForEach(candidates, id: \.bundleIdentifier) { candidate in
                            Button(candidate.name) {
                                model.wideParkedEdgeBundleIdentifiers.append(candidate.bundleIdentifier)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Add a running app to the wide parked edge list")
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
            }
        }
        .onChange(of: model.wideParkedEdgeWidth) { _, width in
            if !isEditingWidth { widthText = String(Int(width)) }
        }
    }

    private func appRow(_ bundleIdentifier: String) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleIdentifier: bundleIdentifier, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.applicationName(for: bundleIdentifier)).font(.body.weight(.medium))
                Text(bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                model.wideParkedEdgeBundleIdentifiers.removeAll { $0 == bundleIdentifier }
            } label: {
                PhosphorIcon(.xCircle)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(Self.applicationName(for: bundleIdentifier))")
        }
    }

    private func commitWidth() {
        guard let value = GapInput.parse(widthText) else {
            widthText = String(Int(model.wideParkedEdgeWidth))
            return
        }
        let clamped = StagehandModel.clampedWideParkedEdgeWidth(value)
        if clamped != model.wideParkedEdgeWidth { model.wideParkedEdgeWidth = clamped }
        widthText = String(Int(clamped))
    }

    struct ApplicationChoice {
        let bundleIdentifier: String
        let name: String
    }

    /// Ordinary running apps other than Stagehand, by name, without the listed ones.
    /// Running apps are offered rather than managed windows so the list is usable
    /// right after an automatic pause, when no window is managed.
    static func runningApplicationChoices(excluding listed: [String]) -> [ApplicationChoice] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set(listed)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app -> ApplicationChoice? in
                guard let bundleIdentifier = app.bundleIdentifier, bundleIdentifier != own,
                      seen.insert(bundleIdentifier).inserted else { return nil }
                return ApplicationChoice(bundleIdentifier: bundleIdentifier,
                                         name: app.localizedName ?? bundleIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func applicationName(for bundleIdentifier: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleIdentifier
    }
}
