import AppKit
import SwiftUI

struct QuickControlsView: View {
    private static let cornerRadius: CGFloat = 20

    @ObservedObject var model: StagehandModel
    let openSettings: () -> Void
    let quit: () -> Void
    let requestAccessibility: () -> Void
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var gapInput: Double

    init(
        model: StagehandModel,
        openSettings: @escaping () -> Void,
        quit: @escaping () -> Void,
        requestAccessibility: @escaping () -> Void
    ) {
        self.model = model
        self.openSettings = openSettings
        self.quit = quit
        self.requestAccessibility = requestAccessibility
        _gapInput = State(initialValue: GapInput.clamped(model.gap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            QuickCard {
                QuickRow("Stagehand") {
                    Toggle("Stagehand", isOn: Binding(
                        get: { model.isRunning },
                        set: { enabled in toggleStagehand(enabled) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                QuickDivider()

                QuickRow("Gesture navigation") {
                    Toggle("Gesture navigation", isOn: $model.gesturesEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                QuickDivider()

                QuickRow("Diagnostic logging") {
                    Toggle("Diagnostic logging", isOn: $model.diagnosticLoggingEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                QuickDivider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Window gap")
                        Spacer()
                        GapInput(value: $gapInput) { model.gap = $0 }
                            .frame(width: 66, height: TextInputMetrics.height)
                        Text("pt")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { gapInput }, set: { gapInput = $0.rounded() }),
                        in: GapInput.bounds
                    ) { editing in
                        if !editing, gapInput != model.gap { model.gap = gapInput }
                    }
                    .accessibilityLabel("Gap between windows")
                }
                .padding(12)

                QuickDivider()

                QuickRow("Space color") {
                    HStack(spacing: 8) {
                        HexColorInput(color: model.focusBorderColor) { color in
                            model.setFocusBorderColor(color)
                        }
                        .id(model.state.activeSpaceIndex)
                        .frame(width: 104, height: TextInputMetrics.height)
                        ForegroundColorPicker(
                            "Space \(model.state.activeSpaceIndex + 1) color",
                            selection: Binding(
                                get: { Color(nsColor: model.focusBorderColor) },
                                set: { model.setFocusBorderColor(NSColor($0)) }
                            )
                        )
                    }
                }
            }

            VStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    HStack(spacing: 7) {
                        PhosphorIcon(.gear)
                            .frame(width: 15, height: 15)
                        Text("Open Settings…")
                    }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("Quit Stagehand", action: quit)
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(.thickMaterial)
                if controlActiveState == .inactive {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.64))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .tint(.blue)
        .onChange(of: model.gap) { _, value in
            gapInput = GapInput.clamped(value)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stagehand")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isSuspended ? Color.orange : model.isRunning ? .green : .secondary)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Space \(model.state.activeSpaceIndex + 1)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        model.isSuspended ? "Waiting for managed desktop" : model.isRunning ? "Running" : "Paused"
    }

    private func toggleStagehand(_ enabled: Bool) {
        if enabled {
            guard model.accessibilityGranted else {
                requestAccessibility()
                return
            }
            model.start()
        } else {
            model.pause()
        }
    }
}

private struct QuickCard<Content: View>: View {
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

private struct QuickDivider: View {
    var body: some View {
        Color.white.opacity(0.08)
            .frame(height: 1)
    }
}

private struct QuickRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
    }
}
