import AppKit
import StagehandCore
import StagehandPlatform

enum ContestedHolderTrigger: String {
    case layout, pointer, click
}

/// A window shown on two displays at once (spec 1.2): the real window on its holder
/// display, a placeholder on every other one, and the pointer watch that moves it.
extension StagehandModel {
    /// Picks every contested window's holder, moves the windows leaving `display` to
    /// their holders, and shows the placeholders, the focused display's at the frames
    /// its slide starts from. Returns the windows `display` must not write or slide.
    func holdContestedWindows(on display: Display, placements: [WindowPlacement],
                              slideFrom: [String: CGRect]?, slideStarts: [String: CGRect]?,
                              in arrangement: DisplayArrangement) -> Set<String> {
        let otherLayouts = otherDisplayLayouts(in: arrangement)
        guard !otherLayouts.isEmpty else {
            clearContestedWindows()
            return []
        }
        let shownHere = Set(placements.filter(\.isVisible).map(\.windowID))
        var shown = [display.id: shownHere]
        for layout in otherLayouts {
            shown[layout.display.id] = Set(layout.placements.filter(\.isVisible).map(\.windowID))
        }
        let pointerDisplay = managedDisplay(at: pointerLocationProvider(), in: arrangement)
        let holders = state.contestedWindowHolders(shownOn: shown, pointerDisplay: pointerDisplay)
        recordHolderChanges(holders)
        contestedHolders = holders
        contestedHolderTrigger = .layout
        let heldElsewhere = Set(otherLayouts.flatMap { shown[$0.display.id] ?? [] }.filter { holders[$0] != display.id })
        handOff(heldElsewhere, leaving: display, to: otherLayouts, besides: shownHere.subtracting(heldElsewhere),
                in: arrangement)
        var startFrames: [String: CGRect] = [:]
        for placement in placements where heldElsewhere.contains(placement.windowID)
            && (placement.isVisible || slideFrom?[placement.windowID]?.intersects(display.visibleFrame) == true) {
            startFrames[placement.windowID] = slideStarts?[placement.windowID] ?? placement.frame
        }
        showPlaceholders(on: display.id, frames: startFrames, otherLayouts: otherLayouts)
        watchPointer(displays: arrangement.displays.filter { state.displays.ids.contains($0.id) },
                     pointerDisplay: pointerDisplay)
        return heldElsewhere
    }

    /// After the layout: the placeholders at the frames it settled on.
    func settleContestedPlaceholders(on display: Display, placements: [WindowPlacement],
                                     heldElsewhere: Set<String>, otherLayouts: [DisplayLayout]) {
        guard !otherLayouts.isEmpty || !placeholderFrames.isEmpty else { return }
        var frames: [String: CGRect] = [:]
        for placement in placements where placement.isVisible && heldElsewhere.contains(placement.windowID) {
            frames[placement.windowID] = placement.frame
        }
        showPlaceholders(on: display.id, frames: frames, otherLayouts: otherLayouts)
    }

    /// Which visible windows each other display writes: its own, and each contested
    /// window on its holder. `focusedDisplayWindowIDs` are written by the focused display.
    func otherDisplayTargets(_ layouts: [DisplayLayout],
                             besides focusedDisplayWindowIDs: Set<String>) -> [(display: DisplayID, frames: [String: CGRect])] {
        var placed = focusedDisplayWindowIDs
        return layouts.map { layout in
            var targets: [String: CGRect] = [:]
            for placement in layout.placements where placement.isVisible {
                let holder = contestedHolders[placement.windowID]
                guard holder == layout.display.id || (holder == nil && !placed.contains(placement.windowID)) else { continue }
                targets[placement.windowID] = placement.frame
            }
            placed.formUnion(targets.keys)
            return (layout.display.id, targets)
        }
    }

    var focusedDisplayPlaceholderFrames: [String: CGRect] {
        state.focusedDisplay.flatMap { placeholderFrames[$0] } ?? [:]
    }

    /// Sends the frames of windows the focused display shows as placeholders to their
    /// placeholders; returns the rest, which are real windows.
    func movePlaceholders(in frames: [String: CGRect]) -> [String: CGRect] {
        guard let display = state.focusedDisplay, let shown = placeholderFrames[display], !shown.isEmpty else { return frames }
        var windowFrames = frames
        var moved: [String: CGRect] = [:]
        for windowID in shown.keys {
            if let frame = windowFrames.removeValue(forKey: windowID) { moved[windowID] = frame }
        }
        guard !moved.isEmpty else { return frames }
        placeholders.move(moved, on: display)
        placeholderFrames[display]?.merge(moved) { _, new in new }
        return windowFrames
    }

