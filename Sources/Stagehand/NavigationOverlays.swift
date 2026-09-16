import AppKit
import SwiftUI
import QuartzCore
import StagehandCore
import StagehandPlatform

struct InterfaceAnimationConfiguration: Equatable {
    static let durationRange = 0.0 ... 0.6
    static let travelRange = 0.0 ... 40.0
    static let scaleRange = 0.9 ... 1.0
    static let opacityRange = 0.2 ... 1.0
    static let `default` = Self(
        hudEnterDuration: 0.18,
        hudExitDuration: 0.14,
        attachedHUDTravel: 10,
        floatingHUDTravel: 6,
        hiddenHUDScale: 0.98,
        feedbackDuration: 0.15,
        pressedScale: 0.97,
        focusRevealDuration: 0.1,
        focusRevealOpacity: 0.72
    )

    let hudEnterDuration: Double
    let hudExitDuration: Double
    let attachedHUDTravel: Double
    let floatingHUDTravel: Double
    let hiddenHUDScale: Double
    let feedbackDuration: Double
    let pressedScale: Double
    let focusRevealDuration: Double
    let focusRevealOpacity: Double
}

struct NavigationHUDGeometry {
    static let padding: CGFloat = 16
    let contentFrame: CGRect
    let attachedToNotch: Bool

    var panelFrame: CGRect {
        let padded = contentFrame.insetBy(dx: -Self.padding, dy: -Self.padding)
        return CGRect(x: padded.minX, y: padded.minY, width: padded.width,
                      height: padded.height - (attachedToNotch ? Self.padding : 0))
    }

    static func layout(screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                       auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, windowCount: Int,
                       warningHeight: CGFloat? = nil,
                       showsDeveloperControls: Bool = false) -> Self {
        let notch: CGRect?
        if safeAreaTop > 0, let left = auxiliaryLeft, let right = auxiliaryRight,
           left.maxX < right.minX, left.maxX >= screenFrame.minX,
           right.minX <= screenFrame.maxX, left.height > 0, right.height > 0 {
            notch = CGRect(x: left.maxX, y: screenFrame.maxY - safeAreaTop,
                           width: right.minX - left.maxX, height: safeAreaTop)
        } else {
            notch = nil
        }
        let attached = notch != nil && warningHeight == nil
        let developerControlsVisible = warningHeight == nil && showsDeveloperControls
        let maximumWidth: CGFloat = warningHeight != nil ? 580 : developerControlsVisible ? 620 : 520
        let limit = max(1, min(maximumWidth, visibleFrame.width - 32))
        let navigationWidth = 60 + CGFloat(max(1, windowCount)) * 36
        let desiredWidth = warningHeight == nil
            ? max(navigationWidth, developerControlsVisible ? 580 : 0)
            : 580
        let width = min(limit, desiredWidth)
        let height = warningHeight.map { max(72, $0) } ?? (developerControlsVisible ? 304 : 66)
        let centerX = notch?.midX ?? screenFrame.midX
        let left = min(max(centerX - width / 2, visibleFrame.minX + 16), visibleFrame.maxX - 16 - width)
        let top = attached ? (notch?.minY ?? visibleFrame.maxY) : min(visibleFrame.maxY, screenFrame.maxY - safeAreaTop) - 6
        return Self(contentFrame: CGRect(x: left, y: top - height, width: width, height: height),
                    attachedToNotch: attached)
    }
}

