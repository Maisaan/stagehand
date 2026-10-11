import AppKit
import QuartzCore
import StagehandPlatform
import SwiftUI

@MainActor
enum SettingsWindow {
    static let cornerRadius: CGFloat = 26

    static func make(model: StagehandModel, showOnboarding: @escaping () -> Void = {}) -> NSWindow {
        let window = SettingsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Stagehand"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        // The settings design uses white dividers, selection fills, and button tints
        // over a dark material. Pin the appearance so Light Mode cannot wash them out.
        window.appearance = NSAppearance(named: .darkAqua)
        // Settings belongs to Stage Manager as a utility window, but must never
        // join another app's native full-screen Space.
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        window.contentView = NSHostingView(rootView: SettingsView(model: model, showOnboarding: showOnboarding))
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.alignWindowControls()
        window.contentMinSize = NSSize(width: 700, height: 620)
        window.center()
        return window
    }
}

@MainActor
private final class SettingsPanelWindow: NSWindow, FocusBorderCornerRadiusProviding {
    private static let windowControlInset: CGFloat = 26
    private static let transitionDuration = 0.25
    private static let reducedMotionDuration = 0.15
    private static let hiddenScale: CGFloat = 0.96
    private var transitionGeneration: UInt64 = 0
    private var isDismissing = false
    var focusBorderCornerRadius: CGFloat { SettingsWindow.cornerRadius }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        let wasVisible = isVisible
        let wasDismissing = isDismissing
        let shouldAnimate = NSApp.currentEvent?.type != .keyDown
        transitionGeneration &+= 1
        isDismissing = false

        if shouldAnimate, !wasVisible { setHiddenAppearance() }
        else if !shouldAnimate { setVisibleAppearance() }
        super.makeKeyAndOrderFront(sender)
        guard shouldAnimate, !wasVisible || wasDismissing else { return }
        transition(visible: true)
    }

    override func performClose(_ sender: Any?) {
        guard isVisible, !isDismissing else { return }
        guard NSApp.currentEvent?.type != .keyDown else {
            super.performClose(sender)
            return
        }

        isDismissing = true
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transition(visible: false) { [weak self] in
            guard let self, self.isDismissing, self.transitionGeneration == generation else { return }
            self.isDismissing = false
            self.finishClosing(sender)
        }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        alignWindowControls()
    }

    func alignWindowControls() {
        guard let closeButton = standardWindowButton(.closeButton) else { return }
        let closeFrame = closeButton.convert(closeButton.bounds, to: nil)
        let closeCenter = CGPoint(x: closeFrame.midX, y: closeFrame.midY)
        let offset = CGPoint(
            x: Self.windowControlInset - closeCenter.x,
            y: frame.height - Self.windowControlInset - closeCenter.y
        )
        guard offset != .zero else { return }

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(buttonType) else { continue }
            button.setFrameOrigin(CGPoint(
                x: button.frame.minX + offset.x,
                y: button.frame.minY + offset.y
            ))
        }
    }

    private var animatedLayer: CALayer? {
        guard let frameView = contentView?.superview else { return nil }
        frameView.wantsLayer = true
        return frameView.layer
    }

    private var hiddenTransform: CATransform3D {
        CATransform3DMakeScale(Self.hiddenScale, Self.hiddenScale, 1)
    }

    private func setHiddenAppearance() {
        guard let layer = animatedLayer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DIdentity
            : hiddenTransform
        CATransaction.commit()
    }

    private func setVisibleAppearance() {
        guard let layer = animatedLayer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func transition(visible: Bool, completion: (() -> Void)? = nil) {
        guard let layer = animatedLayer else {
            completion?()
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let current = layer.presentation() ?? layer
        let currentOpacity = current.opacity
        let currentTransform = current.transform
        let targetOpacity: Float = visible ? 1 : 0
        let targetTransform = visible || reduceMotion ? CATransform3DIdentity : hiddenTransform
        let duration = reduceMotion ? Self.reducedMotionDuration : Self.transitionDuration

        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        layer.opacity = targetOpacity
        layer.transform = targetTransform

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = currentOpacity
        fade.toValue = targetOpacity
        fade.duration = duration
        fade.timingFunction = RibbonAnimationCurve.easeOut.mediaTimingFunction
        layer.add(fade, forKey: "settingsOpacity")

        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: currentTransform)
            scale.toValue = NSValue(caTransform3D: targetTransform)
            scale.duration = duration
            scale.timingFunction = fade.timingFunction
            layer.add(scale, forKey: "settingsTransform")
        }
        CATransaction.commit()
    }

    private func finishClosing(_ sender: Any?) {
        super.performClose(sender)
    }
}
