import AppKit
import SwiftUI
import QuartzCore
import StagehandCore
import StagehandPlatform

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
        let limit = max(1, min(warningHeight == nil ? 520 : 580, visibleFrame.width - 32))
        let desiredWidth = warningHeight == nil ? 60 + CGFloat(max(1, windowCount)) * 36 : 580
        let width = min(limit, desiredWidth)
        let height = warningHeight.map { max(72, $0) } ?? 66
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
        hudModel.onDropTargetChange = { [weak self] isTargeted in
            self?.dropTargetChanged(isTargeted: isTargeted)
        }
        hudModel.onContentChange = { [weak self] in
            self?.presentHUD(dismissAfter: .milliseconds(1_500))
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
            let reveal = CABasicAnimation(keyPath: "opacity")
            reveal.fromValue = layer.animation(forKey: "focusReveal") == nil ? 0.72 : (layer.presentation()?.opacity ?? 0.72)
            reveal.toValue = 1
            reveal.duration = 0.125 * animationDurationMultiplier
            reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
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
        if hudModel.focusedID != state.focusedWindowID { hudModel.focusedID = state.focusedWindowID }
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
            windowCount: hudModel.displayedItemCount)
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
        hudModel.animationDurationMultiplier = animationDurationMultiplier
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
            container.setHidden(reduceMotion: hudModel.reduceMotion)
            hud.orderFrontRegardless()
        }
        if !wasVisible || wasExiting {
            container.transition(visible: true, reduceMotion: hudModel.reduceMotion,
                                 duration: 0.25 * animationDurationMultiplier)
        }
        if !pointerKeepsHUDVisible && !dropTargetKeepsHUDVisible { scheduleDismiss(after: dismissAfter) }
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        let generation = hudGeneration
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self, self.beginHUDDismiss(generation: generation) else { return }
            do { try await Task.sleep(for: .seconds(0.2 * self.animationDurationMultiplier)) } catch { return }
            guard !Task.isCancelled else { return }
            _ = self.completeHUDDismiss(generation: generation)
        }
    }

    @discardableResult
    func beginHUDDismiss(generation: UInt64) -> Bool {
        guard generation == hudGeneration, !hudIsExiting, !pointerKeepsHUDVisible,
              !dropTargetKeepsHUDVisible,
              let container = hud?.contentView as? HUDContainerView else { return false }
        hudIsExiting = true
        container.transition(visible: false, reduceMotion: reduceMotion(),
                             duration: 0.2 * animationDurationMultiplier)
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
    var hiddenTravel: CGFloat { animatedView.bounds.height * (attachedToNotch ? 0.35 : 0.12) }

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
        let scale: CGFloat = 0.95
        let size = animatedView.bounds.size
        // AppKit owns this backing layer's bottom-left anchor and resets custom anchors
        // at commit. Compensate the scale in the transform to keep its top center fixed.
        let x = size.width * (1 - scale) / 2
        let y = size.height * (1 - scale) + hiddenTravel
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
    @Published private(set) var draggedWindowID: String?
    @Published private(set) var dropTargetID: String?
    var animationDurationMultiplier: Double = 1
    var onFocusWindow: ((String) -> Void)?
    var onSelectSpace: ((Int) -> Void)?
    var onShareWindow: ((String, Int) -> Void)?
    var onRemoveWindow: ((String) -> Void)?
    var onReorderWindow: ((String, Int) -> Void)?
    var onDropTargetChange: ((Bool) -> Void)?
    var onContentChange: (() -> Void)?

    var displayedItemCount: Int { showingSpaces ? availableSpaceIndices.count : windows.count }
    var focusedAppName: String { windows.first { $0.id == focusedID }?.appName ?? "No windows" }
    var dropDescription: String? {
        guard let dropTargetID,
              let edge = dropIndicatorEdge(for: dropTargetID),
              let appName = windows.first(where: { $0.id == dropTargetID })?.appName else { return nil }
        return "Move \(edge == .leading ? "before" : "after") \(appName)"
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
                .buttonStyle(.plain)
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
                                .buttonStyle(.plain)
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
                        .animation(model.reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1,
                                                                          duration: 0.2 * model.animationDurationMultiplier),
                                   value: model.focusedID)
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to space \(index + 1)")
                }
            }
        }
        .frame(height: 32)
    }
}
