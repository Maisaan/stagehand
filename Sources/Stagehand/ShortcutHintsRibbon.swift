import AppKit
import SwiftUI
import StagehandPlatform

/// One line in the shortcut ribbon: modifiers, keys, and what they do.
struct ShortcutHint: Equatable, Identifiable {
    let title: String
    let modifiers: String
    let keys: [String]
    var id: String { title + modifiers + keys.joined() }
}

/// A titled group of shortcuts for one kind of task.
struct ShortcutHintSection: Equatable, Identifiable {
    let title: String
    let hints: [ShortcutHint]
    var id: String { title }

    /// The ribbon's sections, built from the current bindings so edited chords show as edited.
    /// Disabled bindings are left out, and a section with nothing enabled disappears.
    static func sections(for bindings: [ShortcutBinding]) -> [Self] {
        let byID = Dictionary(bindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func hints(_ title: String, _ ids: [String]) -> [ShortcutHint] {
            let enabled = ids.compactMap { byID[$0] }.filter(\.isEnabled)
            // A rebound chord may give one entry different modifiers; each gets its own line.
            var groups: [(modifiers: String, bindings: [ShortcutBinding])] = []
            for binding in enabled {
                if let index = groups.firstIndex(where: { $0.modifiers == binding.modifierLabel }) {
                    groups[index].bindings.append(binding)
                } else {
                    groups.append((binding.modifierLabel, [binding]))
                }
            }
            return groups.map { group in
                let keys = group.bindings.count > 3
                    ? ["\(group.bindings[0].keyLabel)–\(group.bindings[group.bindings.count - 1].keyLabel)"]
                    : group.bindings.map(\.keyLabel)
                return ShortcutHint(title: title, modifiers: group.modifiers, keys: keys)
            }
        }
        let spaces = (1...9).map(String.init)
        let sections = [
            Self(title: "Navigate", hints:
                hints("Window", ["focusPrevious", "focusNext"])
                + hints("Space", ["previousSpace", "nextSpace"])
                + hints("Go to space", spaces.map { "goToSpace.\($0)" })),
            Self(title: "Move window", hints:
                hints("Reorder", ["reorderPrevious", "reorderNext"])
                + hints("Up or down", ["moveWindowUpSpace", "moveWindowDownSpace"])
                + hints("To space", spaces.map { "moveToSpace.\($0)" })
                + hints("Share with", spaces.map { "shareToSpace.\($0)" })),
            Self(title: "Size", hints:
                hints("Width", ["shrinkWidth", "growWidth"])
                + hints("Height", ["shrinkHeight", "growHeight"])
                + hints("Next preset", ["nextWidthPreset"])
                + hints("Previous preset", ["previousWidthPreset"])),
            Self(title: "Stagehand", hints:
                hints("Pause", ["togglePause"])
                + hints("Settings", ["showSettings"])
                + hints("Shortcuts", ["toggleShortcutHints"])),
        ]
        return sections.filter { !$0.hints.isEmpty }
    }
}

@MainActor
final class ShortcutHintsModel: ObservableObject {
    @Published var sections: [ShortcutHintSection] = []
}

struct ShortcutHintsView: View {
    @ObservedObject var model: ShortcutHintsModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle().fill(.white.opacity(0.08)).frame(width: 1).padding(.horizontal, 14)
                }
                sectionView(section)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.07), in: shape)
        .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stagehand shortcuts")
    }

    private func sectionView(_ section: ShortcutHintSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(section.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 5) {
                ForEach(section.hints) { hint in
                    GridRow {
                        Text(hint.modifiers)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .gridColumnAlignment(.trailing)
                        HStack(spacing: 3) {
                            ForEach(hint.keys, id: \.self) { key in
                                Text(key)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 5)
                                    .frame(minWidth: 18, minHeight: 18)
                                    .background(.white.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        Text(hint.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
        .lineLimit(1)
    }
}

/// The shortcut ribbon in the bottom-right corner of the managed display. It ignores the
/// pointer and never becomes key, so it cannot take focus or input from the real app.
/// The toggle shortcut shows it for `visibleDuration`; pressing it again while it
/// shows hides it early.
@MainActor
final class ShortcutHintsRibbon {
    static let edgeInset: CGFloat = 12
    static let visibleDuration: Duration = .seconds(4)
    private(set) var panel: OverlayPanel?
    private var hostingView: NSHostingView<ShortcutHintsView>?
    private let model = ShortcutHintsModel()
    private let configuration = InterfaceAnimationConfiguration.default
    private let reduceMotion: () -> Bool
    /// Measured once per change of content, not on every transition.
    private var contentSize: CGSize?
    private var generation: UInt64 = 0
    private var isExiting = false
    private var dismissTask: Task<Void, Never>?

    init(reduceMotion: @escaping () -> Bool) {
        self.reduceMotion = reduceMotion
    }

    func setBindings(_ bindings: [ShortcutBinding]) {
        let sections = ShortcutHintSection.sections(for: bindings)
        guard sections != model.sections else { return }
        model.sections = sections
        contentSize = nil
        if isShowing { show() }
    }

    /// Visible and not already fading out.
    var isShowing: Bool { panel?.isVisible == true && !isExiting }

    /// Shows the ribbon, or keeps it up, for another `visibleDuration`.
    func show() {
        present()
        scheduleDismiss(after: Self.visibleDuration)
    }

    func toggle() {
        if isShowing {
            scheduleDismiss(after: .zero)
        } else {
            show()
        }
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        generation &+= 1
        isExiting = false
        panel?.orderOut(nil)
        panel?.close()
        // Recreated on the next presentation, on whichever Desktop that happens.
        panel = nil
        hostingView = nil
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(level: .statusBar)
        let hosting = NSHostingView(rootView: ShortcutHintsView(model: model))
        // fittingSize measures the intrinsic size. The container lays the hosting view out
        // by frame, so this size does not resize the panel.
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = HUDContainerView(hostingView: hosting, anchoredToBottom: true)
        panel.hasShadow = false
        self.panel = panel
        hostingView = hosting
        contentSize = nil
        return panel
    }

    private func present() {
        guard !model.sections.isEmpty, let screen = NSScreen.managedDisplay else { return }
        let panel = self.panel ?? makePanel()
        guard let container = panel.contentView as? HUDContainerView else { return }
        let size: CGSize
        if let contentSize {
            size = contentSize
        } else {
            size = hostingView?.fittingSize ?? .zero
            contentSize = size
        }
        let padding = HUDContainerView.padding
        let visible = screen.visibleFrame
        let width = min(size.width, visible.width - Self.edgeInset * 2)
        let frame = CGRect(x: (visible.maxX - Self.edgeInset - width - padding).rounded(),
                           y: visible.minY + Self.edgeInset - padding,
                           width: width + padding * 2, height: size.height + padding * 2)
        // Successive transitions keep the same frame; skip the synchronous layout then.
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            container.needsLayout = true
            container.layoutSubtreeIfNeeded()
        }
        let wasVisible = panel.isVisible
        let wasExiting = isExiting
        generation &+= 1
        isExiting = false
        dismissTask?.cancel()
        if !wasVisible {
            container.setHidden(reduceMotion: reduceMotion(), configuration: configuration)
            panel.orderFrontRegardless()
        }
        if !wasVisible || wasExiting {
            container.transition(visible: true, reduceMotion: reduceMotion(),
                                 duration: configuration.hudEnterDuration, configuration: configuration)
        }
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        let generation = generation
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.beginDismiss(generation: generation) else { return }
            do { try await Task.sleep(for: .seconds(self.configuration.hudExitDuration)) } catch { return }
            guard !Task.isCancelled else { return }
            self.completeDismiss(generation: generation)
        }
    }

    private func beginDismiss(generation: UInt64) -> Bool {
        guard generation == self.generation, !isExiting, panel?.isVisible == true,
              let container = panel?.contentView as? HUDContainerView else { return false }
        isExiting = true
        container.transition(visible: false, reduceMotion: reduceMotion(),
                             duration: configuration.hudExitDuration, configuration: configuration)
        return true
    }

    private func completeDismiss(generation: UInt64) {
        guard generation == self.generation, isExiting else { return }
        panel?.orderOut(nil)
        isExiting = false
    }
}
