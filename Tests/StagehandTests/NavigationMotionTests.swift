import AppKit
import QuartzCore
import StagehandCore
import Testing
@testable import Stagehand

@Suite(.serialized) @MainActor
struct NavigationMotionTests {
    @Test func sharedWindowNavigationRetainsTheHorizontalRibbonSlide() {
        let previous = WorkspaceState(spaces: [
            SpaceState(windowIDs: ["other", "shared"], focusedWindowID: "other"),
            SpaceState(windowIDs: ["shared"])
        ])
        var destination = previous
        #expect(destination.apply(.focusNext) == true)

        #expect(shouldSlideRibbon(
            from: previous,
            to: destination,
            hadPreview: false,
            reduceMotion: false
        ))
    }

    @Test func appActivationBeginsBeforeRibbonTranslation() async {
        var events: [String] = []
        let outcome = await runFocusFirstNavigation(
            translate: {
                events.append("translate")
                return .readyForFocus
            },
            focus: {
                events.append("focus")
                return true
            },
            focusConfirmed: { events.append("focusConfirmed") },
            commitInput: { events.append("commit") },
            revealBorder: { events.append("border") }
        )

        #expect(outcome == .completed)
        #expect(events == ["border", "focus", "focusConfirmed", "translate", "commit"])

        events.removeAll()
        let superseded = await runFocusFirstNavigation(
            translate: {
                events.append("translate")
                return .superseded
            },
            focus: {
                events.append("focus")
                return true
            },
            focusConfirmed: { events.append("focusConfirmed") },
            commitInput: { Issue.record("A superseded transition must not commit input") },
            revealBorder: { events.append("border") }
        )
        #expect(superseded == .superseded)
        #expect(events == ["border", "focus", "focusConfirmed", "translate"])
    }

    @Test func offscreenRibbonFramesChooseTheirNearestParkingSide() {
        let display = CGRect(x: 0, y: 0, width: 1800, height: 1169)

        #expect(preferredParkingSide(
            for: CGRect(x: -1662, y: 62, width: 1711, height: 1084),
            relativeTo: display
        ) == .left)
        #expect(preferredParkingSide(
            for: CGRect(x: 1799, y: 62, width: 1711, height: 1084),
            relativeTo: display
        ) == .right)
    }

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
        let enteringUpwardOffset = container.hiddenTravel * (1 - entering.transform.m11) / 0.02
        #expect(abs(entering.frame.maxY - container.animatedView.frame.maxY - enteringUpwardOffset) <= 0.5)
        #expect(panel.frame == panelFrame)

        #expect(overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        let exiting = try #require(container.animatedView.layer?.presentation())
        #expect(exiting.transform.m11 < 1)
        #expect(abs(exiting.frame.midX - container.bounds.midX) <= 0.5)
        let exitingUpwardOffset = container.hiddenTravel * (1 - exiting.transform.m11) / 0.02
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

    @Test func cameraAttachedContainerClipsMotionAtItsTopEdge() throws {
        _ = NSApplication.shared
        let container = HUDContainerView(model: NavigationHUDModel())
        container.attachedToNotch = true
        container.frame = CGRect(x: 0, y: 0, width: 272, height: 82)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        #expect(container.animatedView.frame.maxY == container.bounds.maxY)
        #expect(container.animatedView.bounds.size == CGSize(width: 240, height: 66))
        #expect(container.layer?.masksToBounds == true)
        container.setHidden(reduceMotion: false)
        let transform = try #require(container.animatedView.layer).transform
        #expect(transform.m11 == 0.98)
        #expect(transform.m22 == 0.98)
        #expect(abs(transform.m42 - (66 * 0.02 + 10)) < 0.001)
    }

    @Test func customHUDMotionControlsScaleTravelAndFocusFlash() throws {
        _ = NSApplication.shared
        let configuration = InterfaceAnimationConfiguration(
            hudEnterDuration: 0.3,
            hudExitDuration: 0.12,
            attachedHUDTravel: 18,
            floatingHUDTravel: 11,
            hiddenHUDScale: 0.94,
            feedbackDuration: 0.1,
            pressedScale: 0.96,
            focusRevealDuration: 0.27,
            focusRevealOpacity: 0.55
        )
        let container = HUDContainerView(model: NavigationHUDModel())
        container.attachedToNotch = true
        container.frame = CGRect(x: 0, y: 0, width: 272, height: 82)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        container.setHidden(reduceMotion: false, configuration: configuration)
        let transform = try #require(container.animatedView.layer).transform
        #expect(transform.m11 == 0.94)
        #expect(transform.m22 == 0.94)
        #expect(abs(transform.m42 - (66 * 0.06 + 18)) < 0.001)

        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        overlays.setInterfaceAnimationConfiguration(configuration)
        overlays.updateBorder(
            frame: CGRect(x: 50, y: 50, width: 400, height: 300),
            visible: true,
            focusChanged: true
        )
        let reveal = try #require(overlays.border?.contentView?.layer?.animation(forKey: "focusReveal"))
        #expect(reveal.duration == 0.27)
    }

    @Test func developerHUDReplayUsesTheCurrentEntranceTiming() async throws {
        _ = NSApplication.shared
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        let configuration = InterfaceAnimationConfiguration(
            hudEnterDuration: 0.31,
            hudExitDuration: 0.12,
            attachedHUDTravel: 12,
            floatingHUDTravel: 8,
            hiddenHUDScale: 0.96,
            feedbackDuration: 0.1,
            pressedScale: 0.97,
            focusRevealDuration: 0.14,
            focusRevealOpacity: 0.7
        )
        overlays.setInterfaceAnimationConfiguration(configuration)
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let layer = try #require(overlays.hud?.contentView as? HUDContainerView).animatedView.layer

        overlays.hudModel.previewHUDAnimation()
        await Task.yield()

        #expect(layer?.animation(forKey: "hudOpacity")?.duration == 0.31)
        #expect(layer?.animation(forKey: "hudTransform")?.duration == 0.31)
    }

    @Test func developerMotionEditorFitsTheExpandedAppBar() {
        _ = NSApplication.shared
        let model = NavigationHUDModel()
        model.developerControlsEnabled = true
        let container = HUDContainerView(model: model)
        container.attachedToNotch = true
        container.frame = CGRect(x: 0, y: 0, width: 612, height: 320)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()

        #expect(container.animatedView.bounds.size == CGSize(width: 580, height: 304))
        #expect(container.hostingView.frame == container.animatedView.bounds)
    }

    @Test func revisedHUDTimingStaysBelowThreeHundredMilliseconds() throws {
        _ = NSApplication.shared
        #expect(InterfaceAnimationConfiguration.default.focusRevealDuration == 0.1)
        let overlays = NavigationOverlays(reduceMotion: { false })
        defer { overlays.hide() }
        overlays.showNavigation(state: WorkspaceState(), windows: [])
        let container = try #require(overlays.hud?.contentView as? HUDContainerView)
        let layer = try #require(container.animatedView.layer)
        #expect(layer.animation(forKey: "hudOpacity")?.duration == 0.18)
        #expect(layer.animation(forKey: "hudTransform")?.duration == 0.18)
        #expect(overlays.beginHUDDismiss(generation: overlays.hudGeneration))
        #expect(layer.animation(forKey: "hudOpacity")?.duration == 0.14)
        #expect(layer.animation(forKey: "hudTransform")?.duration == 0.14)
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
