import AppKit
import SwiftUI
import StagehandPlatform

/// One entry in the shortcut ribbon: keys and what they do. The modifiers belong to its row.
struct ShortcutHint: Equatable, Identifiable {
    let title: String
    let keys: [String]
    var id: String { title + keys.joined() }
}

/// One modifier combination. Each column holds the same kind of key in every row,
/// so ← → lines up with ← →, 1–9 with 1–9, and so on.
struct ShortcutHintRow: Equatable, Identifiable {
    let modifiers: String
    var columns: [[ShortcutHint]]
    var id: String { modifiers }

    /// The ribbon's rows, built from the current bindings so edited chords show as edited.
    /// Disabled bindings are left out. Rows appear in the order of their first entry,
    /// and columns that are empty in every row are dropped.
    static func rows(for bindings: [ShortcutBinding]) -> [Self] {
        let byID = Dictionary(bindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spaces = (1...9).map(String.init)
        let entries: [(column: Int, title: String, ids: [String])] = [
            (0, "Focus", ["focusPrevious", "focusNext"]),
            (0, "Reorder", ["reorderPrevious", "reorderNext"]),
            (1, "Space", ["previousSpace", "nextSpace"]),
            (1, "Move", ["moveWindowUpSpace", "moveWindowDownSpace"]),
            (2, "Go to", spaces.map { "goToSpace.\($0)" }),
            (2, "Move to", spaces.map { "moveToSpace.\($0)" }),
            (2, "Share with", spaces.map { "shareToSpace.\($0)" }),
            (3, "Width", ["shrinkWidth", "growWidth"]),
            (3, "Height", ["shrinkHeight", "growHeight"]),
            (4, "Preset", ["nextWidthPreset"]),
            (4, "Previous preset", ["previousWidthPreset"]),
            (5, "Pause", ["togglePause"]),
            (5, "Shortcuts", ["toggleShortcutHints"]),
            (6, "Settings", ["showSettings"]),
        ]
        let columnCount = 7
        var rows: [Self] = []
        for entry in entries {
            let enabled = entry.ids.compactMap { byID[$0] }.filter(\.isEnabled)
            // A rebound chord may leave one entry with different modifiers; each goes to its own row.
            var groups: [(modifiers: String, bindings: [ShortcutBinding])] = []
            for binding in enabled {
                if let index = groups.firstIndex(where: { $0.modifiers == binding.modifierLabel }) {
                    groups[index].bindings.append(binding)
                } else {
                    groups.append((binding.modifierLabel, [binding]))
                }
            }
            for group in groups {
                let keys = group.bindings.count > 3
                    ? ["\(group.bindings[0].keyLabel)–\(group.bindings[group.bindings.count - 1].keyLabel)"]
                    : group.bindings.map(\.keyLabel)
                let hint = ShortcutHint(title: entry.title, keys: keys)
                if let index = rows.firstIndex(where: { $0.modifiers == group.modifiers }) {
                    rows[index].columns[entry.column].append(hint)
                } else {
                    var columns = Array(repeating: [ShortcutHint](), count: columnCount)
                    columns[entry.column] = [hint]
                    rows.append(Self(modifiers: group.modifiers, columns: columns))
                }
            }
        }
        let used = (0..<columnCount).filter { column in rows.contains { !$0.columns[column].isEmpty } }
        return rows.map { row in
            var row = row
            row.columns = used.map { row.columns[$0] }
            return row
        }
    }
}

@MainActor
final class ShortcutHintsModel: ObservableObject {
    @Published var rows: [ShortcutHintRow] = []
}

struct ShortcutHintsView: View {
    @ObservedObject var model: ShortcutHintsModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(model.rows) { row in
                GridRow {
                    Text(row.modifiers)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .gridColumnAlignment(.trailing)
                    ForEach(row.columns.indices, id: \.self) { column in
                        HStack(spacing: 12) {
                            ForEach(row.columns[column]) { hint in item(hint) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.075).opacity(0.97), in: shape)
        .overlay { shape.stroke(.white.opacity(0.12), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stagehand shortcuts")
    }

    private func item(_ hint: ShortcutHint) -> some View {
        HStack(spacing: 3) {
            ForEach(hint.keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(hint.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.leading, 3)
        }
        .lineLimit(1)
    }
}

/// The shortcut ribbon at the bottom center of the managed display. It ignores the
/// pointer and never becomes key, so it cannot take focus or input from the real app.
/// A transition or the toggle shortcut shows it for `visibleDuration`; pressing the
/// toggle while it shows hides it early.
@MainActor
final class ShortcutHintsRibbon {
    static let bottomInset: CGFloat = 10
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
        let rows = ShortcutHintRow.rows(for: bindings)
        guard rows != model.rows else { return }
        model.rows = rows
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
        guard !model.rows.isEmpty, let screen = NSScreen.managedDisplay else { return }
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
        let width = min(size.width, visible.width - 32)
        let frame = CGRect(x: (visible.midX - width / 2 - padding).rounded(),
                           y: visible.minY + Self.bottomInset - padding,
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
