import AppKit
import SwiftUI
import QuartzCore
import StagehandCore
import StagehandPlatform

@MainActor
final class NavigationOverlays {
    private(set) var border: OverlayPanel?
    private(set) var hud: OverlayPanel?
    private(set) var hudGeneration: UInt64 = 0
    private(set) var hudIsExiting = false
    private var dismissTask: Task<Void, Never>?
    private let hudModel = NavigationHUDModel()
    private let reduceMotion: () -> Bool
    private let animationDurationMultiplier: Double

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         animationDurationMultiplier: Double = 1) {
        self.reduceMotion = reduceMotion
        self.animationDurationMultiplier = animationDurationMultiplier
    }

    private func borderPanel() -> OverlayPanel {
        if let border { return border }
        let panel = OverlayPanel()
        panel.contentView = BorderView()
        panel.contentView?.wantsLayer = true
        panel.hasShadow = false
        border = panel
        return panel
    }

    private func hudPanel() -> OverlayPanel {
        if let hud { return hud }
        let panel = OverlayPanel()
        panel.contentView = HUDContainerView(model: hudModel)
        panel.hasShadow = false
        hud = panel
        return panel
    }

    func updateBorder(frame: CGRect, visible: Bool, cornerRadius: CGFloat? = nil, focusChanged: Bool = false) {
        guard visible, let primary = NSScreen.screens.first else {
            border?.orderOut(nil)
            return
        }
        let border = borderPanel()
        (border.contentView as? BorderView)?.cornerRadius = cornerRadius
        let converted = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                               width: frame.width, height: frame.height)
        // Frame/path changes remain synchronous, including throughout a native live resize.
        // Draw inward so the complete stroke remains visible at display edges.
        border.setFrame(converted, display: true)
        if !border.isVisible { border.orderFrontRegardless() }
        if focusChanged, let layer = border.contentView?.layer {
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = layer.animation(forKey: "focusReveal") == nil ? 0.72 : (layer.presentation()?.opacity ?? 0.72)
            reveal.toValue = 1
            reveal.duration = 0.125 * animationDurationMultiplier
            reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            layer.add(reveal, forKey: "focusReveal")
        }
    }

    func showNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        let records = state.currentSpace.windowIDs.compactMap { id in windows.first { $0.id == id } }
        hudModel.space = state.activeSpaceIndex + 1
        hudModel.windows = records
        hudModel.focusedID = state.focusedWindowID
        hudModel.warning = nil
        presentHUD(dismissAfter: .milliseconds(800))
    }

    private func presentHUD(dismissAfter: Duration) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let hud = hudPanel()
        guard let container = hud.contentView as? HUDContainerView else { return }
        hudModel.reduceMotion = reduceMotion()
        hudModel.animationDurationMultiplier = animationDurationMultiplier
        let width = min(580, screen.visibleFrame.width - 32)
        let height: CGFloat = 104
        let padding = HUDContainerView.padding
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        hud.setFrame(CGRect(x: screen.frame.midX - width / 2 - padding,
                            y: top - height - 8 - padding,
                            width: width + padding * 2, height: height + padding * 2), display: true)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        let wasVisible = hud.isVisible
        let wasExiting = hudIsExiting
        hudGeneration &+= 1
        let generation = hudGeneration
        hudIsExiting = false
        dismissTask?.cancel()
        if !wasVisible {
            container.setHidden(reduceMotion: hudModel.reduceMotion)
            hud.orderFrontRegardless()
        }
        if !wasVisible || wasExiting {
            container.transition(visible: true, reduceMotion: hudModel.reduceMotion,
                                 duration: 0.2 * animationDurationMultiplier)
        }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: dismissAfter) } catch { return }
            guard !Task.isCancelled, let self, self.beginHUDDismiss(generation: generation) else { return }
            do { try await Task.sleep(for: .seconds(0.125 * self.animationDurationMultiplier)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = self.completeHUDDismiss(generation: generation)
        }
    }

    @discardableResult
    func beginHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, !hudIsExiting,
              let container = hud?.contentView as? HUDContainerView else { return false }
        hudIsExiting = true
        container.transition(visible: false, reduceMotion: reduceMotion(),
                             duration: 0.125 * animationDurationMultiplier)
        return true
    }

    @discardableResult
    func completeHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, hudIsExiting else { return false }
        hud?.orderOut(nil)
        hudIsExiting = false
        return true
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        hudGeneration &+= 1
        hudIsExiting = false
        border?.orderOut(nil)
        hud?.orderOut(nil)
        border?.close()
        hud?.close()
        // Recreate on the next presentation so an explicit Start on a different native
        // Desktop binds the panels there without making them visible on every Desktop.
        border = nil
        hud = nil
    }

    func showWarning(_ message: String) {
        hudModel.warning = message
        presentHUD(dismissAfter: .seconds(5))
    }
}

/// One hosting view survives consecutive navigation changes. Its parent layer alone moves;
/// no window geometry or managed application participates in the decorative transition.
@MainActor
final class HUDContainerView: NSView {
    static let padding: CGFloat = 16
    let animatedView = NSView()
    let hostingView: NSView

