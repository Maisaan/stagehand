import AppKit
import QuartzCore
import StagehandCore
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct NavigationMotionTests {
    @Test func repeatedNavigationReversesDismissalWithoutReplacingViewsOrTakingFocus() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp.keyWindow
        let state = WorkspaceState()

        overlays.showNavigation(state: state, windows: [])
        let panel = try #require(overlays.hud)
        let container = try #require(panel.contentView as? HUDContainerView)
        let hostingView = container.hostingView
        let frame = panel.frame

        for _ in 0..<10 {
            let previousGeneration = overlays.hudGeneration
            #expect(overlays.beginHUDDismiss(generation: previousGeneration))
            #expect(overlays.hudIsExiting)
            overlays.showNavigation(state: state, windows: [])

            #expect(overlays.hud === panel)
            #expect(panel.contentView === container)
            #expect(container.hostingView === hostingView)
            #expect(panel.frame == frame)
            #expect(overlays.hudGeneration > previousGeneration)
            #expect(!overlays.hudIsExiting)
            #expect(!overlays.completeHUDDismiss(generation: previousGeneration))
            #expect(panel.isVisible)
            #expect(container.animatedView.layer?.opacity == 1)
            #expect(CATransform3DIsIdentity(try #require(container.animatedView.layer).transform))
        }

        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
        #expect(NSApp.keyWindow === keyWindow)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @Test func currentDismissalHidesOnlyAfterCompletionAndCanBePresentedAgain() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let panel = try #require(overlays.hud)
        let generation = overlays.hudGeneration

        #expect(overlays.beginHUDDismiss(generation: generation))
        #expect(panel.isVisible)
        #expect(overlays.completeHUDDismiss(generation: generation))
        #expect(!panel.isVisible)
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        #expect(overlays.hud === panel)
        #expect(panel.isVisible)
        #expect(!overlays.hudIsExiting)
    }

    @Test func navigationWhileVisibleDoesNotRestartTheEntranceAnimation() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let container = try #require(overlays.hud?.contentView as? HUDContainerView)
        let layer = try #require(container.animatedView.layer)
        let entrance = try #require(layer.animation(forKey: "hudOpacity"))
        #expect(entrance.beginTime > 0)

        for index in 0..<9 {
            overlays.showNavigation(state: WorkspaceState(activeSpaceIndex: index), windows: [])
            #expect(layer.animation(forKey: "hudOpacity")?.beginTime == entrance.beginTime)
        }
    }

    @Test func entranceAndExitRemainCenteredAfterAppKitCommitsBackingLayers() async throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false }, animationDurationMultiplier: 4)
        defer { overlays.hide() }
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let panel = try #require(overlays.hud)
        let panelFrame = panel.frame
        let container = try #require(panel.contentView as? HUDContainerView)
        container.displayIfNeeded()
        CATransaction.flush()

        // A synchronous anchorPoint assertion misses AppKit resetting its backing
        // layer's anchor during the next display transaction.
        try await Task.sleep(for: .milliseconds(50))
        let entering = try #require(container.animatedView.layer?.presentation())
        #expect(entering.transform.m11 < 1)
        #expect(abs(entering.frame.midX - container.bounds.midX) <= 0.5)
        let enteringUpwardOffset = container.animatedView.bounds.height * 0.08 * (1 - entering.transform.m11) / 0.05
        #expect(abs(entering.frame.maxY - container.animatedView.frame.maxY - enteringUpwardOffset) <= 0.5)
        #expect(panel.frame == panelFrame)

        #expect(overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        let exiting = try #require(container.animatedView.layer?.presentation())
        #expect(exiting.transform.m11 < 1)
        #expect(abs(exiting.frame.midX - container.bounds.midX) <= 0.5)
        let exitingUpwardOffset = container.animatedView.bounds.height * 0.08 * (1 - exiting.transform.m11) / 0.05
        #expect(abs(exiting.frame.maxY - container.animatedView.frame.maxY - exitingUpwardOffset) <= 0.5)
        #expect(panel.frame == panelFrame)
    }

    @Test func reducedMotionUsesOpacityWithoutTranslationOrScale() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { true })
        defer { overlays.hide() }
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let panel = try #require(overlays.hud)
        let container = try #require(panel.contentView as? HUDContainerView)
        let layer = try #require(container.animatedView.layer)

        #expect(layer.animation(forKey: "hudTransform") == nil)
        #expect(layer.animation(forKey: "hudOpacity") != nil)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        #expect(layer.animation(forKey: "hudTransform") == nil)
        #expect(layer.animation(forKey: "hudOpacity") != nil)
        #expect(CATransform3DIsIdentity(layer.transform))
    }

    @Test func borderGeometryUpdatesImmediatelyWithoutRestartingFocusReveal() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        let primary = try #require(NSScreen.screens.first)
        let initial = CGRect(x: 100, y: 100, width: 640, height: 480)
        overlays.updateBorder(frame: initial, visible: true, cornerRadius: 18, focusChanged: true)
        let panel = try #require(overlays.border)
        let layer = try #require(panel.contentView?.layer)
        let reveal = try #require(layer.animation(forKey: "focusReveal")?.copy() as? CAAnimation)
        // Give the in-flight animation an explicit time so a replaced default-time
        // animation cannot accidentally satisfy the no-restart assertion.
        reveal.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.add(reveal, forKey: "focusReveal")

        for width in [680.0, 720.0, 760.0] {
            let frame = CGRect(x: 110, y: 115, width: width, height: 490)
            overlays.updateBorder(frame: frame, visible: true, cornerRadius: 18, focusChanged: false)
            let expected = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY,
                                  width: frame.width, height: frame.height)
            #expect(panel.frame == expected)
            #expect(overlays.border === panel)
            #expect(layer.animation(forKey: "focusReveal")?.beginTime == reveal.beginTime)
            #expect(layer.animationKeys()?.allSatisfy { $0 == "focusReveal" } == true)
        }
    }

    @Test func hideInvalidatesPendingDismissalsAndReleasesPanels() throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let panel = try #require(overlays.hud)
        let generation = overlays.hudGeneration
        #expect(overlays.beginHUDDismiss(generation: generation))

        overlays.hide()
        #expect(!panel.isVisible)
        #expect(overlays.hud == nil)
        #expect(overlays.border == nil)
        #expect(!overlays.completeHUDDismiss(generation: generation))
    }
}
