import AppKit
import SwiftUI
import QuartzCore
import StagehandCore
import StagehandPlatform

struct InterfaceAnimationConfiguration: Equatable {
    static let `default` = Self(
        hudEnterDuration: 0.14,
        hudExitDuration: 0.26,
        attachedHUDTravel: 10,
        floatingHUDTravel: 6,
        hiddenHUDScale: 0.98,
        feedbackDuration: 0.08,
        pressedScale: 0.9,
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
    /// Navigation keeps the panel at the widest bar's frame, so a new window count, such
    /// as every switch between Spaces, only lays the bar out again inside it. Resizing the
    /// panel is a synchronous WindowServer round trip: 150-900 ms stalls under load on
    /// 2026-10-26, with a fifth of that spent in Stagehand.
    let panelFrame: CGRect

    /// The bar inside the panel, in the panel's coordinates.
    var contentInPanel: CGRect {
        contentFrame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
    }

    static func layout(screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
                       auxiliaryLeft: CGRect?, auxiliaryRight: CGRect?, windowCount: Int,
                       warningHeight: CGFloat? = nil) -> Self {
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
        let maximumWidth: CGFloat = warningHeight != nil ? 580 : 520
        let limit = max(1, min(maximumWidth, visibleFrame.width - 32))
        let navigationWidth = 60 + CGFloat(max(1, windowCount)) * 36
        let desiredWidth = warningHeight == nil ? navigationWidth : 580
        let height = warningHeight.map { max(72, $0) } ?? 66
        let centerX = notch?.midX ?? screenFrame.midX
        let top = attached ? (notch?.minY ?? visibleFrame.maxY) : min(visibleFrame.maxY, screenFrame.maxY - safeAreaTop) - 6
        func frame(width: CGFloat) -> CGRect {
            let left = min(max(centerX - width / 2, visibleFrame.minX + 16), visibleFrame.maxX - 16 - width)
            return CGRect(x: left, y: top - height, width: width, height: height)
        }
        let contentFrame = frame(width: min(limit, desiredWidth))
        // Centered and clamped the same way, a narrower bar lies within the widest one.
        let padded = (warningHeight == nil ? frame(width: limit) : contentFrame)
            .insetBy(dx: -padding, dy: -padding)
        return Self(contentFrame: contentFrame, attachedToNotch: attached,
                    panelFrame: CGRect(x: padded.minX, y: padded.minY, width: padded.width,
                                       height: padded.height - (attached ? padding : 0)))
    }
}

@MainActor
final class NavigationOverlays {
    private(set) var borderPanels: [OverlayPanel] = []
    private(set) var hud: OverlayPanel?
    private var hudGeneration: UInt64 = 0
    private var hudIsExiting = false
    private var dismissTask: Task<Void, Never>?
    let hudModel = NavigationHUDModel()
    private let shortcutHints: ShortcutHintsRibbon
    var onFocusWindow: ((String, Int?) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String, Int?) -> Void)?
    var navigationDisplays: (() -> [NavigationDisplay])?
    var canRevealNavigation: (() -> Bool)?
    var pointerCarriesDrop: (() -> Bool)?
    var onPointerMoved: (() -> Void)? {
        didSet { if onPointerMoved != nil { installMouseMonitors() } }
    }
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// The pointer over one of these reveals the bar on that display.
    private var hoverFrames: [(frame: CGRect, display: NavigationDisplay)] = []
    private var contentFrame: CGRect?
    /// The display the bar was last presented on, and the workspace it last published.
    private var presentedDisplay: NavigationDisplay?
    private var navigationState: (state: WorkspaceState, windows: [WindowRecord])?
    private var pointerKeepsHUDVisible = false
    private let reduceMotion: () -> Bool
    private let pointerLocation: () -> CGPoint
    private var borderColor = BorderView.defaultColor

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.reduceMotion = reduceMotion
        self.pointerLocation = pointerLocation
        shortcutHints = ShortcutHintsRibbon(reduceMotion: reduceMotion)
        shortcutHints.screen = { [weak self] in self?.screen(of: self?.focusedNavigationDisplay) }
        hudModel.onFocusWindow = { [weak self] id in self?.onFocusWindow?(id, self?.presentedOtherSpaceIndex) }
        hudModel.onSelectSpace = { [weak self] index in self?.onSelectSpace?(index) }
        hudModel.onShareWindow = { [weak self] id, index in self?.onShareWindow?(id, index) }
        hudModel.onRemoveWindow = { [weak self] id in self?.onRemoveWindow?(id, self?.presentedOtherSpaceIndex) }
        hudModel.onContentChange = { [weak self] in
            self?.presentHUD(dismissAfter: .milliseconds(1_500))
        }
    }

    private func borderPanel(at index: Int) -> OverlayPanel {
        if borderPanels.indices.contains(index) { return borderPanels[index] }
        // Stay above clicked normal windows and below floating windows such as picture-in-picture.
        let panel = OverlayPanel(level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1))
        let borderView = BorderView()
        borderView.strokeColor = borderColor
        panel.contentView = borderView
        panel.hasShadow = false
        borderPanels.append(panel)
        return panel
    }

    func setBorderColor(_ color: NSColor) {
        guard !borderColor.isEqual(color) || !hudModel.appBarColor.isEqual(color) else { return }
        borderColor = color
        for panel in borderPanels { (panel.contentView as? BorderView)?.strokeColor = color }
        hudModel.appBarColor = color
    }

    private func hudPanel() -> OverlayPanel {
        if let hud { return hud }
        let panel = OverlayPanel(level: .statusBar)
        panel.contentView = HUDContainerView(model: hudModel)
        panel.hasShadow = false
        // While the panel takes the pointer, its moves reach the local monitor only if the
        // panel accepts them; see the container's tracking area.
        panel.acceptsMouseMovedEvents = true
        hud = panel
        return panel
    }

    func updateBorder(
        frame: CGRect,
        sheet: CGRect? = nil,
        visible: Bool,
        cornerRadius: CGFloat? = nil,
        focusChanged: Bool = false,
        raiseBorder: Bool = false
    ) {
        guard visible, let primary = NSScreen.screens.first else {
            orderOutBorder()
            return
        }
        let radius = BorderView.resolvedCornerRadius(cornerRadius, window: frame)
        let pieces = FocusOutlineGeometry.segments(window: frame, cornerRadius: radius, sheet: sheet)
        let windowOpacity: CGFloat = sheet == nil ? 1 : BorderView.sheetOwnerOpacity
        func appKitFrame(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let panels = pieces.indices.map(borderPanel(at:))
        // Frame changes remain synchronous, including throughout a native live resize.
        // Each is a WindowServer round trip, which queues behind a slow window-list call.
        MainThreadActivity.during("borderWindow setFrame") {
            for (panel, piece) in zip(panels, pieces) {
                let converted = appKitFrame(piece.panel)
                if panel.frame != converted { panel.setFrame(converted, display: false) }
                (panel.contentView as? BorderView)?.showOutline(
                    of: piece.outline, radius: piece.cornerRadius, from: piece.panel,
                    opacity: piece.isSheet ? 1 : windowOpacity)
            }
        }
        let unused = borderPanels.dropFirst(pieces.count).filter(\.isVisible)
        if !unused.isEmpty {
            MainThreadActivity.during("borderWindow orderOut") { unused.forEach { $0.orderOut(nil) } }
        }
        let raised = panels.filter { !$0.isVisible || focusChanged || raiseBorder }
        if !raised.isEmpty {
            // Relative ordering does not reliably raise a panel above another app's
            // window. Front ordering is confined to the border's window level.
            MainThreadActivity.during("borderWindow orderFront") { raised.forEach { $0.orderFrontRegardless() } }
        }
        if focusChanged {
            for layer in panels.compactMap({ $0.contentView?.layer }) { addFocusReveal(to: layer) }
        }
    }

    private func orderOutBorder() {
        let visible = borderPanels.filter(\.isVisible)
        guard !visible.isEmpty else { return }
        MainThreadActivity.during("borderWindow orderOut") { visible.forEach { $0.orderOut(nil) } }
    }

    private func addFocusReveal(to layer: CALayer) {
        let configuration = hudModel.interfaceAnimationConfiguration
        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = layer.animation(forKey: "focusReveal") == nil
            ? configuration.focusRevealOpacity
            : (layer.presentation()?.opacity ?? Float(configuration.focusRevealOpacity))
        reveal.toValue = 1
        reveal.duration = configuration.focusRevealDuration
        reveal.timingFunction = RibbonAnimationCurve.ease.mediaTimingFunction
        layer.add(reveal, forKey: "focusReveal")
    }

    func showNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        presentedDisplay = focusedNavigationDisplay
        MainThreadActivity.during("navigation overlay show") {
            updateNavigation(state: state, windows: windows)
            hudModel.showingSpaces = false
            hudModel.warning = nil
            presentHUD(dismissAfter: .milliseconds(1_500))
        }
    }

    func setShortcutHints(_ bindings: [ShortcutBinding], swipeTip: String?) {
        shortcutHints.setContent(bindings, swipeTip: swipeTip)
    }

    func toggleShortcutHints() {
        shortcutHints.toggle()
    }

    /// Keep hover content current without opening the bar during background reconciliation.
    func updateNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        navigationState = (state, windows)
        if let presented = presentedDisplay {
            presentedDisplay = navigationDisplays?().first { $0.number == presented.number } ?? focusedNavigationDisplay
        }
        // Publishing to the app bar's model re-renders its SwiftUI content synchronously.
        MainThreadActivity.during("hudModel update") { publishNavigation() }
        if canRevealNavigation != nil {
            installMouseMonitors()
            if hoverFrames.map(\.display.number) != navigationDisplays?().map(\.number) { updateHoverFrames() }
        }
    }

    /// The bar shows the space of the display it is on: the focused space, or the space
    /// another display shows while the pointer is over that display's bar.
    private func publishNavigation() {
        guard let navigationState else { return }
        let state = navigationState.state
        let content = NavigationHUDContent(state: state, otherSpaceIndex: presentedOtherSpaceIndex,
                                           display: presentedDisplay?.id)
        let recordsByID = Dictionary(navigationState.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = content.space.windowIDs.compactMap { recordsByID[$0] }
        let tiles = NavigationHUDModel.tiles(of: content.space, records: recordsByID)
        let space = content.spaceIndex + 1
        if hudModel.space != space { hudModel.space = space }
        if hudModel.windows != records { hudModel.windows = records }
        if hudModel.tiles != tiles { hudModel.tiles = tiles }
        hudModel.setFocusedID(content.space.focusedWindowID, animate: hud?.isVisible == true)
        if hudModel.spaces != state.spaces { hudModel.spaces = state.spaces }
        if hudModel.availableSpaceIndices != content.availableSpaceIndices {
            hudModel.availableSpaceIndices = content.availableSpaceIndices
        }
    }

    private var focusedNavigationDisplay: NavigationDisplay? {
        navigationDisplays?().first(where: \.isFocused)
    }

    /// Set while the bar shows a display other than the focused one.
    private var presentedOtherSpaceIndex: Int? {
        presentedDisplay.flatMap { $0.isFocused ? nil : $0.spaceIndex }
    }

    private func screen(of display: NavigationDisplay?) -> NSScreen? {
        display.flatMap { NSScreen.screen(displayNumber: $0.number) } ?? NSScreen.screens.first
    }

    private func installMouseMonitors() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        // No move follows a release until the pointer moves, so a press released over the
        // bar's padding would leave the padding catching the next click.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        updateHoverFrames()
    }

    private func updateHoverFrames() {
        hoverFrames = (navigationDisplays?() ?? []).compactMap { display in
            NSScreen.screen(displayNumber: display.number).map { (hoverFrame(on: $0), display) }
        }
    }

    private func hoverFrame(on screen: NSScreen) -> CGRect {
        let geometry = NavigationHUDGeometry.layout(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeft: screen.auxiliaryTopLeftArea, auxiliaryRight: screen.auxiliaryTopRightArea,
            windowCount: hudModel.displayedItemCount)
        let width = max(120, (screen.auxiliaryTopRightArea?.minX ?? 0) - (screen.auxiliaryTopLeftArea?.maxX ?? 0))
        return CGRect(x: geometry.contentFrame.midX - width / 2,
                      y: geometry.contentFrame.maxY - 4, width: width,
                      height: screen.frame.maxY - geometry.contentFrame.maxY + 4)
    }

    /// A panel that accepts mouse events catches every click in its frame, including the
    /// transparent padding that holds the bar's shadow: on 2026-10-27 a click a few points
    /// beside the bar never reached the app under it. Only the bar itself takes the pointer,
    /// and not while it shows a warning or another app's drag-and-drop passes over it.
    private func hudIgnoresPointer(at point: CGPoint) -> Bool {
        contentFrame?.contains(point) != true || hudModel.warning != nil || pointerCarriesDrop?() == true
    }

    func pointerMoved() {
        onPointerMoved?()
        let point = pointerLocation()
        // A press keeps the panel as it was, so a press on the bar keeps its release,
        // and a drag that started elsewhere is not taken over.
        if let hud, hud.ignoresMouseEvents != hudIgnoresPointer(at: point), NSEvent.pressedMouseButtons == 0 {
            hud.ignoresMouseEvents.toggle()
        }
        let hovered = hoverFrames.first { $0.frame.contains(point) }?.display
        let insideBar = hud?.isVisible == true && hudModel.warning == nil && contentFrame?.contains(point) == true
        let inside = hovered != nil || insideBar
        guard inside != pointerKeepsHUDVisible else { return }
        guard inside else {
            pointerKeepsHUDVisible = false
            if hud?.isVisible == true { scheduleDismiss(after: .milliseconds(450)) }
            return
        }
        guard NSEvent.pressedMouseButtons == 0, canRevealNavigation?() == true else { return }
        pointerKeepsHUDVisible = true
        hudModel.warning = nil
        if let hovered, hovered.number != presentedDisplay?.number {
            presentedDisplay = navigationDisplays?().first { $0.number == hovered.number } ?? hovered
            MainThreadActivity.during("hudModel update") { publishNavigation() }
        }
        presentHUD(dismissAfter: .milliseconds(1_500))
    }

    private func presentHUD(dismissAfter: Duration) {
        guard let screen = screen(of: presentedDisplay ?? focusedNavigationDisplay) else { return }
        let hud = hudPanel()
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
            windowCount: hudModel.displayedItemCount, warningHeight: warningHeight)
        contentFrame = geometry.contentFrame
        hud.ignoresMouseEvents = hudIgnoresPointer(at: pointerLocation())
        updateHoverFrames()
        // Successive navigations usually keep the same geometry. Avoid a forced
        // synchronous layout and redraw just as ribbon motion starts.
        if hud.frame != geometry.panelFrame || container.attachedToNotch != geometry.attachedToNotch
            || container.contentRect != geometry.contentInPanel {
            hudModel.attachedToNotch = geometry.attachedToNotch
            container.attachedToNotch = geometry.attachedToNotch
            container.contentRect = geometry.contentInPanel
            // The same synchronous resize, layout, and draw as setFrame(display: true),
            // timed separately: "hudWindow setFrame" was 9 s of stalls on 2026-10-26 and
            // the label could not say whether WindowServer, SwiftUI, or drawing cost it.
            // Layout must finish here: the enter animation reads the bar's final bounds.
            if hud.frame != geometry.panelFrame {
                MainThreadActivity.during("hudWindow setFrame") { hud.setFrame(geometry.panelFrame, display: false) }
            }
            container.needsLayout = true
            MainThreadActivity.during("hudWindow layout") { container.layoutSubtreeIfNeeded() }
            MainThreadActivity.during("hudWindow display") { hud.displayIfNeeded() }
        }
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
            MainThreadActivity.during("hudWindow orderFront") { hud.orderFrontRegardless() }
        }
        if !wasVisible || wasExiting {
            let configuration = hudModel.interfaceAnimationConfiguration
            MainThreadActivity.during("hud transition") {
                container.transition(
                    visible: true,
                    reduceMotion: hudModel.reduceMotion,
                    duration: configuration.hudEnterDuration,
                    configuration: configuration
                )
            }
        }
        if !pointerKeepsHUDVisible { scheduleDismiss(after: dismissAfter) }
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
                ))
            } catch { return }
            guard !Task.isCancelled else { return }
            self.completeHUDDismiss(generation: generation)
        }
    }

    private func beginHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, !hudIsExiting, !pointerKeepsHUDVisible,
              let container = hud?.contentView as? HUDContainerView else { return false }
        hudIsExiting = true
        let configuration = hudModel.interfaceAnimationConfiguration
        container.transition(
            visible: false,
            reduceMotion: reduceMotion(),
            duration: configuration.hudExitDuration,
            configuration: configuration
        )
        return true
    }

    private func completeHUDDismiss(generation: UInt64) {
        guard generation == hudGeneration, hudIsExiting else { return }
        hud?.orderOut(nil)
        hudIsExiting = false
        hudModel.showingSpaces = false
    }

    func hide() {
        suspend()
        MainThreadActivity.during("overlays close") {
            borderPanels.forEach { $0.close() }
            hud?.close()
        }
        // Recreate on the next presentation so an explicit Start on a different native
        // Desktop binds the panels there without making them visible on every Desktop.
        borderPanels = []
        hud = nil
    }

    /// Hides the overlays but keeps their panels for a resume, which always returns to
    /// the Desktop they were created on. A new HUD panel lays out and draws its content
    /// synchronously on first presentation, a 60-260 ms main-thread stall after unlock.
    func suspend() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        hoverFrames = []
        contentFrame = nil
        presentedDisplay = nil
        pointerKeepsHUDVisible = false
        hudModel.showingSpaces = false
        dismissTask?.cancel()
        dismissTask = nil
        hudGeneration &+= 1
        hudIsExiting = false
        shortcutHints.hide()
        MainThreadActivity.during("overlays orderOut") {
            borderPanels.forEach { $0.orderOut(nil) }
            hud?.orderOut(nil)
        }
    }

    func showWarning(_ message: String) {
        presentOnFocusedDisplay()
        hudModel.warning = message
        hudModel.warningIsNotice = false
        presentHUD(dismissAfter: .seconds(5))
    }

    /// The warning's place in the bar, for a short note that needs no action. Like a
    /// warning, it ignores the pointer and the panel never becomes key.
    func showNotice(_ message: String) {
        presentOnFocusedDisplay()
        hudModel.warning = message
        hudModel.warningIsNotice = true
        presentHUD(dismissAfter: .milliseconds(2_500))
    }

    private func presentOnFocusedDisplay() {
        guard presentedDisplay?.isFocused == false else { return }
        presentedDisplay = focusedNavigationDisplay
        MainThreadActivity.during("hudModel update") { publishNavigation() }
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
    /// Where the content sits in the container; nil insets it by the padding on every side.
    var contentRect: CGRect?
    /// Content at the bottom of the screen grows from and sinks toward its bottom edge.
    let anchoredToBottom: Bool
    private var motionConfiguration = InterfaceAnimationConfiguration.default
    var hiddenTravel: CGFloat {
        CGFloat(attachedToNotch
            ? motionConfiguration.attachedHUDTravel
            : motionConfiguration.floatingHUDTravel)
    }

    convenience init(model: NavigationHUDModel) {
        let hosting = FirstMouseHostingView(rootView: NavigationHUD(model: model))
        // The container sizes the hosting view by frame and never asks for its fitting
        // size, so SwiftUI's minimum, intrinsic, and maximum measurements are wasted work.
        hosting.sizingOptions = []
        self.init(hostingView: hosting)
    }

    init(hostingView: NSView, anchoredToBottom: Bool = false) {
        self.hostingView = hostingView
        self.anchoredToBottom = anchoredToBottom
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
        // Accepting mouse events, the panel receives the pointer's moves over its
        // transparent padding too, which the local monitor needs to let that padding go.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// The tracking area exists for the local monitor; the moves go no further.
    override func mouseMoved(with event: NSEvent) {}

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animatedView.frame = contentRect ?? CGRect(
            x: Self.padding, y: Self.padding,
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
        // at commit. Compensate the scale in the transform to keep its top (or bottom)
        // center fixed.
        let x = size.width * (1 - scale) / 2
        let y = anchoredToBottom ? -hiddenTravel : size.height * (1 - scale) + hiddenTravel
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

/// Receives the first click while the managed app remains the key application.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
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

/// One piece of the focus outline: the window's whole native-corner border, offset so
/// only the part inside this panel shows.
final class BorderView: NSView {
    static let defaultColor = NSColor(srgbRed: 0.44, green: 0.85, blue: 0.71, alpha: 0.95)
    static var fallbackCornerRadius: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 9
    }

    static func resolvedCornerRadius(_ native: CGFloat?, window: CGRect) -> CGFloat {
        let radius = native.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? fallbackCornerRadius
        return min(radius, max(0, min(window.width, window.height) / 2))
    }

    var strokeColor = defaultColor {
        didSet {
            guard oldValue != strokeColor else { return }
            outline.borderColor = strokeColor.cgColor
        }
    }

    /// The window's outline beside its sheet, fainter so the sheet's ring reads as focused.
    static let sheetOwnerOpacity: CGFloat = 0.45

    private let outline = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    private func configureLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        outline.borderWidth = FocusOutlineGeometry.strokeWidth
        outline.borderColor = strokeColor.cgColor
        outline.cornerCurve = .continuous
        layer?.addSublayer(outline)
    }

    /// `window` and `piece` in screen coordinates with y growing downward; the stroke
    /// lies inside the window so it stays visible at display edges.
    func showOutline(of window: CGRect, radius: CGFloat, from piece: CGRect, opacity: CGFloat = 1) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.frame = CGRect(x: window.minX - piece.minX, y: piece.maxY - window.maxY,
                               width: window.width, height: window.height)
        outline.cornerRadius = radius
        outline.opacity = Float(opacity)
        CATransaction.commit()
    }
}