@MainActor
final class NavigationOverlays {
    private(set) var border: OverlayPanel?
    private(set) var hud: OverlayPanel?
    private(set) var hudGeneration: UInt64 = 0
    private(set) var hudIsExiting = false
    private var dismissTask: Task<Void, Never>?
    let hudModel = NavigationHUDModel()
    var onFocusWindow: ((String) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String) -> Void)?
    var onReorderWindow: ((String, Int) -> Void)?
    var onAnimationConfigurationChange: ((RibbonAnimationConfiguration) -> Void)?
    var onInterfaceAnimationConfigurationChange: ((InterfaceAnimationConfiguration) -> Void)?
    var canRevealNavigation: (() -> Bool)?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var hoverFrame: CGRect?
    private var contentFrame: CGRect?
    private(set) var pointerKeepsHUDVisible = false
    private(set) var dropTargetKeepsHUDVisible = false
    private let reduceMotion: () -> Bool
    private let animationDurationMultiplier: Double
    private var borderColor = BorderView.defaultColor

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         animationDurationMultiplier: Double = 1) {
        self.reduceMotion = reduceMotion
        self.animationDurationMultiplier = animationDurationMultiplier
        hudModel.onFocusWindow = { [weak self] id in self?.onFocusWindow?(id) }
        hudModel.onSelectSpace = { [weak self] index in self?.onSelectSpace?(index) }
        hudModel.onShareWindow = { [weak self] id, index in self?.onShareWindow?(id, index) }
        hudModel.onRemoveWindow = { [weak self] id in self?.onRemoveWindow?(id) }
        hudModel.onReorderWindow = { [weak self] id, index in self?.onReorderWindow?(id, index) }
        hudModel.onAnimationConfigurationChange = { [weak self] configuration in
            self?.onAnimationConfigurationChange?(configuration)
        }
        hudModel.onInterfaceAnimationConfigurationChange = { [weak self] configuration in
            self?.onInterfaceAnimationConfigurationChange?(configuration)
        }
        hudModel.onDropTargetChange = { [weak self] isTargeted in
            self?.dropTargetChanged(isTargeted: isTargeted)
        }
        hudModel.onContentChange = { [weak self] in
            self?.presentHUD(dismissAfter: .milliseconds(1_500))
        }
        hudModel.onPreviewHUDAnimation = { [weak self] in
            self?.previewHUDAnimation()
        }
    }

    private func borderPanel() -> OverlayPanel {
        if let border { return border }
        let panel = OverlayPanel(level: .floating)
        let borderView = BorderView()
        borderView.strokeColor = borderColor
        panel.contentView = borderView
        panel.contentView?.wantsLayer = true
        panel.hasShadow = false
        border = panel
        return panel
    }

    func setBorderColor(_ color: NSColor) {
        borderColor = color
        (border?.contentView as? BorderView)?.strokeColor = color
    }

    private func hudPanel() -> OverlayPanel {
        if let hud { return hud }
        let panel = OverlayPanel(level: .statusBar)
        panel.contentView = HUDContainerView(model: hudModel)
        panel.hasShadow = false
        hud = panel
        return panel
    }

    func setAppBarColor(_ color: NSColor) {
        hudModel.appBarColor = color
    }

    func setDeveloperControlsEnabled(_ enabled: Bool) {
        guard hudModel.developerControlsEnabled != enabled else { return }
        hudModel.developerControlsEnabled = enabled
        if hud?.isVisible == true { presentHUD(dismissAfter: .milliseconds(1_500)) }
    }

    func setRibbonAnimationConfiguration(_ configuration: RibbonAnimationConfiguration) {
        hudModel.setAnimationConfiguration(configuration)
    }

    func setInterfaceAnimationConfiguration(_ configuration: InterfaceAnimationConfiguration) {
        hudModel.setInterfaceAnimationConfiguration(configuration)
    }

    func updateBorder(frame: CGRect, visible: Bool, cornerRadius: CGFloat? = nil, focusChanged: Bool = false) {
        guard visible, let primary = NSScreen.screens.first else {
            border?.orderOut(nil)
            return
        }
        let border = borderPanel()
        let borderView = border.contentView as? BorderView
        let radiusChanged = borderView?.cornerRadius != cornerRadius
        borderView?.cornerRadius = cornerRadius
        let converted = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                               width: frame.width, height: frame.height)
        // Frame/path changes remain synchronous, including throughout a native live resize.
        // Draw inward so the complete stroke remains visible at display edges.
        border.setFrame(converted, display: radiusChanged || border.frame.size != converted.size)
        if !border.isVisible { border.orderFrontRegardless() }
        if focusChanged, let layer = border.contentView?.layer {
            let configuration = hudModel.interfaceAnimationConfiguration
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = layer.animation(forKey: "focusReveal") == nil
                ? configuration.focusRevealOpacity
                : (layer.presentation()?.opacity ?? Float(configuration.focusRevealOpacity))
            reveal.toValue = 1
            reveal.duration = configuration.focusRevealDuration * animationDurationMultiplier
            reveal.timingFunction = RibbonAnimationCurve.ease.mediaTimingFunction
            layer.add(reveal, forKey: "focusReveal")
        }
    }

    func showNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        updateNavigation(state: state, windows: windows)
        hudModel.showingSpaces = false
        hudModel.warning = nil
        presentHUD(dismissAfter: .milliseconds(1_500))
    }

    private func dropTargetChanged(isTargeted: Bool) {
        guard dropTargetKeepsHUDVisible != isTargeted else { return }
        dropTargetKeepsHUDVisible = isTargeted
        if isTargeted {
            presentHUD(dismissAfter: .milliseconds(1_500))
        } else if !pointerKeepsHUDVisible, hud?.isVisible == true {
            scheduleDismiss(after: .milliseconds(450))
        }
    }

    /// Keep hover content current without opening the bar during background reconciliation.
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        let records = state.currentSpace.windowIDs.compactMap { recordsByID[$0] }
        let space = state.activeSpaceIndex + 1
        let availableSpaceIndices = state.displayedSpaceIndices
        if hudModel.space != space { hudModel.space = space }
        if hudModel.windows != records { hudModel.windows = records }
        hudModel.setFocusedID(state.focusedWindowID, animate: hud?.isVisible == true)
        if hudModel.spaces != state.spaces { hudModel.spaces = state.spaces }
        if hudModel.availableSpaceIndices != availableSpaceIndices {
            hudModel.availableSpaceIndices = availableSpaceIndices
        }
        if canRevealNavigation != nil { installMouseMonitors() }
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved(to: NSEvent.mouseLocation)
            return event
        }
        updateHoverFrame()
    }

    private func updateHoverFrame() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
            windowCount: hudModel.displayedItemCount,
            showsDeveloperControls: hudModel.developerControlsEnabled)
        let width = max(120, (screen.auxiliaryTopRightArea?.minX ?? 0) - (screen.auxiliaryTopLeftArea?.maxX ?? 0))
        hoverFrame = CGRect(x: geometry.contentFrame.midX - width / 2,
                            y: geometry.contentFrame.maxY - 4, width: width,
                            height: screen.frame.maxY - geometry.contentFrame.maxY + 4)
    }

    func pointerMoved(to point: CGPoint) {
        let insideTrigger = hoverFrame?.contains(point) == true
        let insideBar = hud?.isVisible == true && hudModel.warning == nil && contentFrame?.contains(point) == true
        let inside = insideTrigger || insideBar
        guard inside != pointerKeepsHUDVisible else { return }
        guard inside else {
            pointerKeepsHUDVisible = false
            if hud?.isVisible == true { scheduleDismiss(after: .milliseconds(450)) }
            return
        }
        guard NSEvent.pressedMouseButtons == 0, canRevealNavigation?() == true else { return }
        pointerKeepsHUDVisible = true
        hudModel.warning = nil
        presentHUD(dismissAfter: .milliseconds(1_500))
    }

    private func presentHUD(dismissAfter: Duration) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let hud = hudPanel()
        hud.ignoresMouseEvents = hudModel.warning != nil
        guard let container = hud.contentView as? HUDContainerView else { return }
        hudModel.reduceMotion = reduceMotion()
        let warningHeight = hudModel.warning.map { message in
            let textWidth = max(1, min(580, screen.visibleFrame.width - 32) - 64)
            return ceil((message as NSString).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 12)]).height) + 36
        }
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
            windowCount: hudModel.displayedItemCount, warningHeight: warningHeight,
            showsDeveloperControls: hudModel.developerControlsEnabled)
        contentFrame = geometry.contentFrame
        updateHoverFrame()
        hudModel.attachedToNotch = geometry.attachedToNotch
        container.attachedToNotch = geometry.attachedToNotch
        hud.setFrame(geometry.panelFrame, display: true)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        let wasVisible = hud.isVisible
        let wasExiting = hudIsExiting
        hudGeneration &+= 1
        hudIsExiting = false
        dismissTask?.cancel()
        if !wasVisible {
            container.setHidden(
                reduceMotion: hudModel.reduceMotion,
                configuration: hudModel.interfaceAnimationConfiguration
            )
            hud.orderFrontRegardless()
        }
        if !wasVisible || wasExiting {
            let configuration = hudModel.interfaceAnimationConfiguration
            container.transition(
                visible: true,
                reduceMotion: hudModel.reduceMotion,
                duration: configuration.hudEnterDuration * animationDurationMultiplier,
                configuration: configuration
            )
        }
        if !pointerKeepsHUDVisible && !dropTargetKeepsHUDVisible { scheduleDismiss(after: dismissAfter) }
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        let generation = hudGeneration
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.beginHUDDismiss(generation: generation) else { return }
            do {
                try await Task.sleep(for: .seconds(
                    self.hudModel.interfaceAnimationConfiguration.hudExitDuration
                        * self.animationDurationMultiplier
                ))
            } catch { return }
            guard !Task.isCancelled else { return }
            _ = self.completeHUDDismiss(generation: generation)
        }
    }

    private func previewHUDAnimation() {
        guard hud?.isVisible == true,
              let container = hud?.contentView as? HUDContainerView else { return }
        let configuration = hudModel.interfaceAnimationConfiguration
        container.setHidden(reduceMotion: hudModel.reduceMotion, configuration: configuration)
        DispatchQueue.main.async { [weak self, weak container] in
            guard let self, let container, self.hud?.isVisible == true else { return }
            container.transition(
                visible: true,
                reduceMotion: self.hudModel.reduceMotion,
                duration: configuration.hudEnterDuration * self.animationDurationMultiplier,
                configuration: configuration
            )
        }
    }

    @discardableResult
    func beginHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, !hudIsExiting, !pointerKeepsHUDVisible,
              !dropTargetKeepsHUDVisible,
              let container = hud?.contentView as? HUDContainerView else { return false }
        hudIsExiting = true
        let configuration = hudModel.interfaceAnimationConfiguration
        container.transition(
            visible: false,
            reduceMotion: reduceMotion(),
            duration: configuration.hudExitDuration * animationDurationMultiplier,
            configuration: configuration
        )
        return true
    }

    @discardableResult
    func completeHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, hudIsExiting else { return false }
        hud?.orderOut(nil)
        hudIsExiting = false
        hudModel.showingSpaces = false
        return true
    }

    func hide() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        hoverFrame = nil
        contentFrame = nil
        pointerKeepsHUDVisible = false
        dropTargetKeepsHUDVisible = false
        hudModel.showingSpaces = false
        hudModel.endDraggingWindow()
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
    static let padding = NavigationHUDGeometry.padding
    let animatedView = NSView()
    let hostingView: NSView
    var attachedToNotch = false
    private var motionConfiguration = InterfaceAnimationConfiguration.default
    var hiddenTravel: CGFloat {
        CGFloat(attachedToNotch
            ? motionConfiguration.attachedHUDTravel
            : motionConfiguration.floatingHUDTravel)
    }

    init(model: NavigationHUDModel) {
        hostingView = NavigationHostingView(rootView: NavigationHUD(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        // The top edge is flush with the physical camera housing on notched displays.
        // Clip translation there so content never travels over the menu bar.
        layer?.masksToBounds = true
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
        animatedView.frame = CGRect(x: Self.padding, y: Self.padding,
                                    width: max(0, bounds.width - Self.padding * 2),
                                    height: max(0, bounds.height - Self.padding * (attachedToNotch ? 1 : 2)))
        hostingView.frame = animatedView.bounds
        CATransaction.commit()
    }

    private func hiddenTransform(reduceMotion: Bool) -> CATransform3D {
        guard !reduceMotion else { return CATransform3DIdentity }
        let scale = CGFloat(motionConfiguration.hiddenHUDScale)
        let size = animatedView.bounds.size
        // AppKit owns this backing layer's bottom-left anchor and resets custom anchors
        // at commit. Compensate the scale in the transform to keep its top center fixed.
        let x = size.width * (1 - scale) / 2
        let y = size.height * (1 - scale) + hiddenTravel
        return CATransform3DScale(CATransform3DMakeTranslation(x, y, 0), scale, scale, 1)
    }

    func setHidden(
        reduceMotion: Bool,
        configuration: InterfaceAnimationConfiguration = .default
    ) {
        guard let layer = animatedView.layer else { return }
        motionConfiguration = configuration
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = hiddenTransform(reduceMotion: reduceMotion)
        CATransaction.commit()
    }

    func transition(
        visible: Bool,
        reduceMotion: Bool,
        duration: Double,
        configuration: InterfaceAnimationConfiguration = .default
    ) {
        guard let layer = animatedView.layer else { return }
        motionConfiguration = configuration
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
        fade.timingFunction = RibbonAnimationCurve.easeOut.mediaTimingFunction
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

private final class NavigationHostingView<Content: View>: NSHostingView<Content> {
    // The HUD receives the first click while the managed app remains the key application.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayPanel: NSPanel {
    init(level: NSWindow.Level = .floating) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        self.level = level
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
    static let defaultColor = NSColor(srgbRed: 0.44, green: 0.85, blue: 0.71, alpha: 0.95)

    var strokeColor = defaultColor {
        didSet { if oldValue != strokeColor { needsDisplay = true } }
    }

    var cornerRadius: CGFloat? {
        didSet { if oldValue != cornerRadius { needsDisplay = true } }
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
        strokeColor.setStroke()
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

enum WindowDropIndicatorEdge: Equatable {
    case leading
    case trailing
}

@MainActor
final class NavigationHUDModel: ObservableObject {
    static let defaultAppBarColor = NSColor.systemMint

    @Published var space = 1
    @Published var windows: [WindowRecord] = []
    @Published var focusedID: String?
    @Published var warning: String?
    @Published var reduceMotion = false
    @Published var attachedToNotch = false
    @Published var spaces: [SpaceState] = []
    @Published var availableSpaceIndices: [Int] = []
    @Published var showingSpaces = false
    @Published var appBarColor = defaultAppBarColor
    @Published var developerControlsEnabled = false
    @Published private(set) var animatesFocusIndicator = false
    @Published private(set) var animationConfiguration = RibbonAnimationConfiguration.default
    @Published private(set) var interfaceAnimationConfiguration = InterfaceAnimationConfiguration.default
    @Published private(set) var draggedWindowID: String?
    @Published private(set) var dropTargetID: String?
    var onFocusWindow: ((String) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String) -> Void)?
    var onReorderWindow: ((String, Int) -> Void)?
    var onAnimationConfigurationChange: ((RibbonAnimationConfiguration) -> Void)?
    var onInterfaceAnimationConfigurationChange: ((InterfaceAnimationConfiguration) -> Void)?
    var onDropTargetChange: ((Bool) -> Void)?
    var onContentChange: (() -> Void)?
    var onPreviewHUDAnimation: (() -> Void)?
    private var lastFocusChange: TimeInterval?

    var displayedItemCount: Int { showingSpaces ? availableSpaceIndices.count : windows.count }
    var focusedAppName: String { windows.first { $0.id == focusedID }?.appName ?? "No windows" }
    var dropDescription: String? {
        guard let dropTargetID,
              let edge = dropIndicatorEdge(for: dropTargetID),
              let appName = windows.first(where: { $0.id == dropTargetID })?.appName else { return nil }
        return "Move \(edge == .leading ? "before" : "after") \(appName)"
    }

    func setFocusedID(
        _ id: String?,
        animate: Bool,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard focusedID != id else { return }
        if animate {
            animatesFocusIndicator = lastFocusChange.map {
                timestamp - $0 >= animationConfiguration.duration
            } ?? true
            lastFocusChange = timestamp
        } else {
            animatesFocusIndicator = false
            lastFocusChange = nil
        }
        focusedID = id
    }

    func setAnimationConfiguration(_ configuration: RibbonAnimationConfiguration) {
        guard animationConfiguration != configuration else { return }
        animationConfiguration = configuration
    }

    func setInterfaceAnimationConfiguration(_ configuration: InterfaceAnimationConfiguration) {
        guard interfaceAnimationConfiguration != configuration else { return }
        interfaceAnimationConfiguration = configuration
    }

    func setAnimationDuration(_ duration: Double) {
        changeAnimationConfiguration(duration: duration)
    }

    func setAnimationCurve(_ curve: RibbonAnimationCurve) {
        changeAnimationConfiguration(curve: curve)
    }

    func setGestureTracking(_ tracking: Double) {
        changeAnimationConfiguration(tracking: tracking)
    }

    func setGestureCommitProgress(_ commitProgress: Double) {
        changeAnimationConfiguration(commitProgress: commitProgress)
    }

    func setGestureFlickDistance(_ flickDistance: Double) {
        changeAnimationConfiguration(flickDistance: flickDistance)
    }

    func setGestureFlickVelocity(_ flickVelocity: Double) {
        changeAnimationConfiguration(flickVelocity: flickVelocity)
    }

    func setGestureEdgeResistance(_ edgeResistance: Double) {
        changeAnimationConfiguration(edgeResistance: edgeResistance)
    }

    func resetAnimationConfiguration() {
        setAnimationConfiguration(RibbonAnimationConfiguration.default)
        onAnimationConfigurationChange?(animationConfiguration)
    }

    func resetAllMotionConfiguration() {
        resetAnimationConfiguration()
        setInterfaceAnimationConfiguration(.default)
        onInterfaceAnimationConfigurationChange?(interfaceAnimationConfiguration)
    }

    func previewHUDAnimation() {
        onPreviewHUDAnimation?()
    }

    func setHUDEnterDuration(_ value: Double) {
        changeInterfaceAnimationConfiguration(hudEnterDuration: value)
    }

    func setHUDExitDuration(_ value: Double) {
        changeInterfaceAnimationConfiguration(hudExitDuration: value)
    }

    func setAttachedHUDTravel(_ value: Double) {
        changeInterfaceAnimationConfiguration(attachedHUDTravel: value)
    }

    func setFloatingHUDTravel(_ value: Double) {
        changeInterfaceAnimationConfiguration(floatingHUDTravel: value)
    }

    func setHiddenHUDScale(_ value: Double) {
        changeInterfaceAnimationConfiguration(hiddenHUDScale: value)
    }

    func setFeedbackDuration(_ value: Double) {
        changeInterfaceAnimationConfiguration(feedbackDuration: value)
    }

    func setPressedScale(_ value: Double) {
        changeInterfaceAnimationConfiguration(pressedScale: value)
    }

    func setFocusRevealDuration(_ value: Double) {
        changeInterfaceAnimationConfiguration(focusRevealDuration: value)
    }

    func setFocusRevealOpacity(_ value: Double) {
        changeInterfaceAnimationConfiguration(focusRevealOpacity: value)
    }

    private func changeInterfaceAnimationConfiguration(
        hudEnterDuration: Double? = nil,
        hudExitDuration: Double? = nil,
        attachedHUDTravel: Double? = nil,
        floatingHUDTravel: Double? = nil,
        hiddenHUDScale: Double? = nil,
        feedbackDuration: Double? = nil,
        pressedScale: Double? = nil,
        focusRevealDuration: Double? = nil,
        focusRevealOpacity: Double? = nil
    ) {
        let current = interfaceAnimationConfiguration
        let configuration = InterfaceAnimationConfiguration(
            hudEnterDuration: hudEnterDuration ?? current.hudEnterDuration,
            hudExitDuration: hudExitDuration ?? current.hudExitDuration,
            attachedHUDTravel: attachedHUDTravel ?? current.attachedHUDTravel,
            floatingHUDTravel: floatingHUDTravel ?? current.floatingHUDTravel,
            hiddenHUDScale: hiddenHUDScale ?? current.hiddenHUDScale,
            feedbackDuration: feedbackDuration ?? current.feedbackDuration,
            pressedScale: pressedScale ?? current.pressedScale,
            focusRevealDuration: focusRevealDuration ?? current.focusRevealDuration,
            focusRevealOpacity: focusRevealOpacity ?? current.focusRevealOpacity
        )
        guard configuration != current else { return }
        interfaceAnimationConfiguration = configuration
        onInterfaceAnimationConfigurationChange?(configuration)
    }

    private func changeAnimationConfiguration(
        duration: Double? = nil,
        curve: RibbonAnimationCurve? = nil,
        tracking: Double? = nil,
        commitProgress: Double? = nil,
        flickDistance: Double? = nil,
        flickVelocity: Double? = nil,
        edgeResistance: Double? = nil
    ) {
        let configuration = RibbonAnimationConfiguration(
            duration: duration ?? animationConfiguration.duration,
            curve: curve ?? animationConfiguration.curve,
            tracking: tracking ?? animationConfiguration.tracking,
            commitProgress: commitProgress ?? animationConfiguration.commitProgress,
            flickDistance: flickDistance ?? animationConfiguration.flickDistance,
            flickVelocity: flickVelocity ?? animationConfiguration.flickVelocity,
            edgeResistance: edgeResistance ?? animationConfiguration.edgeResistance
        )
        guard configuration != animationConfiguration else { return }
        animationConfiguration = configuration
        onAnimationConfigurationChange?(configuration)
    }

    func toggleSpaces() {
        showingSpaces.toggle()
        onContentChange?()
    }

    func selectWindow(id: String) {
        guard windows.contains(where: { $0.id == id }) else { return }
        onFocusWindow?(id)
        onContentChange?()
    }

    func selectSpace(index: Int) {
        guard availableSpaceIndices.contains(index) else { return }
        showingSpaces = false
        onSelectSpace?(index)
        onContentChange?()
    }

    func shareDestinations(for windowID: String) -> [Int] {
        guard windows.contains(where: { $0.id == windowID }) else { return [] }
        return spaces.indices.filter { !spaces[$0].windowIDs.contains(windowID) }
    }

    func canRemoveFromCurrentSpace(windowID: String) -> Bool {
        spaces.indices.contains(space - 1) &&
            spaces[space - 1].windowIDs.contains(windowID) &&
            spaces.filter { $0.windowIDs.contains(windowID) }.count > 1
    }

    func shareWindow(id: String, withSpace index: Int) {
        guard shareDestinations(for: id).contains(index) else { return }
        onShareWindow?(id, index)
        onContentChange?()
    }

    func removeWindowFromCurrentSpace(id: String) {
        guard canRemoveFromCurrentSpace(windowID: id) else { return }
        onRemoveWindow?(id)
        onContentChange?()
    }

    @discardableResult
    func beginDraggingWindow(id: String) -> Bool {
        guard windows.count > 1, windows.contains(where: { $0.id == id }) else { return false }
        draggedWindowID = id
        setDropTarget(id: nil, isTargeted: false)
        return true
    }

    func setDropTarget(id: String?, isTargeted: Bool) {
        let target: String?
        if isTargeted, let id, id != draggedWindowID, windows.contains(where: { $0.id == id }) {
            target = id
        } else {
            guard id == nil || id == dropTargetID else { return }
            target = nil
        }
        guard target != dropTargetID else { return }
        dropTargetID = target
        onDropTargetChange?(target != nil)
    }

    func dropIndicatorEdge(for windowID: String) -> WindowDropIndicatorEdge? {
        guard dropTargetID == windowID,
              let draggedWindowID,
              let source = windows.firstIndex(where: { $0.id == draggedWindowID }),
              let destination = windows.firstIndex(where: { $0.id == windowID }),
              source != destination else { return nil }
        return source < destination ? .trailing : .leading
    }

    func endDraggingWindow() {
        setDropTarget(id: nil, isTargeted: false)
        draggedWindowID = nil
    }

    @discardableResult
    func reorderWindow(id: String, onto destinationID: String) -> Bool {
        guard id != destinationID,
              windows.contains(where: { $0.id == id }),
              let destination = windows.firstIndex(where: { $0.id == destinationID }) else { return false }
        onReorderWindow?(id, destination)
        onContentChange?()
        return true
    }
}

private enum MotionEditorSection: String, CaseIterable, Identifiable {
    case settle = "Settle"
    case gesture = "Gesture"
    case interface = "HUD"

    var id: Self { self }
}

private struct NavigationHUD: View {
    @ObservedObject var model: NavigationHUDModel
    @Namespace private var selection
    @State private var motionEditorSection = MotionEditorSection.settle

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
        .background(model.attachedToNotch ? Color.black : Color(white: 0.075).opacity(0.97), in: shape)
        .overlay { if !model.attachedToNotch { shape.stroke(.white.opacity(0.12), lineWidth: 1) } }
        .environment(\.colorScheme, .dark)
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: model.attachedToNotch ? 0 : 15,
                               bottomLeadingRadius: 15, bottomTrailingRadius: 15,
                               topTrailingRadius: model.attachedToNotch ? 0 : 15)
    }

    private var navigation: some View {
        let appBarColor = Color(nsColor: model.appBarColor)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: model.toggleSpaces) {
                    Text("\(model.space, format: .number.precision(.integerLength(2)))")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(model.showingSpaces ? 1 : 0.65))
                        .frame(width: 22, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ResponsiveButtonStyle(
                    reduceMotion: model.reduceMotion,
                    configuration: model.interfaceAnimationConfiguration
                ))
                .help(model.showingSpaces ? "Show windows" : "Choose a space")
                .accessibilityLabel(model.showingSpaces ? "Show windows in Space \(model.space)" : "Choose a space, currently Space \(model.space)")
                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 18)
                if model.showingSpaces {
                    spacePicker
                } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(model.windows) { window in
                                Button { model.selectWindow(id: window.id) } label: {
                                    AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
                                    .padding(4)
                                    .background {
                                        ZStack {
                                            if window.id == model.focusedID {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(appBarColor.opacity(0.25))
                                                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(appBarColor.opacity(0.8), lineWidth: 1) }
                                                    .matchedGeometryEffect(id: "selection", in: selection)
                                                    .transition(.identity)
                                            }
                                            if window.id == model.dropTargetID {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(appBarColor.opacity(0.12))
                                                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(appBarColor.opacity(0.8), lineWidth: 1.5) }
                                            }
                                        }
                                    }
                                    .overlay {
                                        if let edge = model.dropIndicatorEdge(for: window.id) {
                                            HStack(spacing: 0) {
                                                if edge == .trailing { Spacer(minLength: 0) }
                                                Capsule().fill(appBarColor).frame(width: 3, height: 28)
                                                    .shadow(color: appBarColor.opacity(0.8), radius: 3)
                                                if edge == .leading { Spacer(minLength: 0) }
                                            }
                                            .offset(x: edge == .leading ? -3 : 3)
                                        }
                                    }
                                }
                                .buttonStyle(ResponsiveButtonStyle(
                                    reduceMotion: model.reduceMotion,
                                    configuration: model.interfaceAnimationConfiguration
                                ))
                                .help(window.title.isEmpty ? window.appName : "\(window.appName): \(window.title)")
                                .accessibilityLabel("Focus \(window.appName)\(window.title.isEmpty ? "" : ", \(window.title)")")
                                .contextMenu {
                                    let destinations = model.shareDestinations(for: window.id)
                                    if !destinations.isEmpty {
                                        Menu("Share with") {
                                            ForEach(destinations, id: \.self) { index in
                                                Button("Space \(index + 1)") {
                                                    model.shareWindow(id: window.id, withSpace: index)
                                                }
                                            }
                                        }
                                    }
                                    if model.canRemoveFromCurrentSpace(windowID: window.id) {
                                        Button("Remove from Space \(model.space)") {
                                            model.removeWindowFromCurrentSpace(id: window.id)
                                        }
                                    }
                                }
                                .onDrag {
                                    _ = model.beginDraggingWindow(id: window.id)
                                    return NSItemProvider(object: window.id as NSString)
                                } preview: {
                                    HStack(spacing: 7) {
                                        AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
                                        Text(window.appName).font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(.white)
                                    .background(Color(white: 0.1).opacity(0.96), in: RoundedRectangle(cornerRadius: 11))
                                    .overlay { RoundedRectangle(cornerRadius: 11).stroke(appBarColor.opacity(0.8), lineWidth: 1) }
                                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                                    .environment(\.colorScheme, .dark)
                                }
                                .dropDestination(for: String.self) { draggedIDs, _ in
                                    defer { model.endDraggingWindow() }
                                    guard let draggedID = draggedIDs.first else { return false }
                                    return model.reorderWindow(id: draggedID, onto: window.id)
                                } isTargeted: { isTargeted in
                                    model.setDropTarget(id: window.id, isTargeted: isTargeted)
                                }
                                .id(window.id)
                            }
                        }
                        .frame(minWidth: 1)
                        .animation(
                            model.reduceMotion || !model.animatesFocusIndicator
                                ? nil
                                : model.animationConfiguration.curve.animation(
                                    duration: model.animationConfiguration.duration
                                ),
                            value: model.focusedID
                        )
                    }
                    .onChange(of: model.focusedID, initial: true) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: model.windows.map(\.id)) { _, _ in
                        if let id = model.focusedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(height: 32)
                }
            }
            if !model.showingSpaces {
                Text(model.dropDescription ?? model.focusedAppName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(model.dropDescription == nil ? Color.white.opacity(0.8) : appBarColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
                .animation(
                    model.reduceMotion || model.dropDescription == nil && !model.animatesFocusIndicator
                        ? nil
                        : RibbonAnimationCurve.ease.animation(
                            duration: model.interfaceAnimationConfiguration.feedbackDuration
                        ),
                    value: model.dropDescription ?? model.focusedAppName
                )
            }
            if model.developerControlsEnabled {
                Divider().overlay(.white.opacity(0.12))
                animationControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var animationControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("Motion controls", selection: $motionEditorSection) {
                    ForEach(MotionEditorSection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Spacer()
                if motionEditorSection == .interface {
                    Button(action: model.previewHUDAnimation) {
                        Label("Replay", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(ResponsiveButtonStyle(
                        reduceMotion: model.reduceMotion,
                        configuration: model.interfaceAnimationConfiguration
                    ))
                    .foregroundStyle(.white.opacity(0.75))
                    .help("Replay the app bar entrance")
                }
                Button(action: model.resetAllMotionConfiguration) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(ResponsiveButtonStyle(
                    reduceMotion: model.reduceMotion,
                    configuration: model.interfaceAnimationConfiguration
                ))
                .foregroundStyle(.white.opacity(0.7))
                .help("Reset all motion controls")
            }

            Group {
                switch motionEditorSection {
                case .settle: settleControls
                case .gesture: gestureControls
                case .interface: interfaceControls
                }
            }
            .frame(maxHeight: .infinity)
        }
        .controlSize(.small)
        .frame(height: 220)
    }

    private var settleControls: some View {
        let configuration = model.animationConfiguration
        let curve = configuration.curve
        return HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 5) {
                HStack {
                    Text("Easing curve")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Menu {
                        ForEach(RibbonAnimationPreset.allCases) { preset in
                            Button(preset.title) { model.setAnimationCurve(preset.curve) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(RibbonAnimationPreset.matching(curve)?.title ?? "Custom")
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                RibbonCurveEditor(
                    curve: Binding(
                        get: { model.animationConfiguration.curve },
                        set: { model.setAnimationCurve($0) }
                    ),
                    color: Color(nsColor: model.appBarColor)
                )
                HStack {
                    Text("P1  \(curve.x1, format: .number.precision(.fractionLength(2))), \(curve.y1, format: .number.precision(.fractionLength(2)))")
                    Spacer()
                    Text("P2  \(curve.x2, format: .number.precision(.fractionLength(2))), \(curve.y2, format: .number.precision(.fractionLength(2)))")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            }
            .frame(width: 270)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 142)

            VStack(spacing: 8) {
                HStack {
                    Text("Timeline")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text("\(Int((configuration.duration * 1_000).rounded())) ms")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Slider(
                    value: Binding(
                        get: { model.animationConfiguration.duration },
                        set: { model.setAnimationDuration($0) }
                    ),
                    in: RibbonAnimationConfiguration.durationRange,
                    step: 0.01
                )
                .accessibilityLabel("Switch duration")
                MotionTimeline(
                    duration: configuration.duration,
                    curve: curve,
                    color: Color(nsColor: model.appBarColor),
                    reduceMotion: model.reduceMotion
                )
                HStack {
                    Text("Start")
                    Spacer()
                    Text("Finish")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var gestureControls: some View {
        let configuration = model.animationConfiguration
        return LazyVGrid(columns: motionControlColumns, spacing: 14) {
            MotionTuningSlider(
                title: "Tracking gain",
                value: Binding(
                    get: { model.animationConfiguration.tracking },
                    set: { model.setGestureTracking($0) }
                ),
                range: RibbonAnimationConfiguration.trackingRange,
                step: 0.1,
                valueText: "×\(configuration.tracking.formatted(.number.precision(.fractionLength(1))))"
            )
            MotionTuningSlider(
                title: "Commit point",
                value: Binding(
                    get: { model.animationConfiguration.commitProgress },
                    set: { model.setGestureCommitProgress($0) }
                ),
                range: RibbonAnimationConfiguration.commitProgressRange,
                step: 0.01,
                valueText: configuration.commitProgress.formatted(.percent.precision(.fractionLength(0)))
            )
            MotionTuningSlider(
                title: "Flick distance",
                value: Binding(
                    get: { model.animationConfiguration.flickDistance },
                    set: { model.setGestureFlickDistance($0) }
                ),
                range: RibbonAnimationConfiguration.flickDistanceRange,
                step: 0.005,
                valueText: configuration.flickDistance.formatted(.number.precision(.fractionLength(3)))
            )
            MotionTuningSlider(
                title: "Flick speed",
                value: Binding(
                    get: { model.animationConfiguration.flickVelocity },
                    set: { model.setGestureFlickVelocity($0) }
                ),
                range: RibbonAnimationConfiguration.flickVelocityRange,
                step: 0.05,
                valueText: configuration.flickVelocity.formatted(.number.precision(.fractionLength(2)))
            )
            MotionTuningSlider(
                title: "Edge resistance",
                value: Binding(
                    get: { model.animationConfiguration.edgeResistance },
                    set: { model.setGestureEdgeResistance($0) }
                ),
                range: RibbonAnimationConfiguration.edgeResistanceRange,
                step: 5,
                valueText: "\(Int(configuration.edgeResistance.rounded())) pt"
            )
        }
    }

    private var interfaceControls: some View {
        return LazyVGrid(columns: motionControlColumns, spacing: 12) {
            interfaceSlider("Enter duration", value: Binding(
                get: { model.interfaceAnimationConfiguration.hudEnterDuration },
                set: { model.setHUDEnterDuration($0) }
            ),
                            range: InterfaceAnimationConfiguration.durationRange,
                            step: 0.01, unit: "ms")
            interfaceSlider("Exit duration", value: Binding(
                get: { model.interfaceAnimationConfiguration.hudExitDuration },
                set: { model.setHUDExitDuration($0) }
            ),
                            range: InterfaceAnimationConfiguration.durationRange,
                            step: 0.01, unit: "ms")
            interfaceSlider("Notch travel", value: Binding(
                get: { model.interfaceAnimationConfiguration.attachedHUDTravel },
                set: { model.setAttachedHUDTravel($0) }
            ),
                            range: InterfaceAnimationConfiguration.travelRange,
                            step: 1, unit: "pt")
            interfaceSlider("Floating travel", value: Binding(
                get: { model.interfaceAnimationConfiguration.floatingHUDTravel },
                set: { model.setFloatingHUDTravel($0) }
            ),
                            range: InterfaceAnimationConfiguration.travelRange,
                            step: 1, unit: "pt")
            interfaceSlider("Hidden scale", value: Binding(
                get: { model.interfaceAnimationConfiguration.hiddenHUDScale },
                set: { model.setHiddenHUDScale($0) }
            ),
                            range: InterfaceAnimationConfiguration.scaleRange,
                            step: 0.005)
            interfaceSlider("State fade", value: Binding(
                get: { model.interfaceAnimationConfiguration.feedbackDuration },
                set: { model.setFeedbackDuration($0) }
            ),
                            range: InterfaceAnimationConfiguration.durationRange,
                            step: 0.01, unit: "ms")
            interfaceSlider("Pressed scale", value: Binding(
                get: { model.interfaceAnimationConfiguration.pressedScale },
                set: { model.setPressedScale($0) }
            ),
                            range: InterfaceAnimationConfiguration.scaleRange,
                            step: 0.005)
            interfaceSlider("Focus flash", value: Binding(
                get: { model.interfaceAnimationConfiguration.focusRevealDuration },
                set: { model.setFocusRevealDuration($0) }
            ),
                            range: InterfaceAnimationConfiguration.durationRange,
                            step: 0.01, unit: "ms")
            interfaceSlider("Focus opacity", value: Binding(
                get: { model.interfaceAnimationConfiguration.focusRevealOpacity },
                set: { model.setFocusRevealOpacity($0) }
            ),
                            range: InterfaceAnimationConfiguration.opacityRange,
                            step: 0.01)
        }
    }

    private var motionControlColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())]
    }

    private func interfaceSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String? = nil
    ) -> some View {
        let current = value.wrappedValue
        let valueText = unit == "ms"
            ? "\(Int((current * 1_000).rounded())) ms"
            : unit.map { "\(Int(current.rounded())) \($0)" }
                ?? current.formatted(.number.precision(.fractionLength(2)))
        return MotionTuningSlider(
            title: title,
            value: value,
            range: range,
            step: step,
            valueText: valueText
        )
    }

    private var spacePicker: some View {
        let appBarColor = Color(nsColor: model.appBarColor)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.availableSpaceIndices, id: \.self) { index in
                    Button { model.selectSpace(index: index) } label: {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(index + 1 == model.space ? 1 : 0.7))
                            .frame(width: 32, height: 32)
                            .background(index + 1 == model.space ? appBarColor.opacity(0.25) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ResponsiveButtonStyle(
                        reduceMotion: model.reduceMotion,
                        configuration: model.interfaceAnimationConfiguration
                    ))
                    .accessibilityLabel("Go to space \(index + 1)")
                }
            }
        }
        .frame(height: 32)
    }
}

private struct RibbonCurveEditor: View {
    @Binding var curve: RibbonAnimationCurve
    let color: Color
    @State private var selectedHandle: Int?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let start = point(x: 0, y: 0, in: size)
            let end = point(x: 1, y: 1, in: size)
            let first = point(x: curve.x1, y: curve.y1, in: size)
            let second = point(x: curve.x2, y: curve.y2, in: size)
            ZStack {
                Canvas { context, size in
                    var grid = Path()
                    for fraction in [0.25, 0.5, 0.75] {
                        grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                        grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                        grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    }
                    context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

                    var handles = Path()
                    handles.move(to: start)
                    handles.addLine(to: first)
                    handles.move(to: end)
                    handles.addLine(to: second)
                    context.stroke(handles, with: .color(.white.opacity(0.3)), lineWidth: 1)

                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: first, control2: second)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                Circle().fill(color).frame(width: 10, height: 10).position(first)
                Circle().fill(color).frame(width: 10, height: 10).position(second)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in updateCurve(location: value.location, size: size,
                                                          first: first, second: second) }
                        .onEnded { _ in selectedHandle = nil })
            }
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12), lineWidth: 1) }
        }
        .frame(height: 86)
        .accessibilityElement()
        .accessibilityLabel("Cubic Bezier easing curve")
        .accessibilityValue(curve.diagnosticDescription)
    }

    private func point(x: Double, y: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * (1.5 - y) / 2)
    }

    private func updateCurve(location: CGPoint, size: CGSize, first: CGPoint, second: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        if selectedHandle == nil {
            let firstDistance = hypot(location.x - first.x, location.y - first.y)
            let secondDistance = hypot(location.x - second.x, location.y - second.y)
            selectedHandle = firstDistance <= secondDistance ? 1 : 2
        }
        let x = Double(location.x / size.width)
        let y = Double(1.5 - location.y / size.height * 2)
        if selectedHandle == 1 {
            curve = RibbonAnimationCurve(x1: x, y1: y, x2: curve.x2, y2: curve.y2)
        } else {
            curve = RibbonAnimationCurve(x1: curve.x1, y1: curve.y1, x2: x, y2: y)
        }
    }
}

