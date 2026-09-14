import AppKit
import SwiftUI
import StagehandCore
import StagehandPlatform

@MainActor
final class NavigationOverlays {
    private let border = OverlayPanel()
    private let hud = OverlayPanel()
    private var dismissTask: Task<Void, Never>?

    init() {
        border.contentView = BorderView()
        border.hasShadow = false
        hud.hasShadow = true
    }

    func updateBorder(frame: CGRect, visible: Bool) {
        guard visible, let primary = NSScreen.screens.first else {
            border.orderOut(nil)
            return
        }
        let converted = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                               width: frame.width, height: frame.height)
        border.setFrame(converted.insetBy(dx: -2, dy: -2), display: true)
        border.orderFrontRegardless()
    }

    func showNavigation(state: WorkspaceState, windows: [WindowRecord]) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let width = min(580, screen.visibleFrame.width - 32)
        let height: CGFloat = 104
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: top - height - 8, width: width, height: height)
        let records = state.currentSpace.windowIDs.compactMap { id in windows.first { $0.id == id } }
        hud.contentView = NSHostingView(rootView: NavigationHUD(
            space: state.activeSpaceIndex + 1, mode: state.layoutMode,
            windows: records, focusedID: state.focusedWindowID
        ))
        let wasVisible = hud.isVisible
        hud.setFrame(wasVisible ? frame : frame.offsetBy(dx: 0, dy: 10), display: true)
        hud.alphaValue = wasVisible ? 1 : 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            hud.animator().alphaValue = 1
            hud.animator().setFrame(frame, display: true)
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            self.hud.orderOut(nil)
        }
    }

    func hide() {
        dismissTask?.cancel()
        border.orderOut(nil)
        hud.orderOut(nil)
    }

    func showWarning(_ message: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let width = min(580, screen.visibleFrame.width - 32)
        let top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        hud.contentView = NSHostingView(rootView: HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: width, height: 104, alignment: .leading)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 17)))
        hud.setFrame(CGRect(x: screen.frame.midX - width / 2, y: top - 112, width: width, height: 104), display: true)
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.hud.orderOut(nil)
        }
    }
}

private final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.44, green: 0.85, blue: 0.71, alpha: 0.95).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        path.stroke()
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

private struct NavigationHUD: View {
    let space: Int
    let mode: LayoutMode
    let windows: [WindowRecord]
    let focusedID: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SPACE \(space, format: .number.precision(.integerLength(2)))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Spacer()
                Text(mode == .scrolling ? "SCROLLING" : "MONOCLE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.55))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(windows) { window in
                            AppIcon(bundleIdentifier: window.bundleIdentifier)
                                .padding(6)
                                .background(window.id == focusedID ? Color.mint.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(window.id == focusedID ? Color.mint.opacity(0.8) : .clear, lineWidth: 1)
                                }
                                .id(window.id)
                        }
                    }
                    .frame(minWidth: 1)
                }
                .onAppear { if let focusedID { proxy.scrollTo(focusedID, anchor: .center) } }
            }
            Text(windows.first(where: { $0.id == focusedID }).map {
                $0.title.isEmpty ? $0.appName : "\($0.appName) · \($0.title)"
            } ?? "Empty space")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.075).opacity(0.97), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.12), lineWidth: 1) }
        .environment(\.colorScheme, .dark)
    }
}
