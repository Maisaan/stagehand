import AppKit
import StagehandCore
import StagehandPlatform

let traceGestures = ProcessInfo.processInfo.arguments.contains("--trace-gestures")

enum RibbonTransitionSource: Equatable {
    case managed
    case observedFocus
    case windowRemoval
}

func shouldSlideRibbon(from previousState: WorkspaceState, to state: WorkspaceState,
                       source: RibbonTransitionSource, hadPreview: Bool, reduceMotion: Bool) -> Bool {
    guard source != .observedFocus,
          !reduceMotion,
          previousState.activeSpaceIndex == state.activeSpaceIndex,
          state.focusedWindowID != nil else { return false }
    if source == .windowRemoval {
        return previousState.currentSpace.windowIDs != state.currentSpace.windowIDs
    }
    return previousState.focusedWindowID != state.focusedWindowID || hadPreview
}

func framesMatch(observed: CGRect, target: CGRect, tolerance: CGFloat = 1) -> Bool {
    abs(observed.minX - target.minX) <= tolerance
        && abs(observed.minY - target.minY) <= tolerance
        && abs(observed.width - target.width) <= tolerance
        && abs(observed.height - target.height) <= tolerance
}

func adjustedWindowHeight(current: CGFloat, available: CGFloat, growing: Bool) -> CGFloat? {
    guard current.isFinite, current > 0, available.isFinite, available > 0 else { return nil }
    let limit = available * (growing ? 1 : 0.25)
    guard growing ? current < limit : current > limit else { return nil }
    let adjustment = available * (growing ? 0.05 : -0.05)
    return growing ? min(current + adjustment, limit) : max(current + adjustment, limit)
}

func preferredHeightAfterResize(previous: CGRect, observed: CGRect, available: CGRect) -> CGFloat {
    let edgeTolerance: CGFloat = 4
    let grewFromTop = observed.height > previous.height + 3
        && observed.minY < previous.minY - 3
        && abs(observed.maxY - previous.maxY) <= edgeTolerance
    return grewFromTop && observed.minY <= available.minY + edgeTolerance
        ? available.height : observed.height
}

struct WindowFocusHistory {
    private var windowIDs: [String] = []

    mutating func record(windowID: String) {
        windowIDs.removeAll { $0 == windowID }
        windowIDs.append(windowID)
    }

    mutating func remove(windowIDs removedWindowIDs: Set<String>) {
        windowIDs.removeAll { removedWindowIDs.contains($0) }
    }

    func mostRecentWindowID(among availableWindowIDs: Set<String>) -> String? {
        windowIDs.last { availableWindowIDs.contains($0) }
    }
}

func focusMostRecentWindowAfterLoss(
    previousFocusedWindowID: String?,
    history: WindowFocusHistory,
    state: inout WorkspaceState
) {
    guard let previousFocusedWindowID,
          !state.currentSpace.windowIDs.contains(previousFocusedWindowID),
          let windowID = history.mostRecentWindowID(among: Set(state.currentSpace.windowIDs)) else { return }
    state.focus(windowID: windowID)
}

@MainActor
func prepareObservedFocus(
    state: WorkspaceState,
    notificationWindowID: String,
    focusedWindowID: String?
) -> WorkspaceState? {
    guard notificationWindowID == focusedWindowID else { return nil }
    return LayoutRequestPolicy.preferences.prepare(state: state, focusedWindowID: focusedWindowID)
}

/// Result of one layout pass. `.failed` pauses and restores; `.interrupted` means the
/// session, worker, or Desktop changed underneath it.
enum LayoutOutcome: Equatable {
    case completed
    case interrupted
    case targetUnavailable(windowID: String, reason: WindowUnavailability)
    case failed(reason: String)
}

enum RibbonTranslationOutcome: Equatable {
    case readyForFocus
    case superseded
    case failed
}

enum NavigationTransitionOutcome: Equatable {
    case completed
    case superseded
    case failed
}

@MainActor
func runFocusFirstNavigation(
    translate: () async -> RibbonTranslationOutcome,
    focus: () async -> Bool,
    focusConfirmed: () -> Void,
    commitInput: () -> Void,
    revealBorder: () -> Void
) async -> NavigationTransitionOutcome {
    revealBorder()
    guard await focus() else { return .failed }
    // A verified destination can receive input while the ribbon finishes moving.
    commitInput()
    focusConfirmed()
    switch await translate() {
    case .superseded: return .superseded
    case .failed: return .failed
    case .readyForFocus: break
    }
    return .completed
}

@MainActor
func runConcurrentRemovalNavigation(
    translate: @escaping () async -> RibbonTranslationOutcome,
    cancelTranslation: () -> Void,
    focus: () async -> Bool,
    focusConfirmed: () -> Void,
    commitInput: () -> Void,
    revealBorder: () -> Void
) async -> NavigationTransitionOutcome {
    let translation = Task { @MainActor in await translate() }
    await Task.yield()
    let focused = await focus()
    guard focused else {
        cancelTranslation()
        _ = await translation.value
        return .failed
    }
    commitInput()
    focusConfirmed()
    let translationOutcome = await translation.value
    switch translationOutcome {
    case .superseded: return .superseded
    case .failed: return .failed
    case .readyForFocus: break
    }
    revealBorder()
    return .completed
}