    /// Windows another display holds that the focused display does not show as a
    /// placeholder; a swipe preview must not pull them onto the focused display.
    func windowsOnlyOnOtherDisplays(in arrangement: DisplayArrangement) -> Set<String> {
        guard let focused = state.focusedDisplay else { return [] }
        let shownAsPlaceholders = focusedDisplayPlaceholderFrames
        return windowsShownOnOtherDisplays(in: arrangement).filter {
            contestedHolders[$0] != focused && shownAsPlaceholders[$0] == nil
        }
    }

    func contestedPointerMoved() {
        let point = pointerLocationProvider()
        let display = contestedPointerDisplays.first { $0.frame.contains(point) }?.id
        guard display != contestedPointerDisplay else { return }
        contestedPointerDisplay = display
        guard let display, isRunning, !isSuspended,
              placeholderFrames[display]?.keys.contains(where: { $0 != state.focusedWindowID }) == true,
              !changes.contains(where: { $0.change == .refresh }) else { return }
        contestedHolderTrigger = .pointer
        enqueue(.refresh)
    }

    func placeholderClicked(windowID: String, on display: DisplayID) {
        guard isRunning, !isSuspended, let space = state.shownSpaceIndex(on: display),
              state.spaces[space].contains(windowID: windowID) else { return }
        contestedHolderTrigger = .click
        focusWindow(windowID, inSpace: space)
    }

    func clearContestedWindows() {
        guard !contestedHolders.isEmpty || !placeholderFrames.isEmpty || overlays.onPointerMoved != nil else { return }
        placeholders.hide()
        placeholderFrames = [:]
        contestedHolders = [:]
        contestedHolderTrigger = .layout
        watchPointer(displays: [], pointerDisplay: nil)
    }

    private func managedDisplay(at point: CGPoint, in arrangement: DisplayArrangement) -> DisplayID? {
        arrangement.displays.first { state.displays.ids.contains($0.id) && $0.frame.contains(point) }?.id
    }

    private func recordHolderChanges(_ holders: [String: DisplayID]) {
        for (windowID, holder) in holders where contestedHolders[windowID] != holder {
            diagnostics.record("contested_window_holder", details: [
                "windowID": windowID,
                "from": contestedHolders[windowID]?.logPrefix ?? "none",
                "to": holder.logPrefix,
                "trigger": contestedHolderTrigger.rawValue
            ])
        }
    }

    private func handOff(_ heldElsewhere: Set<String>, leaving display: Display, to layouts: [DisplayLayout],
                         besides focusedDisplayWindowIDs: Set<String>, in arrangement: DisplayArrangement) {
        let leaving = heldElsewhere.filter { windowID in
            !windowSystem.isParked(windowID: windowID)
                && knownFrames[windowID].flatMap { managedDisplay(holding: $0, in: arrangement) } == display.id
        }
        guard !leaving.isEmpty else { return }
        for (_, targets) in otherDisplayTargets(layouts, besides: focusedDisplayWindowIDs) {
            for (windowID, target) in targets where leaving.contains(windowID) {
                writeStaticFrame(target, windowID: windowID)
            }
        }
    }

    private func showPlaceholders(on focusedDisplay: DisplayID, frames focusedFrames: [String: CGRect],
                                  otherLayouts: [DisplayLayout]) {
        var framesByDisplay: [DisplayID: [String: CGRect]] = focusedFrames.isEmpty ? [:] : [focusedDisplay: focusedFrames]
        for layout in otherLayouts {
            for placement in layout.placements where placement.isVisible {
                guard let holder = contestedHolders[placement.windowID], holder != layout.display.id else { continue }
                framesByDisplay[layout.display.id, default: [:]][placement.windowID] = placement.frame
            }
        }
        guard framesByDisplay != placeholderFrames else { return }
        placeholderFrames = framesByDisplay
        let records = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        placeholders.show(framesByDisplay.flatMap { display, frames in
            let color = focusBorderColor(forSpace: state.shownSpaceIndex(on: display) ?? state.activeSpaceIndex)
            return frames.compactMap { windowID, frame in
                records[windowID].map {
                    ContestedPlaceholder(windowID: windowID, display: display, frame: frame, color: color,
                                         bundleIdentifier: $0.bundleIdentifier)
                }
            }
        })
    }

    private func watchPointer(displays: [Display], pointerDisplay: DisplayID?) {
        guard !contestedHolders.isEmpty else {
            contestedPointerDisplays = []
            contestedPointerDisplay = nil
            if overlays.onPointerMoved != nil { overlays.onPointerMoved = nil }
            return
        }
        contestedPointerDisplays = displays
        contestedPointerDisplay = pointerDisplay
        if overlays.onPointerMoved == nil {
            overlays.onPointerMoved = { [weak self] in self?.contestedPointerMoved() }
        }
    }
}