/// App icons by bundle identifier. Each body evaluation looked the app up with
/// LaunchServices and loaded a fresh icon (Chrome: ~73 ms cold, measured 2026-10-26),
/// on the main thread, for every chip the app bar redrew.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage? {
        if let cached = icons[bundleIdentifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleIdentifier] = icon
        return icon
    }
}

struct AppIcon: View {
    let bundleIdentifier: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let icon = AppIconCache.icon(for: bundleIdentifier) {
                Image(nsImage: icon).resizable()
            } else {
                PhosphorIcon(.appWindow)
                    .padding(4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What the app bar lists: the focused space with the focused display's picker, or the
/// space another display shows with that display's picker.
struct NavigationHUDContent {
    let spaceIndex: Int
    let availableSpaceIndices: [Int]
    let space: SpaceState

    init(state: WorkspaceState, otherSpaceIndex: Int?, display: DisplayID?) {
        if let otherSpaceIndex, let display, state.spaces.indices.contains(otherSpaceIndex) {
            spaceIndex = otherSpaceIndex
            availableSpaceIndices = state.displayedSpaceIndices(on: display)
        } else {
            spaceIndex = state.activeSpaceIndex
            availableSpaceIndices = state.displayedSpaceIndices
        }
        space = state.spaces[spaceIndex]
    }
}

/// One ribbon tile in the app bar: a lone window, or a multi-pane tile's windows in reading order.
struct AppBarTile: Equatable, Identifiable {
    let id: String
    let windows: [WindowRecord]
}

@MainActor
final class NavigationHUDModel: ObservableObject {

    @Published var space = 1
    @Published var windows: [WindowRecord] = []
    /// `windows` grouped by ribbon tile, so a multi-pane tile shows as one group.
    @Published var tiles: [AppBarTile] = []
    @Published var focusedID: String?
    @Published var warning: String?
    /// The message is a note, such as a refused tile change, rather than a warning.
    @Published var warningIsNotice = false
    @Published var reduceMotion = false
    @Published var attachedToNotch = false
    @Published var spaces: [SpaceState] = []
    @Published var availableSpaceIndices: [Int] = []
    @Published var showingSpaces = false
    @Published var appBarColor = BorderView.defaultColor
    @Published private(set) var animatesFocusIndicator = false
    let animationConfiguration = RibbonAnimationConfiguration.default
    let interfaceAnimationConfiguration = InterfaceAnimationConfiguration.default
    var onFocusWindow: ((String) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String) -> Void)?
    var onContentChange: (() -> Void)?
    private var lastFocusChange: TimeInterval?

    var displayedItemCount: Int { showingSpaces ? availableSpaceIndices.count : windows.count }
    var focusedWindowLabel: String {
        guard let window = windows.first(where: { $0.id == focusedID }) else { return "No windows" }
        let title = Self.displayTitle(for: window)
        let repeatsAppName = title.caseInsensitiveCompare(window.appName) == .orderedSame
        return title.isEmpty || repeatsAppName ? window.appName : "\(window.appName) - \(title)"
    }
    private static let workspaceTitledEditors: Set<String> = [
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.exafunction.windsurf",
    ]
    /// VS Code-family editors title windows "file — workspace"; keep only the workspace.
    static func displayTitle(for window: WindowRecord) -> String {
        guard workspaceTitledEditors.contains(window.bundleIdentifier),
              let workspace = window.title.components(separatedBy: " — ").last else { return window.title }
        return workspace
    }

    /// The app bar's groups: each tile's windows in reading order, leaving out
    /// windows without a record and tiles left empty by that.
    static func tiles(of space: SpaceState, records: [String: WindowRecord]) -> [AppBarTile] {
        space.tiles.compactMap { tile in
            let windows = tile.windowIDs.compactMap { records[$0] }
            return windows.isEmpty ? nil : AppBarTile(id: tile.id, windows: windows)
        }
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
            spaces.membershipCount(of: windowID) > 1
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
}

private struct NavigationHUD: View {
    @ObservedObject var model: NavigationHUDModel
    @Namespace private var selection

    var body: some View {
        Group {
            if let warning = model.warning {
                HStack(alignment: .top, spacing: 12) {
                    PhosphorIcon(model.warningIsNotice ? .info : .warning)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(model.warningIsNotice ? Color(nsColor: model.appBarColor) : .orange)
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
                            ForEach(model.tiles) { tile in
                                if tile.windows.count == 1, let window = tile.windows.first {
                                    windowButton(window, appBarColor: appBarColor)
                                } else {
                                    // A multi-pane tile: its windows side by side on one shared
                                    // backing, each still its own button.
                                    HStack(spacing: 0) {
                                        ForEach(tile.windows) { window in
                                            windowButton(window, appBarColor: appBarColor)
                                        }
                                    }
                                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                                    .accessibilityElement(children: .contain)
                                    .accessibilityLabel("Tile of \(tile.windows.count) windows")
                                }
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
                Text(model.focusedWindowLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(
                    model.reduceMotion || !model.animatesFocusIndicator
                        ? nil
                        : RibbonAnimationCurve.ease.animation(
                            duration: model.interfaceAnimationConfiguration.feedbackDuration
                        ),
                    value: model.focusedWindowLabel
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func windowButton(_ window: WindowRecord, appBarColor: Color) -> some View {
        Button { model.selectWindow(id: window.id) } label: {
            AppIcon(bundleIdentifier: window.bundleIdentifier, size: 24)
            .padding(4)
            .background {
                if window.id == model.focusedID {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(appBarColor.opacity(0.25))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(appBarColor.opacity(0.8), lineWidth: 1) }
                        .matchedGeometryEffect(id: "selection", in: selection)
                        .transition(.identity)
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
        .id(window.id)
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

private extension RibbonAnimationCurve {
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
