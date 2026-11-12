import AppKit
import StagehandCore
import StagehandPlatform

/// Where a window shown on two displays is not: its pane on the display that does not hold it.
struct ContestedPlaceholder: Equatable {
    let windowID: String
    let display: DisplayID
    /// Accessibility coordinates, as window frames are.
    var frame: CGRect
    let color: NSColor
    let bundleIdentifier: String
}

@MainActor
protocol ContestedPlaceholderPresenting: AnyObject {
    /// A click on a placeholder: a request to focus its window on that display.
    var onClick: ((String, DisplayID) -> Void)? { get set }
    /// Shows exactly these placeholders, reusing the panels already shown.
    func show(_ placeholders: [ContestedPlaceholder])
    func move(_ frames: [String: CGRect], on display: DisplayID)
    func hide()
}

/// One borderless, non-activating panel per placeholder. Stagehand never registers
/// these windows, so they are never managed, and they never become key.
@MainActor
final class ContestedWindowPlaceholders: ContestedPlaceholderPresenting {
    private struct Key: Hashable {
        let windowID: String
        let display: DisplayID
    }

    var onClick: ((String, DisplayID) -> Void)?
    private var panels: [Key: PlaceholderPanel] = [:]

    func show(_ placeholders: [ContestedPlaceholder]) {
        let keys = Set(placeholders.map { Key(windowID: $0.windowID, display: $0.display) })
        for (key, panel) in panels where !keys.contains(key) {
            MainThreadActivity.during("placeholder close") { panel.close() }
            panels[key] = nil
        }
        for placeholder in placeholders {
            let key = Key(windowID: placeholder.windowID, display: placeholder.display)
            let panel = panels[key] ?? makePanel(for: key)
            panel.placeholderView.configure(color: placeholder.color,
                                            icon: AppIconCache.icon(for: placeholder.bundleIdentifier))
            setFrame(placeholder.frame, of: panel)
            // Behind every window: with a negative Tile gap a pane overlaps its neighbours, and
            // a placeholder in front would cover the focused window and take its clicks.
            if !panel.isVisible { MainThreadActivity.during("placeholder orderBack") { panel.orderBack(nil) } }
        }
    }

    func move(_ frames: [String: CGRect], on display: DisplayID) {
        for (windowID, frame) in frames {
            guard let panel = panels[Key(windowID: windowID, display: display)] else { continue }
            setFrame(frame, of: panel)
        }
    }

    func hide() {
        MainThreadActivity.during("placeholder close") { panels.values.forEach { $0.close() } }
        panels.removeAll()
    }

    private func makePanel(for key: Key) -> PlaceholderPanel {
        let panel = PlaceholderPanel()
        panel.placeholderView.onClick = { [weak self] in self?.onClick?(key.windowID, key.display) }
        panels[key] = panel
        return panel
    }

    private func setFrame(_ frame: CGRect, of panel: PlaceholderPanel) {
        guard let primary = NSScreen.screens.first else { return }
        let converted = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        guard panel.frame != converted else { return }
        MainThreadActivity.during("placeholder setFrame") { panel.setFrame(converted, display: true) }
    }
}

private final class PlaceholderPanel: NSPanel {
    let placeholderView = PlaceholderView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .normal
        hasShadow = false
        hidesOnDeactivate = false
        // Like the overlays: it belongs to the Desktop it was shown on and stays out of window cycling.
        collectionBehavior = [.transient, .fullScreenNone, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = placeholderView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PlaceholderView: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = BorderView.fallbackCornerRadius
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(color: NSColor, icon: NSImage?) {
        layer?.backgroundColor = color.withAlphaComponent(0.25).cgColor
        if iconView.image !== icon { iconView.image = icon }
    }

    override func layout() {
        super.layout()
        let side = min(64, bounds.width / 2, bounds.height / 2)
        iconView.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