func preferredParkingSide(for frame: CGRect?, relativeTo bounds: CGRect) -> WindowParkingSide? {
    guard let frame, !bounds.isEmpty, frame.midX.isFinite, bounds.midX.isFinite else { return nil }
    return frame.midX < bounds.midX ? .left : .right
}

struct RibbonPositionWriteFailure: Equatable {
    let windowID: String
    let requestedFrame: CGRect
    let actualFrame: CGRect?
}

enum WindowParkingOutcome: Equatable {
    case parked
    case deferred
    case unavailable(WindowUnavailability)
    case failed
}

@discardableResult
func removeTerminatedApplication(
    pid: Int32,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>
) -> Set<String> {
    let removedIDs = Set(windows.lazy.filter { $0.pid == pid }.map(\.id))
    guard !removedIDs.isEmpty else { return [] }
    windows.removeAll { removedIDs.contains($0.id) }
    restoration.reconcile(state: &state, windowIDs: windows.map(\.id),
                          trackedWindowIDs: trackedWindowIDs.subtracting(removedIDs))
    return removedIDs
}

@discardableResult
func removeDestroyedWindow(
    windowID: String,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>
) -> Bool {
    guard windows.contains(where: { $0.id == windowID }) else { return false }
    windows.removeAll { $0.id == windowID }
    restoration.reconcile(state: &state, windowIDs: windows.map(\.id),
                          trackedWindowIDs: trackedWindowIDs.subtracting([windowID]))
    return true
}

@discardableResult
func removeUnavailableWindow(
    windowID: String,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>
) -> Bool {
    guard windows.contains(where: { $0.id == windowID }) else { return false }
    windows.removeAll { $0.id == windowID }
    restoration.reconcile(
        state: &state,
        windowIDs: windows.map(\.id),
        trackedWindowIDs: trackedWindowIDs
    )
    return true
}

@discardableResult
func restoreAvailableWindow(
    _ window: WindowRecord,
    windows: inout [WindowRecord],
    state: inout WorkspaceState,
    restoration: inout WorkspaceRestoration,
    trackedWindowIDs: Set<String>,
    initialWidthFractions: [String: Double] = [:]
) -> Bool {
    guard !windows.contains(where: { $0.id == window.id }) else { return false }
    windows.append(window)
    restoration.reconcile(
        state: &state,
        windowIDs: windows.map(\.id),
        trackedWindowIDs: trackedWindowIDs,
        initialWidthFractions: initialWidthFractions
    )
    return true
}

@MainActor
func writeRibbonPositions(
    frames: [String: CGRect],
    writtenPositions: inout [String: CGPoint],
    backingScaleFactor: CGFloat,
    setPosition: (String, CGPoint) -> Bool
) {
    for (windowID, frame) in frames {
        let position = RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: backingScaleFactor)
        if writtenPositions[windowID] == position { continue }
        if setPosition(windowID, position) {
            writtenPositions[windowID] = position
        } else {
            // AX writes during animation are presentation hints. Leave the value
            // unwritten so a later display tick can retry, then verify at commit.
            writtenPositions.removeValue(forKey: windowID)
        }
    }
}

@MainActor
func commitRibbonPositions(
    frames: [String: CGRect],
    backingScaleFactor: CGFloat,
    setPosition: (String, CGPoint) -> Bool,
    observedFrame: (String) -> CGRect?
) -> [RibbonPositionWriteFailure] {
    frames.compactMap { windowID, frame in
        let position = RibbonMotion.pixelAligned(frame.origin, backingScaleFactor: backingScaleFactor)
        if let actual = observedFrame(windowID), ribbonPositionMatches(actual.origin, position) { return nil }
        _ = setPosition(windowID, position)
        let actual = observedFrame(windowID)
        guard actual.map({ ribbonPositionMatches($0.origin, position) }) != true else { return nil }
        return RibbonPositionWriteFailure(windowID: windowID, requestedFrame: frame, actualFrame: actual)
    }
}

private func ribbonPositionMatches(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 1) -> Bool {
    lhs.x.isFinite && lhs.y.isFinite && rhs.x.isFinite && rhs.y.isFinite &&
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

@MainActor
func parkWindow(
    windowID: String,
    park: (String) -> Bool,
    observedFrame: (String) -> CGRect?,
    unavailability: (String) -> WindowUnavailability? = { _ in nil },
    canRetry: () -> Bool = { true }
) async -> WindowParkingOutcome {
    for delay in [Duration.zero, .milliseconds(8), .milliseconds(24), .milliseconds(56)] {
        if delay != .zero {
            do { try await Task.sleep(for: delay) }
            catch { return .deferred }
        }
        guard !Task.isCancelled, canRetry() else { return .deferred }
        if park(windowID) { return .parked }
        if let reason = unavailability(windowID) { return .unavailable(reason) }
        if observedFrame(windowID) == nil { return .deferred }
    }
    return .failed
}
