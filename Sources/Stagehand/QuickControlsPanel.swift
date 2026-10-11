import AppKit

@MainActor
final class QuickControlsPanel: NSPanel {
    static let width: CGFloat = 340
    private static let menuBarSpacing: CGFloat = 6
    private static let screenInset: CGFloat = 8

    var onDismiss: (() -> Void)?

    init(contentView: NSView) {
        let fittingSize = contentView.fittingSize
        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: Self.width, height: ceil(fittingSize.height))
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Same dark design as Settings: white dividers and strokes need a dark material.
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        animationBehavior = .none
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }
        contentView?.layoutSubtreeIfNeeded()
        if let contentView {
            setContentSize(NSSize(width: Self.width, height: ceil(contentView.fittingSize.height)))
        }

        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        let proposedX = buttonFrame.midX - frame.width / 2
        let minimumX = screenFrame.minX + Self.screenInset
        let maximumX = screenFrame.maxX - Self.screenInset - frame.width
        let origin = CGPoint(
            x: min(max(proposedX, minimumX), max(minimumX, maximumX)),
            y: max(
                screenFrame.minY + Self.screenInset,
                buttonFrame.minY - frame.height - Self.menuBarSpacing
            )
        )
        present(at: origin)
    }

    func present(at origin: CGPoint) {
        setFrameOrigin(origin)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(nil)
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
