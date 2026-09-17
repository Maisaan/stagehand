import AppKit
import SwiftUI

/// The only Stagehand-owned working window: a keyboard-safe placeholder for an empty space.
@MainActor
final class EmptySpaceWindow {
    private let window: NSWindow = {
        let window = EmptyWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = false
        return window
    }()

    var isFocused: Bool { NSApp.isActive && window.isKeyWindow }

    func show(space: Int, frame: CGRect) async -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        window.setFrame(CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                               width: frame.width, height: frame.height), display: true)
        window.contentView = NSHostingView(rootView: VStack(spacing: 16) {
            Image(systemName: "rectangle.dashed").font(.system(size: 46, weight: .ultraLight)).foregroundStyle(.mint)
            Text("Space \(space)").font(.system(size: 24, weight: .medium))
            Text("No windows here yet.").foregroundStyle(.secondary)
            Text("Use your space shortcuts or swipe vertically.\nFrom another space, use the Share window shortcut for this space.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
        repeat {
            guard !Task.isCancelled else { return false }
            if NSApp.isActive && window.isKeyWindow { return true }
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }

    func hide() { window.orderOut(nil) }
}

private final class EmptyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // No text editor in an empty space. Navigation still comes through the global shortcuts.
    override func keyDown(with event: NSEvent) {}
}