private struct MotionTimeline: View {
    let duration: Double
    let curve: RibbonAnimationCurve
    let color: Color
    let reduceMotion: Bool
    @State private var previewAtEnd = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.8))
            .help("Preview timing")
            .accessibilityLabel("Preview timing")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 3)
                    HStack {
                        ForEach(0 ..< 5) { tick in
                            Circle().fill(.white.opacity(0.3)).frame(width: 3, height: 3)
                            if tick < 4 { Spacer() }
                        }
                    }
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .offset(x: previewAtEnd ? max(0, geometry.size.width - 12) : 0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 20)
        }
    }

    private func play() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { previewAtEnd = false }
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : curve.animation(duration: duration)) { previewAtEnd = true }
        }
    }
}

private struct MotionTuningSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                Spacer(minLength: 2)
                Text(valueText).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
        .frame(maxWidth: .infinity)
    }
}

private extension RibbonAnimationCurve {
    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(x1), Float(y1), Float(x2), Float(y2)
        )
    }

    func animation(duration: Double) -> SwiftUI.Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration)
    }
}

private struct ResponsiveButtonStyle: ButtonStyle {
    let reduceMotion: Bool
    let configuration: InterfaceAnimationConfiguration

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion
                    ? self.configuration.pressedScale
                    : 1
            )
            .animation(
                reduceMotion ? nil : RibbonAnimationCurve.ease.animation(
                    duration: self.configuration.feedbackDuration
                ),
                value: configuration.isPressed
            )
    }
}