    init(model: NavigationHUDModel) {
        hostingView = NSHostingView(rootView: NavigationHUD(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        animatedView.wantsLayer = true
        addSubview(animatedView)
        animatedView.addSubview(hostingView)
        animatedView.layer?.shadowColor = NSColor.black.cgColor
        animatedView.layer?.shadowOpacity = 0.25
        animatedView.layer?.shadowRadius = 12
        animatedView.layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animatedView.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        hostingView.frame = animatedView.bounds
        CATransaction.commit()
    }

    private func hiddenTransform(reduceMotion: Bool) -> CATransform3D {
        guard !reduceMotion else { return CATransform3DIdentity }
        let scale: CGFloat = 0.95
        let size = animatedView.bounds.size
        // AppKit owns this backing layer's bottom-left anchor and resets custom anchors
        // at commit. Compensate the scale in the transform to keep its top center fixed.
        let x = size.width * (1 - scale) / 2
        let y = size.height * (1 - scale) + size.height * 0.08
        return CATransform3DScale(CATransform3DMakeTranslation(x, y, 0), scale, scale, 1)
    }

    func setHidden(reduceMotion: Bool) {
        guard let layer = animatedView.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = hiddenTransform(reduceMotion: reduceMotion)
        CATransaction.commit()
    }

    func transition(visible: Bool, reduceMotion: Bool, duration: Double) {
        guard let layer = animatedView.layer else { return }
        let current = layer.presentation() ?? layer
        let opacity = current.opacity
        let transform = current.transform
        let targetOpacity: Float = visible ? 1 : 0
        let targetTransform = visible ? CATransform3DIdentity : hiddenTransform(reduceMotion: reduceMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = targetOpacity
        layer.transform = targetTransform
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = targetOpacity
        fade.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.add(fade, forKey: "hudOpacity")
        if reduceMotion {
            layer.removeAnimation(forKey: "hudTransform")
        } else {
            let motion = CABasicAnimation(keyPath: "transform")
            motion.fromValue = NSValue(caTransform3D: transform)
            motion.toValue = NSValue(caTransform3D: targetTransform)
            motion.beginTime = fade.beginTime
            motion.duration = duration
            motion.timingFunction = fade.timingFunction
            layer.add(motion, forKey: "hudTransform")
        }
    }
}

final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        // A border belongs to the Desktop where it was presented. Joining all Spaces or
        // fullscreen auxiliary windows makes it follow native swipe animations.
        collectionBehavior = [.transient, .fullScreenNone, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BorderView: NSView {
    var cornerRadius: CGFloat? {
        didSet { needsDisplay = true }
    }

    static func outline(in bounds: CGRect, cornerRadius: CGFloat? = nil) -> NSBezierPath {
        // Use the target window's native radius. Older systems or ambiguous window matches
        // retain the small fallback; the OS version alone does not determine window shape.
        let nativeRadius = cornerRadius.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 9
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: max(0, nativeRadius - 1), yRadius: max(0, nativeRadius - 1))
        path.lineWidth = 2
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.44, green: 0.85, blue: 0.71, alpha: 0.95).setStroke()
        Self.outline(in: bounds, cornerRadius: cornerRadius).stroke()
    }
}

struct AppIcon: View {
    let bundleIdentifier: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().padding(4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
final class NavigationHUDModel: ObservableObject {
    @Published var space = 1
    @Published var windows: [WindowRecord] = []
    @Published var focusedID: String?
    @Published var warning: String?
    @Published var reduceMotion = false
    var animationDurationMultiplier: Double = 1
}

private struct NavigationHUD: View {
    @ObservedObject var model: NavigationHUDModel
    @Namespace private var selection

    var body: some View {
        Group {
            if let warning = model.warning {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).font(.system(size: 12)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                navigation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.075).opacity(0.97), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.12), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
    }

    private var navigation: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SPACE \(model.space, format: .number.precision(.integerLength(2)))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
                Text("RIBBON")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.55))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.windows) { window in
                            AppIcon(bundleIdentifier: window.bundleIdentifier)
                                .padding(6)
                                .background {
                                    if window.id == model.focusedID {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.mint.opacity(0.25))
                                            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.mint.opacity(0.8), lineWidth: 1) }
                                            .matchedGeometryEffect(id: "selection", in: selection)
                                            .transition(.identity)
                                    }
                                }
                                .id(window.id)
                        }
                    }
                    .frame(minWidth: 1)
                    .animation(model.reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1,
                                                                      duration: 0.18 * model.animationDurationMultiplier),
                               value: model.focusedID)
                }
                .onChange(of: model.focusedID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: model.windows.map(\.id)) { _, _ in
                    if let id = model.focusedID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Text(model.windows.first(where: { $0.id == model.focusedID }).map {
                $0.title.isEmpty ? $0.appName : "\($0.appName) · \($0.title)"
            } ?? "Empty space")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
