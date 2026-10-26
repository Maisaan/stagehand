import AppKit
import Carbon
import os
import StagehandCore
import Testing
@testable import StagehandPlatform

private func contacts(count: Int = 3, dx: Double = 0, dy: Double = 0) -> [GestureContact] {
    (0 ..< count).map {
        GestureContact(id: Int32($0), x: 0.3 + Double($0) * 0.08 + dx, y: 0.4 + dy)
    }
}

@Test func shortcutSwipeStartsOnlyForAnEnabledArrowChord() {
    let baseFlags: CGEventFlags = [.maskControl, .maskAlternate]
    let commandFlags = baseFlags.union(.maskCommand)
    let bindings = ShortcutBinding.defaults
    #expect(shortcutGestureModifiers(for: baseFlags, bindings: bindings) == UInt32(controlKey | optionKey))
    #expect(shortcutGestureModifiers(for: commandFlags, bindings: bindings) == UInt32(controlKey | optionKey | cmdKey))
    #expect(shortcutGestureModifiers(for: [], bindings: bindings) == nil)
    #expect(shortcutGestureModifiers(for: [.maskControl], bindings: bindings) == nil)
    #expect(shortcutGestureModifiers(for: baseFlags.union(.maskShift), bindings: bindings) == nil)
}

@Test func shortcutSwipesUseTheOppositeArrowForEveryDirection() throws {
    let modifiers = UInt32(cmdKey | controlKey | optionKey)
    #expect(gestureShortcutAction(
        axis: .horizontal,
        displacement: -0.1,
        modifiers: modifiers,
        bindings: ShortcutBinding.defaults
    ) == .reorderNext)
    #expect(gestureShortcutAction(
        axis: .horizontal,
        displacement: 0.1,
        modifiers: modifiers,
        bindings: ShortcutBinding.defaults
    ) == .reorderPrevious)
    #expect(gestureShortcutAction(
        axis: .vertical,
        displacement: 0.1,
        modifiers: modifiers,
        bindings: ShortcutBinding.defaults
    ) == .moveWindowDownSpace)
    #expect(gestureShortcutAction(
        axis: .vertical,
        displacement: -0.1,
        modifiers: modifiers,
        bindings: ShortcutBinding.defaults
    ) == .moveWindowUpSpace)
    let base = UInt32(controlKey | optionKey)
    #expect(gestureShortcutAction(
        axis: .horizontal, displacement: -0.1, modifiers: base, bindings: ShortcutBinding.defaults
    ) == .focusNext)
    #expect(gestureShortcutAction(
        axis: .horizontal, displacement: 0.1, modifiers: base, bindings: ShortcutBinding.defaults
    ) == .focusPrevious)
    #expect(gestureShortcutAction(
        axis: .vertical, displacement: 0.1, modifiers: base, bindings: ShortcutBinding.defaults
    ) == .nextSpace)
    #expect(gestureShortcutAction(
        axis: .vertical, displacement: -0.1, modifiers: base, bindings: ShortcutBinding.defaults
    ) == .previousSpace)
    var bindings = ShortcutBinding.defaults
    let nextIndex = try #require(bindings.firstIndex { $0.id == "reorderNext" })
    bindings[nextIndex].isEnabled = false
    #expect(gestureShortcutAction(
        axis: .horizontal, displacement: -0.1, modifiers: modifiers, bindings: bindings
    ) == nil)
    let settingsIndex = try #require(bindings.firstIndex { $0.id == "showSettings" })
    bindings[settingsIndex].key = UInt32(kVK_DownArrow)
    bindings[settingsIndex].modifiers = modifiers | UInt32(shiftKey)
    #expect(gestureShortcutAction(
        axis: .vertical, displacement: 0.1, modifiers: modifiers | UInt32(shiftKey), bindings: bindings
    ) == .showSettings)
}

@Test func directionToggleRestoresMatchingArrowSwipesWithoutChangingKeyboardBindings() throws {
    let modifiers = UInt32(cmdKey | controlKey | optionKey)
    var bindings = ShortcutBinding.defaults
    #expect(gestureShortcutAction(axis: .horizontal, displacement: -0.1,
                                  modifiers: modifiers, bindings: bindings,
                                  reverseDirection: false) == .reorderPrevious)
    #expect(gestureShortcutAction(axis: .horizontal, displacement: 0.1,
                                  modifiers: modifiers, bindings: bindings,
                                  reverseDirection: false) == .reorderNext)
    #expect(gestureShortcutAction(axis: .vertical, displacement: 0.1,
                                  modifiers: modifiers, bindings: bindings,
                                  reverseDirection: false) == .moveWindowUpSpace)
    #expect(gestureShortcutAction(axis: .vertical, displacement: -0.1,
                                  modifiers: modifiers, bindings: bindings,
                                  reverseDirection: false) == .moveWindowDownSpace)
    #expect(ShortcutBinding.action(forKey: UInt32(kVK_LeftArrow), modifiers: modifiers,
                                   in: bindings) == .reorderPrevious)
    let settingsIndex = try #require(bindings.firstIndex { $0.id == "showSettings" })
    bindings[settingsIndex].key = UInt32(kVK_UpArrow)
    bindings[settingsIndex].modifiers = modifiers | UInt32(shiftKey)
    #expect(gestureShortcutAction(axis: .vertical, displacement: 0.1,
                                  modifiers: modifiers | UInt32(shiftKey), bindings: bindings,
                                  reverseDirection: false) == .showSettings)
}

@Test func adjacentSpaceBindingsWorkForKeysAndCanBeDisabledForSwipes() throws {
    let modifiers = UInt32(cmdKey | controlKey | optionKey)
    var bindings = ShortcutBinding.defaults
    #expect(ShortcutBinding.action(forKey: UInt32(kVK_UpArrow), modifiers: modifiers,
                                   in: bindings) == .moveWindowUpSpace)
    #expect(ShortcutBinding.action(forKey: UInt32(kVK_DownArrow), modifiers: modifiers,
                                   in: bindings) == .moveWindowDownSpace)
    let downIndex = try #require(bindings.firstIndex { $0.id == "moveWindowDownSpace" })
    bindings[downIndex].isEnabled = false
    #expect(ShortcutBinding.action(forKey: UInt32(kVK_DownArrow), modifiers: modifiers,
                                   in: bindings) == nil)
    #expect(gestureShortcutAction(axis: .vertical, displacement: 0.1,
                                  modifiers: modifiers, bindings: bindings) == nil)
}

@Test func configuredGestureRecognizesSlowMovementAndResets() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    var began = false
    for frame in 1 ... 120 {
        let displacement = Double(frame) / 1_200
        if case .began = recognizer.update(
            contacts: contacts(dx: -displacement),
            timestamp: Double(frame) / 60
        ) {
            began = true
        }
    }
    #expect(began)
    guard case .ended(_, _, let action, _) = recognizer.update(contacts: [], timestamp: 2.1) else {
        Issue.record("Slow gesture did not complete")
        return
    }
    #expect(action == .focusNext)
    #expect(!recognizer.hasContactSequence)
}

private func suppressed(_ ownership: inout GestureInputOwnership, _ event: SuppressibleInputEvent,
                        now: TimeInterval) -> Bool {
    ownership.suppress(event, now: now)
}

@Test func inputOwnershipStartsOnLandingAndLastsUntilEveryFingerLifts() {
    var ownership = GestureInputOwnership()
    #expect(!suppressed(&ownership, .liveBegan, now: 1))
    ownership.observe(contactCount: 2, fingerCount: 3, eligible: true, now: 1)
    #expect(!suppressed(&ownership, .live, now: 1.001))
    #expect(!suppressed(&ownership, .gesture, now: 1.001))
    // The third finger lands: both event families are withheld before any movement.
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 1.01)
    #expect(suppressed(&ownership, .liveBegan, now: 1.011))
    #expect(suppressed(&ownership, .gesture, now: 1.011))
    // A finger lifting early (the recognizer would cancel) does not hand the rest of the
    // sequence to the app.
    ownership.observe(contactCount: 2, fingerCount: 3, eligible: true, now: 1.05)
    #expect(suppressed(&ownership, .live, now: 1.051))
    #expect(suppressed(&ownership, .gesture, now: 1.051))
    // Everything lifts. The sequence's terminal touch event, which may arrive after the
    // zero-contact frame, is still withheld; live scrolling resumes.
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 1.1)
    #expect(suppressed(&ownership, .gesture, now: 1.101))
    #expect(!suppressed(&ownership, .liveBegan, now: 1.102))
    #expect(!suppressed(&ownership, .live, now: 1.103))
    // New contacts end the tail: their touches reach the app.
    ownership.observe(contactCount: 2, fingerCount: 3, eligible: true, now: 1.12)
    #expect(!suppressed(&ownership, .gesture, now: 1.121))
}

@Test func inputOwnershipKeepsMomentumFromAnOwnedLiftUntilItEnds() {
    var ownership = GestureInputOwnership()
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 1)
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 1.1)
    #expect(suppressed(&ownership, .momentumBegan, now: 1.15))
    // A long momentum tail outlasts the window after the lift and is still withheld.
    var time = 1.15
    while time < 1.1 + momentumSuppressionWindow + 0.5 {
        time += 0.016
        #expect(suppressed(&ownership, .momentum, now: time))
    }
    #expect(suppressed(&ownership, .momentumEnded, now: time + 0.016))
    // After the end phase the next momentum stream is the app's.
    #expect(!suppressed(&ownership, .momentumBegan, now: time + 0.5))
    #expect(!suppressed(&ownership, .momentum, now: time + 0.52))
}

@Test func inputOwnershipMomentumClaimEndsWithANewScrollOrSilence() {
    var ownership = GestureInputOwnership()
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 1)
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 1.1)
    #expect(suppressed(&ownership, .momentumBegan, now: 1.12))
    #expect(suppressed(&ownership, .momentum, now: 1.14))
    // A new two-finger scroll begins: its stream, momentum included, is the app's.
    #expect(!suppressed(&ownership, .liveBegan, now: 1.3))
    #expect(!suppressed(&ownership, .momentumBegan, now: 1.4))
    // Momentum that went silent for longer than the inactivity interval is a new stream.
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 2)
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 2.1)
    #expect(suppressed(&ownership, .momentumBegan, now: 2.12))
    #expect(!suppressed(&ownership, .momentum, now: 2.12 + GestureInputOwnership.momentumInactivityInterval + 0.01))
    // A lift with no momentum within the window claims nothing later.
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 3)
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 3.1)
    #expect(!suppressed(&ownership, .momentumBegan, now: 3.1 + momentumSuppressionWindow + 0.01))
}

@Test func inputOwnershipLeavesARapidFollowingFlickItsMomentum() {
    for beginPhase: Int64 in [1, 128] {
        var ownership = GestureInputOwnership()
        ownership.observe(contactCount: 3, fingerCount: 3, eligible: true, now: 10)
        ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 10.1)
        #expect(suppressed(&ownership, .momentumBegan, now: 10.11))
        // Two fingers land and flick within the window after the owned lift.
        ownership.observe(contactCount: 2, fingerCount: 3, eligible: true, now: 10.12)
        #expect(!suppressed(&ownership, .scroll(phase: beginPhase, momentumPhase: 0), now: 10.13))
        #expect(!suppressed(&ownership, .live, now: 10.15))
        ownership.observe(contactCount: 0, fingerCount: 3, eligible: true, now: 10.2)
        #expect(!suppressed(&ownership, .momentumBegan, now: 10.21), "phase \(beginPhase)")
        #expect(!suppressed(&ownership, .momentum, now: 10.4), "phase \(beginPhase)")
    }
}

@Test func inputOwnershipSkipsSequencesHandedToTheAppAndStaleFrames() {
    var ownership = GestureInputOwnership()
    // A shortcut swipe landing without its modifiers belongs to the app for the whole sequence.
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: false, now: 1)
    #expect(!suppressed(&ownership, .liveBegan, now: 1.001))
    ownership.observe(contactCount: 3, fingerCount: 3, eligible: false, now: 1.02)
    #expect(!suppressed(&ownership, .gesture, now: 1.021))
    ownership.observe(contactCount: 0, fingerCount: 3, eligible: false, now: 1.04)
    #expect(!suppressed(&ownership, .gesture, now: 1.041))
    #expect(!suppressed(&ownership, .momentumBegan, now: 1.05))
    // Four fingers are at least three: macOS owns the swipe, and the app gets no scroll.
    ownership.observe(contactCount: 4, fingerCount: 3, eligible: true, now: 2)
    #expect(suppressed(&ownership, .live, now: 2.001))
    // If frames stop arriving, the app's input recovers after the stale interval.
    #expect(suppressed(&ownership, .live, now: 2 + inputSuppressionStaleInterval - 0.01))
    #expect(!suppressed(&ownership, .live, now: 2 + inputSuppressionStaleInterval + 0.01))
    #expect(!suppressed(&ownership, .gesture, now: 2 + inputSuppressionStaleInterval + 0.01))
}

private func touches(_ contacts: [GestureContact], frame: Int32) -> [GestureFrameValidator.Touch] {
    contacts.map { .init(frame: frame, state: 4, x: Float($0.x), y: Float($0.y), isTouching: true) }
}

private func enabledCallbackState(unmodified: Bool = true, shortcut: Bool = false) -> GestureCallbackState {
    var state = GestureCallbackState()
    state.enabled = true
    state.recognizer = NavigationGestureRecognizer(fingerCount: 3)
    state.unmodifiedEnabled = unmodified
    state.shortcutEnabled = shortcut
    state.shortcutBindings = ShortcutBinding.defaults
    return state
}

@Test func contactFrameProcessingOwnsInputOnLandingAndReleasesOnLift() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time)
        frame += 1
    }
    feed(contacts(count: 2), at: 1)
    #expect(!suppressed(&state.ownership, .liveBegan, now: 1.001))
    feed(contacts(), at: 1.01)
    #expect(suppressed(&state.ownership, .liveBegan, now: 1.011))
    #expect(!state.recognizer.isDragging)
    // Movement that the recognizer rejects as incoherent keeps the sequence owned.
    var moved = contacts(dx: -0.12)
    moved[0].x += 0.16
    moved[2].x -= 0.16
    feed(moved, at: 1.3)
    #expect(state.recognizer.cancellationReason == "incoherent-movement")
    #expect(suppressed(&state.ownership, .live, now: 1.301))
    #expect(suppressed(&state.ownership, .gesture, now: 1.301))
    // A corrupt frame (timestamp going backwards) is dropped without releasing ownership.
    feed(contacts(dx: -0.13), at: 1.2)
    #expect(suppressed(&state.ownership, .live, now: 1.302))
    feed([], at: 1.4)
    #expect(!suppressed(&state.ownership, .live, now: 1.401))
    #expect(suppressed(&state.ownership, .gesture, now: 1.401))
    #expect(suppressed(&state.ownership, .momentumBegan, now: 1.42))
}

@Test func contactFrameProcessingLeavesShortcutSwipesWithoutModifiersToTheApp() {
    var state = enabledCallbackState(unmodified: false, shortcut: true)
    let landed = contacts()
    _ = state.process(contacts: landed, touches: touches(landed, frame: 1), rawCount: 3,
                      flags: [], timestamp: 1, now: 1)
    #expect(state.ignoredUntilLift)
    #expect(!suppressed(&state.ownership, .liveBegan, now: 1.001))
    #expect(!suppressed(&state.ownership, .gesture, now: 1.001))
    let moved = contacts(dx: -0.1)
    _ = state.process(contacts: moved, touches: touches(moved, frame: 2), rawCount: 3,
                      flags: [], timestamp: 1.1, now: 1.1)
    #expect(!suppressed(&state.ownership, .live, now: 1.101))
    _ = state.process(contacts: [], touches: [], rawCount: 0, flags: [], timestamp: 1.2, now: 1.2)
    #expect(!state.ignoredUntilLift)
    #expect(!suppressed(&state.ownership, .momentumBegan, now: 1.21))
    // With the bound modifiers held, the same landing is owned.
    _ = state.process(contacts: landed, touches: touches(landed, frame: 3), rawCount: 3,
                      flags: [.maskControl, .maskAlternate], timestamp: 2, now: 2)
    #expect(suppressed(&state.ownership, .liveBegan, now: 2.001))
}

@Test func inputTapMaskCoversScrollAndTheGestureFamily() {
    // Left-mouse drags are seen only to tell macOS's from Stagehand's, and always passed.
    for type: UInt32 in [CGEventType.scrollWheel.rawValue, 19, 20, 29, 30, 31,
                         CGEventType.leftMouseDragged.rawValue] {
        #expect(suppressibleEventTypeMask & (CGEventMask(1) << CGEventMask(type)) != 0, "type \(type)")
    }
    for type: UInt32 in [CGEventType.keyDown.rawValue, CGEventType.leftMouseDown.rawValue,
                         CGEventType.leftMouseUp.rawValue, CGEventType.mouseMoved.rawValue] {
        #expect(suppressibleEventTypeMask & (CGEventMask(1) << CGEventMask(type)) == 0, "type \(type)")
    }
}

@Test func gestureRejectsIncoherentMovementBeforeAxisLock() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    var moved = contacts(dx: -0.12)
    moved[0].x += 0.16
    moved[2].x -= 0.16
    #expect(recognizer.update(contacts: moved, timestamp: 0.3) == nil)
    #expect(recognizer.cancellationReason == "incoherent-movement")
    #expect(recognizer.update(contacts: [], timestamp: 0.31) == nil)
}

@Test func gestureReversalDoesNotCommitAStaleFlick() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
    _ = recognizer.update(contacts: contacts(dx: -0.06), timestamp: 0.2)
    _ = recognizer.update(contacts: contacts(dx: -0.02), timestamp: 0.22)
    guard case .ended(let displacement, let velocity, let action, _) = recognizer.update(
        contacts: [], timestamp: 0.23
    ) else {
        Issue.record("Reversed gesture did not complete")
        return
    }
    #expect(abs(displacement + 0.02) < 0.001)
    #expect(velocity > 0)
    #expect(action == nil)
}

@Test func malformedPartialLiftCancelsInsteadOfNavigating() {
    var recognizer = NavigationGestureRecognizer(fingerCount: 3)
    _ = recognizer.update(contacts: contacts(), timestamp: 0)
    _ = recognizer.update(contacts: contacts(dx: -0.1), timestamp: 0.1)
    var remaining = contacts(count: 2, dx: -0.1)
    remaining[0].id = remaining[1].id
    #expect(recognizer.update(contacts: remaining, timestamp: 0.11) == .cancelled)
}

@Test func gestureBufferKeepsBoundariesAndOnlyTheLatestDragFrame() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: 0.02, mode: .plain))
    for index in 0 ..< 100 {
        pending.append(.changed(displacement: Double(index) / 1_000, velocity: 1))
    }
    pending.append(.ended(displacement: 0.099, velocity: 1, action: .focusPrevious, mode: .plain))
    #expect(pending.drain() == [
        .began(axis: .horizontal, displacement: 0.02, mode: .plain),
        .changed(displacement: 0.099, velocity: 1),
        .ended(displacement: 0.099, velocity: 1, action: .focusPrevious, mode: .plain),
    ])
}

@Test func shortcutSwipeCompletionKeepsReorderActionBeforeKeyboardDelivery() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: -0.02, mode: .shortcut))
    pending.append(.ended(displacement: -0.1, velocity: -1, action: .reorderPrevious, mode: .shortcut))
    let completion = pending.takeCompletion()
    #expect(completion?.recognizerAction == .reorderPrevious)
    #expect(completion?.mode == .shortcut)
    #expect(pending.drain().isEmpty)
}

@Test(arguments: [
    (kVK_ANSI_Minus, CGEventFlags([.maskControl, .maskAlternate]), NavigationAction.shrinkWidth),
    (kVK_ANSI_Equal, CGEventFlags([.maskControl, .maskAlternate, .maskShift]), .growWidth),
    (kVK_ANSI_Minus, CGEventFlags([.maskControl, .maskAlternate, .maskCommand]), .shrinkHeight),
    (kVK_ANSI_Equal, CGEventFlags([.maskControl, .maskAlternate, .maskCommand, .maskShift]), .growHeight),
    (kVK_ANSI_0, CGEventFlags([.maskControl, .maskAlternate]), .nextWidthPreset),
    (kVK_ANSI_0, CGEventFlags([.maskControl, .maskAlternate, .maskShift]), .previousWidthPreset),
])
func sizeShortcutChordsResolve(key: Int, flags: CGEventFlags, action: NavigationAction) throws {
    let event = try #require(CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(key),
        keyDown: true
    ))
    event.flags = flags
    #expect(ShortcutBinding.action(for: event) == action)
}

@Test func persistedShortcutsRejectUnsafeAndDuplicateChords() throws {
    let suiteName = "ShortcutBindingValidationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var bindings = ShortcutBinding.defaults
    let focusNext = try #require(bindings.firstIndex { $0.id == "focusNext" })
    bindings[focusNext].key = UInt32(kVK_ANSI_K)
    bindings[focusNext].modifiers = 0
    bindings[focusNext].keyLabel = "K"
    let settings = try #require(bindings.firstIndex { $0.id == "showSettings" })
    let previous = try #require(bindings.first { $0.id == "focusPrevious" })
    bindings[settings].key = previous.key
    bindings[settings].modifiers = previous.modifiers
    bindings[settings].keyLabel = previous.keyLabel
    let saved = bindings.map {
        ["id": $0.id, "key": $0.key, "modifiers": $0.modifiers,
         "keyLabel": $0.keyLabel, "isEnabled": $0.isEnabled] as [String: Any]
    }
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: ShortcutBinding.preferenceKey)
    defaults.set(1, forKey: "shortcutBindingsVersion")

    let result = ShortcutBinding.loadReportingIssues(from: defaults)
    let loaded = result.bindings
    // An unsafe saved chord reverts to the default chord but stays off until the user re-enables it.
    var expectedNext = try #require(ShortcutBinding.defaultBinding(id: "focusNext"))
    expectedNext.isEnabled = false
    #expect(loaded.first { $0.id == "focusNext" } == expectedNext)
    #expect(loaded.first { $0.id == "focusPrevious" }?.isEnabled == true)
    #expect(loaded.first { $0.id == "showSettings" }?.isEnabled == false)
    #expect(result.issues.count == 2)
    #expect(result.issues[0].hasPrefix("Next window was turned off"))
    #expect(result.issues[1].hasPrefix("Open settings was turned off"))
    #expect(ShortcutBinding.loadReportingIssues(from: defaults).bindings == loaded)
}

@Test(arguments: [
    (kVK_ANSI_K, UInt32(shiftKey), false),
    (kVK_ANSI_K, UInt32(alphaLock), false),
    (kVK_ANSI_K, UInt32(shiftKey | alphaLock), false),
    (kVK_ANSI_K, 0, false),
    (kVK_ANSI_K, UInt32(controlKey), true),
    (kVK_ANSI_K, UInt32(optionKey | shiftKey), true),
    (kVK_ANSI_K, UInt32(cmdKey | alphaLock), true),
    (kVK_ANSI_Q, UInt32(cmdKey), false),
    (kVK_ANSI_Q, UInt32(cmdKey | alphaLock), false),
    (kVK_ANSI_Q, UInt32(cmdKey | shiftKey), true),
    (kVK_ANSI_W, UInt32(cmdKey), false),
    (kVK_Tab, UInt32(cmdKey), false),
    (kVK_Space, UInt32(cmdKey), false),
    (kVK_ANSI_H, UInt32(cmdKey), false),
    (kVK_ANSI_M, UInt32(cmdKey), false),
    (kVK_ANSI_Q, UInt32(controlKey | cmdKey), false),
    (kVK_Escape, UInt32(optionKey | cmdKey), false),
    (0x80, UInt32(controlKey), false),
    (kVK_ANSI_K, UInt32(controlKey | 1 << 20), false),
])
func shortcutValidationRequiresARealModifierAndSparesSystemChords(key: Int, modifiers: UInt32, valid: Bool) {
    let issue = ShortcutBinding.validationIssue(key: UInt32(key), modifiers: modifiers, keyLabel: "K")
    #expect((issue == nil) == valid, "\(String(describing: issue))")
}

@Test func everyDefaultShortcutPassesValidation() {
    for binding in ShortcutBinding.defaults {
        #expect(ShortcutBinding.validationIssue(key: binding.key, modifiers: binding.modifiers,
                                                keyLabel: binding.keyLabel) == nil, Comment(rawValue: binding.id))
    }
}

@Test func chordsThatDifferOnlyByCapsLockConflict() throws {
    var bindings = ShortcutBinding.defaults
    let index = try #require(bindings.firstIndex { $0.id == "focusNext" })
    bindings[index].key = UInt32(kVK_ANSI_K)
    bindings[index].modifiers = UInt32(controlKey)
    bindings[index].keyLabel = "K"
    #expect(ShortcutBinding.conflict(in: bindings, key: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | alphaLock),
                                     excluding: "focusPrevious")?.id == "focusNext")
    #expect(ShortcutBinding.conflict(in: bindings, key: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey),
                                     excluding: "focusNext") == nil)
    #expect(ShortcutBinding.conflict(in: bindings, key: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey),
                                     excluding: "focusPrevious") == nil)
}

@Test func loadTurnsOffOutOfRangeKeysAndCapsLockDuplicates() throws {
    let suiteName = "ShortcutBindingLoadTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var bindings = ShortcutBinding.defaults
    let grow = try #require(bindings.firstIndex { $0.id == "growWidth" })
    bindings[grow].key = 0x1FF
    bindings[grow].keyLabel = "?"
    let settings = try #require(bindings.firstIndex { $0.id == "showSettings" })
    let previous = try #require(bindings.first { $0.id == "focusPrevious" })
    bindings[settings].key = previous.key
    bindings[settings].modifiers = previous.modifiers | UInt32(alphaLock)
    bindings[settings].keyLabel = previous.keyLabel
    let saved = bindings.map {
        ["id": $0.id, "key": $0.key, "modifiers": $0.modifiers,
         "keyLabel": $0.keyLabel, "isEnabled": $0.isEnabled] as [String: Any]
    }
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: ShortcutBinding.preferenceKey)
    defaults.set(1, forKey: "shortcutBindingsVersion")

    let result = ShortcutBinding.loadReportingIssues(from: defaults)
    #expect(result.bindings.first { $0.id == "growWidth" }?.isEnabled == false)
    #expect(result.bindings.first { $0.id == "growWidth" }?.key == ShortcutBinding.defaultBinding(id: "growWidth")?.key)
    #expect(result.bindings.first { $0.id == "showSettings" }?.isEnabled == false)
    #expect(result.bindings.first { $0.id == "focusPrevious" }?.isEnabled == true)
    #expect(result.issues.count == 2)
    #expect(result.issues.contains { $0.contains("Open settings") && $0.contains("Previous window") })
}

@Test func legacyWidthDefaultsMigrateWithoutOverwritingCustomBindings() throws {
    let suiteName = "ShortcutBindingMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var bindings = ShortcutBinding.defaults
    let shrink = try #require(bindings.firstIndex { $0.id == "shrinkWidth" })
    bindings[shrink].key = UInt32(kVK_ANSI_1)
    bindings[shrink].modifiers = UInt32(optionKey | cmdKey)
    bindings[shrink].keyLabel = "1"
    let grow = try #require(bindings.firstIndex { $0.id == "growWidth" })
    bindings[grow].key = UInt32(kVK_ANSI_K)
    bindings[grow].modifiers = UInt32(controlKey)
    bindings[grow].keyLabel = "K"
    let saved = bindings.map {
        ["id": $0.id, "key": $0.key, "modifiers": $0.modifiers,
         "keyLabel": $0.keyLabel, "isEnabled": $0.isEnabled] as [String: Any]
    }
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: ShortcutBinding.preferenceKey)

    let loaded = ShortcutBinding.loadReportingIssues(from: defaults).bindings
    #expect(loaded.first { $0.id == "shrinkWidth" } == ShortcutBinding.defaultBinding(id: "shrinkWidth"))
    #expect(loaded.first { $0.id == "growWidth" }?.key == UInt32(kVK_ANSI_K))
    #expect(loaded.first { $0.id == "growWidth" }?.modifiers == UInt32(controlKey))
}

@Test func capsLockIsOptionalUnlessTheBindingRequiresIt() throws {
    var bindings = ShortcutBinding.defaults
    let index = try #require(bindings.firstIndex { $0.id == "focusNext" })
    bindings[index].key = UInt32(kVK_ANSI_K)
    bindings[index].modifiers = UInt32(alphaLock)
    bindings[index].keyLabel = "K"
    let event = try #require(CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(kVK_ANSI_K),
        keyDown: true
    ))
    event.flags = [.maskAlphaShift]
    #expect(ShortcutBinding.action(for: event, in: bindings) == .focusNext)
    event.flags = []
    #expect(ShortcutBinding.action(for: event, in: bindings) == nil)

    let defaultEvent = try #require(CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(kVK_RightArrow),
        keyDown: true
    ))
    defaultEvent.flags = [.maskControl, .maskAlternate, .maskAlphaShift]
    #expect(ShortcutBinding.action(for: defaultEvent) == .focusNext)
}

@MainActor @Test func focusGateUsesUpdatedAndDisabledShortcuts() throws {
    let gate = FocusInputGate(postEvent: { _, _ in })
    var bindings = ShortcutBinding.defaults
    let index = try #require(bindings.firstIndex { $0.id == "focusNext" })
    bindings[index].key = UInt32(kVK_ANSI_K)
    bindings[index].modifiers = UInt32(controlKey)
    bindings[index].keyLabel = "K"
    gate.setShortcutBindings(bindings)
    var actions: [NavigationAction] = []
    gate.onNavigationAction = { actions.append($0) }
    let event = try #require(CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(kVK_ANSI_K),
        keyDown: true
    ))
    event.flags = [.maskControl]
    #expect(gate.processKeyboardEvent(type: .keyDown, event: event))
    #expect(actions == [.focusNext])
    bindings[index].isEnabled = false
    gate.setShortcutBindings(bindings)
    #expect(!gate.processKeyboardEvent(type: .keyDown, event: event))
}

@MainActor @Test func gateReplaysEachKeyPairToItsTransferDestination() throws {
    var posted: [(event: CGEvent, pid: Int32)] = []
    let gate = FocusInputGate(postEvent: { posted.append(($0, $1)) })
    let first = gate.beginTransfer()
    let aDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: aDown))
    let second = gate.beginTransfer()
    let bDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: bDown))
    let aUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: aUp))
    gate.commitTransfer(token: first, processIdentifier: 100)
    gate.commitTransfer(token: second, processIdentifier: 200)
    let bUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: bUp))
    #expect(posted.map(\.pid) == [100, 100, 200, 200])
}

@MainActor @Test func keyboardNavigationBeginsBufferingBeforeCarbonDispatch() throws {
    var posted: [CGEvent] = []
    let gate = FocusInputGate(postEvent: { event, _ in posted.append(event) })
    var token: UInt64?
    gate.onNavigationAction = { _ in token = gate.beginTransfer() }
    let navigation = try #require(CGEvent(
        keyboardEventSource: nil,
        virtualKey: CGKeyCode(kVK_RightArrow),
        keyDown: true
    ))
    navigation.flags = [.maskControl, .maskAlternate]
    #expect(gate.processKeyboardEvent(type: .keyDown, event: navigation))
    let typing = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: typing))
    gate.commitTransfer(token: try #require(token), processIdentifier: 100)
    #expect(posted.count == 1)
    #expect(posted[0].getIntegerValueField(.keyboardEventKeycode) == 0)
}

@MainActor @Test func overflowedInputNeverReplaysToAnUnverifiedProcess() throws {
    var posted = 0
    var discarded: [Int] = []
    var expired: [UInt64] = []
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    gate.onInputDiscarded = { discarded.append($0) }
    gate.onTransferExpired = { expired.append($0) }
    let token = gate.beginTransfer()
    let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    for index in 0 ..< FocusInputGate.maximumBufferedEvents {
        #expect(gate.processKeyboardEvent(type: index.isMultiple(of: 2) ? .keyDown : .keyUp,
                                          event: index.isMultiple(of: 2) ? down : up))
    }
    #expect(gate.pendingEventCount == FocusInputGate.maximumBufferedEvents)
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    // The held events and the one that did not fit are reported once, as a single count.
    #expect(discarded == [FocusInputGate.maximumBufferedEvents + 1])
    #expect(expired == [token])
    #expect(gate.pendingEventCount == 0)
    gate.commitTransfer(token: token, processIdentifier: 100)
    #expect(posted == 0)
}

@MainActor @Test func heldKeyRepeatsAreCoalescedInsteadOfFillingTheBuffer() throws {
    var posted = 0
    var discarded = 0
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    gate.onInputDiscarded = { discarded += $0 }
    let token = gate.beginTransfer()
    let first = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: first))
    let repeated = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    for _ in 0 ..< FocusInputGate.maximumBufferedEvents + 1 {
        #expect(gate.processKeyboardEvent(type: .keyDown, event: repeated))
    }
    let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: up))
    #expect(gate.pendingEventCount == 2)
    gate.commitTransfer(token: token, processIdentifier: 100)
    #expect(posted == 2)
    #expect(discarded == 0)
}

@MainActor @Test func secureInputDuringATransferDropsHeldTypingInsteadOfReorderingIt() throws {
    let secureInput = OSAllocatedUnfairLock(initialState: false)
    var posted = 0
    var discarded: [Int] = []
    var availabilityChanges = 0
    let gate = FocusInputGate(secureInputEnabled: { secureInput.withLock { $0 } }, postEvent: { _, _ in posted += 1 })
    gate.onInputDiscarded = { discarded.append($0) }
    gate.onAvailabilityChanged = { availabilityChanges += 1 }
    let token = gate.beginTransfer()
    let aDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: aDown))
    secureInput.withLock { $0 = true }
    let bDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: true))
    #expect(!gate.processKeyboardEvent(type: .keyDown, event: bDown))
    #expect(discarded == [1])
    #expect(availabilityChanges == 1)
    #expect(gate.pendingEventCount == 0)
    // The held key's release is no longer routed anywhere: it reaches the focused window itself.
    let aUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(!gate.processKeyboardEvent(type: .keyUp, event: aUp))
    gate.commitTransfer(token: token, processIdentifier: 100)
    #expect(posted == 0)
}

@MainActor @Test func heldNavigationChordsRepeatFocusStepsButNotSpaceSteps() throws {
    let gate = FocusInputGate(postEvent: { _, _ in })
    var actions: [NavigationAction] = []
    gate.onNavigationAction = { actions.append($0) }
    func chord(_ key: Int, repeated: Bool) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true))
        event.flags = [.maskControl, .maskAlternate]
        if repeated { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        return event
    }
    #expect(gate.processKeyboardEvent(type: .keyDown, event: try chord(kVK_DownArrow, repeated: false)))
    for _ in 0 ..< 3 {
        #expect(gate.processKeyboardEvent(type: .keyDown, event: try chord(kVK_DownArrow, repeated: true)))
    }
    let downUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_DownArrow), keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: downUp))
    #expect(actions == [.nextSpace])
    #expect(gate.processKeyboardEvent(type: .keyDown, event: try chord(kVK_RightArrow, repeated: false)))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: try chord(kVK_RightArrow, repeated: true)))
    #expect(actions == [.nextSpace, .focusNext, .focusNext])
}

@MainActor @Test func transfersWithoutTypingAreCappedOldestFirst() throws {
    var posted = 0
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    defer { gate.cancelAll() }
    let typed = gate.beginTransfer()
    let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    let oldestEmpty = gate.beginTransfer()
    for _ in 0 ..< FocusInputGate.maximumActiveTransfers { _ = gate.beginTransfer() }
    // The oldest empty transfer was dropped; the one that owns typing was kept.
    #expect(!gate.cancelTransferIfEmpty(token: oldestEmpty))
    #expect(!gate.cancelTransferIfEmpty(token: typed))
    gate.commitTransfer(token: typed, processIdentifier: 100)
    #expect(posted == 1)
}

/// The tap thread holds typing that follows a trackpad release whose delivery is still
/// queued, then the release's navigation adopts that transfer on the main actor.
@MainActor @Test func typingAfterAPendingTrackpadReleaseFollowsItsNavigation() async throws {
    var posted: [Int32] = []
    let gate = FocusInputGate(installsEventTap: false, frontmostProcessIdentifier: { 77 },
                              postEvent: { _, pid in posted.append(pid) })
    gate.start()
    defer { gate.stop() }
    gate.setPendingGestureCompletionCheck { true }
    var adopted: UInt64?
    gate.onBeforeKeyboardEvent = { adopted = gate.beginTransfer() }
    let consumed = await Task.detached {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        return gate.receiveFromTap(type: .keyDown, event: down)
    }.value
    #expect(consumed)
    try await waitUntil { adopted != nil }
    #expect(gate.pendingEventCount == 1)
    gate.commitTransfer(token: try #require(adopted), processIdentifier: 99)
    #expect(posted == [99])

    // Without a navigation, the typing belongs to the window that was focused when it was typed.
    gate.onBeforeKeyboardEvent = nil
    let consumedAgain = await Task.detached {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: true)!
        return gate.receiveFromTap(type: .keyDown, event: down)
    }.value
    #expect(consumedAgain)
    try await waitUntil { posted.count == 2 }
    #expect(posted == [99, 77])
    let releaseConsumed = await Task.detached {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 11, keyDown: false)!
        return gate.receiveFromTap(type: .keyUp, event: up)
    }.value
    #expect(releaseConsumed)
    try await waitUntil { posted.count == 3 }
    #expect(posted == [99, 77, 77])
    #expect(gate.pendingEventCount == 0)
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@MainActor @Test func carbonSkipsNavigationChordsWhileTheTapConsumesThem() {
    #expect(!InputController.shouldDispatchHotKey(.focusNext, tapHandlesNavigation: true))
    #expect(!InputController.shouldDispatchHotKey(.goToSpace(index: 2), tapHandlesNavigation: true))
    #expect(InputController.shouldDispatchHotKey(.focusNext, tapHandlesNavigation: false))
    // The tap passes these through on purpose, so Carbon is their only dispatcher.
    #expect(InputController.shouldDispatchHotKey(.showSettings, tapHandlesNavigation: true))
    #expect(InputController.shouldDispatchHotKey(.togglePause, tapHandlesNavigation: true))
}

@Test func corruptContactFramesAreRejectedAndEventuallyDisableGestures() {
    var validator = GestureFrameValidator()
    func touch(frame: Int32 = 1, state: UInt32 = 4, x: Float = 0.5, y: Float = 0.5) -> GestureFrameValidator.Touch {
        .init(frame: frame, state: state, x: x, y: y, isTouching: state == 3 || state == 4)
    }
    func accept(_ timestamp: Double, _ touches: [GestureFrameValidator.Touch]) -> Bool {
        validator.accept(timestamp: timestamp, touches: touches)
    }
    #expect(accept(1, [touch()]))
    #expect(!accept(1.01, [touch(state: 9)]))
    #expect(!accept(1.02, [touch(x: 1.5)]))
    #expect(!accept(1.03, [touch(y: -0.5)]))
    #expect(!accept(1.04, [touch(x: .nan)]))
    #expect(!accept(.infinity, [touch()]))
    // A hover state may carry any position; only touching contacts are range checked.
    #expect(accept(1.05, [touch(state: 2, x: 7)]))
    #expect(validator.badFrames == 0)
    // Time running backwards counts once, then the new baseline is accepted.
    #expect(!accept(0.5, [touch()]))
    #expect(accept(0.6, [touch()]))
    #expect(!accept(0.7, [touch(frame: 0)]))
    #expect(accept(0.8, [touch(frame: 2)]))
    for index in 0 ..< GestureFrameValidator.maximumBadFrames {
        #expect(!validator.isExhausted)
        #expect(!accept(1 + Double(index), [touch(state: 200)]))
    }
    #expect(validator.isExhausted)
}

/// A chord consumed on the tap thread reserves its transfer under the lock, so typing that
/// follows while main is still busy is held for that navigation.
@MainActor @Test func typingRightAfterAShortcutIsHeldForItsNavigationWhileMainIsBusy() async throws {
    var posted: [Int32] = []
    let gate = FocusInputGate(installsEventTap: false, frontmostProcessIdentifier: { 77 },
                              postEvent: { _, pid in posted.append(pid) })
    gate.start()
    defer { gate.stop() }
    var adopted: UInt64?
    gate.onNavigationAction = { _ in adopted = gate.beginTransfer() }
    // Both events reach the tap before any main-queue hop runs.
    let consumed = await Task.detached { () -> [Bool] in
        let chord = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true)!
        chord.flags = [.maskControl, .maskAlternate]
        let typing = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        return [gate.receiveFromTap(type: .keyDown, event: chord), gate.receiveFromTap(type: .keyDown, event: typing)]
    }.value
    #expect(consumed == [true, true])
    try await waitUntil { adopted != nil }
    #expect(gate.pendingEventCount == 1)
    gate.commitTransfer(token: try #require(adopted), processIdentifier: 99)
    #expect(posted == [99])
}

@MainActor @Test func typingAfterAShortcutJoinsThatChordNotAnEarlierTransfer() async throws {
    var posted: [Int32] = []
    let gate = FocusInputGate(installsEventTap: false, postEvent: { _, pid in posted.append(pid) })
    gate.start()
    defer { gate.stop() }
    let earlier = gate.beginTransfer()
    var adopted: UInt64?
    gate.onNavigationAction = { _ in adopted = gate.beginTransfer() }
    _ = await Task.detached { () -> [Bool] in
        let chord = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true)!
        chord.flags = [.maskControl, .maskAlternate]
        let typing = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        return [gate.receiveFromTap(type: .keyDown, event: chord), gate.receiveFromTap(type: .keyDown, event: typing)]
    }.value
    try await waitUntil { adopted != nil }
    gate.commitTransfer(token: earlier, processIdentifier: 11)
    #expect(posted.isEmpty)
    gate.commitTransfer(token: try #require(adopted), processIdentifier: 22)
    #expect(posted == [22])
}

@MainActor @Test func unclaimedShortcutReservationReturnsTypingToTheFocusedProcess() async throws {
    var posted: [Int32] = []
    let gate = FocusInputGate(installsEventTap: false, frontmostProcessIdentifier: { 77 },
                              postEvent: { _, pid in posted.append(pid) })
    gate.start()
    defer { gate.stop() }
    gate.onNavigationAction = { _ in }
    _ = await Task.detached { () -> [Bool] in
        let chord = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_RightArrow), keyDown: true)!
        chord.flags = [.maskControl, .maskAlternate]
        let typing = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        return [gate.receiveFromTap(type: .keyDown, event: chord), gate.receiveFromTap(type: .keyDown, event: typing)]
    }.value
    try await waitUntil { posted == [77] }
    #expect(gate.pendingEventCount == 0)
}

@Test func drainedReleasesStayPendingUntilTheirHandoffReturns() {
    var pending = GestureEventBuffer()
    pending.append(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
    pending.append(.ended(displacement: -0.1, velocity: -1, action: .focusNext, mode: .plain))
    #expect(pending.hasCompletion)
    #expect(pending.drain().count == 2)
    // The .began may do slow preview work on main before the .ended begins its transfer.
    #expect(pending.hasCompletion)
    #expect(pending.completionsInFlight == 1)
    pending.completionDelivered()
    #expect(!pending.hasCompletion)
    // Dropping a sequence does not count its release as work in flight.
    pending.append(.began(axis: .horizontal, displacement: -0.02, mode: .plain))
    pending.append(.ended(displacement: -0.1, velocity: -1, action: .focusNext, mode: .plain))
    pending.removeAll()
    #expect(!pending.hasCompletion)
}

/// A key that reaches the tap while a committed transfer is still being replayed goes to
/// the same process through the main queue, after the replay, instead of passing through.
@MainActor @Test func typingDuringReplayFollowsTheReplayInOrder() async throws {
    final class Sink: @unchecked Sendable {
        var gate: FocusInputGate?
        var posted: [(key: Int64, pid: Int32)] = []
        var consumedDuringReplay: Bool?
    }
    let sink = Sink()
    let gate = FocusInputGate(installsEventTap: false, postEvent: { event, pid in
        sink.posted.append((event.getIntegerValueField(.keyboardEventKeycode), pid))
        // The tap thread lands a fresh key in the middle of the replay loop.
        if sink.posted.count == 1, let gate = sink.gate {
            let fresh = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
            sink.consumedDuringReplay = gate.receiveFromTap(type: .keyDown, event: fresh)
        }
    })
    sink.gate = gate
    gate.start()
    defer { gate.stop() }
    let token = gate.beginTransfer()
    for key in [0, 1] as [CGKeyCode] {
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    }
    gate.commitTransfer(token: token, processIdentifier: 55)
    #expect(sink.consumedDuringReplay == true)
    try await waitUntil { sink.posted.count == 3 }
    #expect(sink.posted.map(\.key) == [0, 1, 9])
    #expect(sink.posted.map(\.pid) == [55, 55, 55])
    // Its release follows the same route; a key pressed after the replay passes through.
    let freshUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: freshUp))
    let later = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 10, keyDown: true))
    #expect(!gate.processKeyboardEvent(type: .keyDown, event: later))
    #expect(sink.posted.map(\.key) == [0, 1, 9, 9])
}

@MainActor @Test func emptyTransferCancellationKeepsTypingCapturedMeanwhile() throws {
    // The check and the removal share one lock section; a key captured just before the
    // call is seen by the check, and the transfer with typing is kept for verification.
    var posted = 0
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    let token = gate.beginTransfer()
    let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    #expect(!gate.cancelTransferIfEmpty(token: token))
    #expect(gate.pendingEventCount == 1)
    gate.commitTransfer(token: token, processIdentifier: 5)
    #expect(posted == 1)
}

/// Carrying a file: one finger holds a click while three others swipe. The held finger
/// made four contacts, more than a three-finger swipe, so the swipe never began.
@Test func aHeldClickIsLeftOutSoTheOtherFingersCanSwipe() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
    }
    let held = GestureContact(id: 9, x: 0.5, y: 0.1)
    func swipe(from start: Double) -> [GestureNavigationEvent] {
        feed([held] + contacts(), at: start, buttonDown: true)
        feed([held] + contacts(dx: -0.05), at: start + 0.05, buttonDown: true)
        feed([held] + contacts(dx: -0.12), at: start + 0.1, buttonDown: true)
        feed([held], at: start + 0.15, buttonDown: true)
        return state.pendingEvents.drain()
    }
    feed([held], at: 1, buttonDown: false)
    feed([held], at: 1.01, buttonDown: true)
    #expect(state.heldClickContactIDs == [9])

    let first = swipe(from: 1.1)
    #expect(first.contains { if case .began(.horizontal, _, .plain) = $0 { true } else { false } })
    #expect(first.contains { if case .ended(_, _, .focusNext?, .plain) = $0 { true } else { false } })
    // The press carries on, and so does the next swipe; a drop does not cancel it.
    let second = swipe(from: 2)
    #expect(second.contains { if case .ended(_, _, .focusNext?, .plain) = $0 { true } else { false } })
    feed([held] + contacts(), at: 3, buttonDown: false)
    #expect(state.heldClickContactIDs == [9])
    feed([], at: 3.1, buttonDown: false)
    #expect(state.heldClickContactIDs.isEmpty)
}

/// A swipe that presses the pad partway keeps its fingers, and fingers that land while
/// a mouse button is already held are not taken for a held click.
@Test func onlyAFingerAlreadyTouchingBeforeThePressIsAHeldClick() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
    }
    feed(contacts(), at: 1, buttonDown: false)
    feed(contacts(dx: -0.05), at: 1.05, buttonDown: false)
    feed(contacts(dx: -0.08), at: 1.08, buttonDown: true)
    #expect(state.heldClickContactIDs.isEmpty)
    feed([], at: 1.1, buttonDown: true)
    #expect(state.pendingEvents.drain().contains { if case .ended(_, _, .focusNext?, _) = $0 { true } else { false } })

    // A mouse held with no fingers down sends no frames: the last frame had the button
    // up, and the first landing frame sees it down. Fingers land one at a time.
    feed([], at: 1.9, buttonDown: false)
    feed(Array(contacts().prefix(1)), at: 2, buttonDown: true)
    feed(contacts(), at: 2.01, buttonDown: true)
    #expect(state.heldClickContactIDs.isEmpty)
    feed(contacts(dx: -0.12), at: 2.1, buttonDown: true)
    feed([], at: 2.15, buttonDown: true)
    #expect(state.pendingEvents.drain().contains { if case .ended(_, _, .focusNext?, _) = $0 { true } else { false } })
}

/// A held click and a two-finger scroll are three contacts. Stagehand used to own them
/// as a three-finger sequence and withhold the scroll; the held click no longer counts.
@Test func aHeldClickDoesNotMakeATwoFingerScrollStagehands() {
    var state = enabledCallbackState()
    let held = GestureContact(id: 9, x: 0.5, y: 0.1)
    let scroll = Array(contacts().prefix(2))
    _ = state.process(contacts: [held], touches: touches([held], frame: 1), rawCount: 1,
                      flags: [], timestamp: 1, now: 1, buttonDown: false)
    _ = state.process(contacts: [held], touches: touches([held], frame: 2), rawCount: 1,
                      flags: [], timestamp: 1.01, now: 1.01, buttonDown: true)
    _ = state.process(contacts: [held] + scroll, touches: touches([held] + scroll, frame: 3), rawCount: 3,
                      flags: [], timestamp: 1.02, now: 1.02, buttonDown: true)
    #expect(!suppressed(&state.ownership, .liveBegan, now: 1.021))
}

/// A held click is still a finger to macOS: three fingers swiping beside it are four,
/// and macOS started its own four-finger swipe between Spaces, freezing the pointer and
/// the carried file. Its Dock events are withheld only beside a held click; four plain
/// fingers stay macOS's swipe.
@Test func theDockSwipeIsWithheldOnlyBesideAHeldClick() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
    }
    func withheld(_ kind: SuppressibleInputEvent, at time: Double) -> Bool { state.suppress(kind, now: time) }
    let held = GestureContact(id: 9, x: 0.5, y: 0.1)
    feed([held], at: 1, buttonDown: false)
    feed([held], at: 1.01, buttonDown: true)
    #expect(!withheld(.dockControl, at: 1.011))
    feed([held] + contacts(), at: 1.02, buttonDown: true)
    feed([held] + contacts(dx: -0.05), at: 1.07, buttonDown: true)
    #expect(withheld(.dockControl, at: 1.071))
    // The swipe fingers lift; the Dock's last event of that sequence is withheld too.
    feed([held], at: 1.12, buttonDown: true)
    #expect(withheld(.dockControl, at: 1.121))
    #expect(!withheld(.dockControl, at: 1.3))
    #expect(state.withheldDockControlEvents == 2)
    feed([], at: 1.4, buttonDown: false)

    // Four fingers without a held click: macOS's swipe between Spaces.
    let four = contacts(count: 4)
    feed(four, at: 2, buttonDown: false)
    feed(contacts(count: 4, dx: -0.05), at: 2.05, buttonDown: false)
    #expect(!withheld(.dockControl, at: 2.051))
    #expect(withheld(.liveBegan, at: 2.051))
}

@Test func aHeldClickFingersTravelIsMeasured() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
    }
    feed([GestureContact(id: 9, x: 0.5, y: 0.1)], at: 1, buttonDown: false)
    feed([GestureContact(id: 9, x: 0.5, y: 0.1)], at: 1.01, buttonDown: true)
    feed([GestureContact(id: 9, x: 0.53, y: 0.14)], at: 1.02, buttonDown: true)
    #expect(abs(state.heldClickTravel - 0.05) < 0.0001)
    // Fingers that are not the held click do not count.
    feed([GestureContact(id: 9, x: 0.53, y: 0.14)] + contacts(dx: 0.2), at: 1.03, buttonDown: true)
    #expect(abs(state.heldClickTravel - 0.05) < 0.0001)
}

/// Cancel mode passes the Dock one cancelled event per swipe beside the held click and
/// drops the rest; pass mode lets everything through; nothing changes without a held click.
@Test func dockGestureHandlingBesideAHeldClick() {
    var state = enabledCallbackState()
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool) {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
    }
    func decide(_ handling: DockSwipeHandling, phase: Int64 = 2, at time: Double) -> DockEventDecision {
        state.dockDecision(phase: phase, now: time, handling: handling)
    }
    let held = GestureContact(id: 9, x: 0.5, y: 0.1)
    feed([held], at: 1, buttonDown: false)
    feed([held], at: 1.01, buttonDown: true)
    #expect(decide(.cancel, at: 1.011) == .pass)
    feed([held] + contacts(), at: 1.02, buttonDown: true)
    #expect(decide(.cancel, phase: 1, at: 1.021) == .cancel)
    #expect(decide(.cancel, at: 1.022) == .drop)
    #expect(decide(.pass, at: 1.023) == .pass)
    #expect(decide(.withhold, at: 1.024) == .drop)
    // The second swipe of the same press gets its own cancel.
    feed([held], at: 1.1, buttonDown: true)
    feed([held] + contacts(), at: 1.5, buttonDown: true)
    #expect(decide(.cancel, phase: 1, at: 1.501) == .cancel)
    #expect(state.dockPhaseCounts[1] == 2)
}

/// Once macOS takes the held click and the fingers beside it for its own four-finger
/// gesture, it stops moving the pointer until every finger lifts; the held finger lifts
/// only at the drop. Stagehand then moves the pointer from the held finger itself, only
/// while that finger is alone and macOS sends no real drags.
@Test func aLockedHeldClickMovesThePointerOnlyWhileMacOSDoesNot() {
    var state = enabledCallbackState()
    state.heldDragPointsPerPadWidth = 1_000
    var frame: Int32 = 1
    func feed(_ contacts: [GestureContact], at time: Double, buttonDown: Bool = true) -> HeldClickPointerMove? {
        _ = state.process(contacts: contacts, touches: touches(contacts, frame: frame), rawCount: Int32(contacts.count),
                          flags: [], timestamp: time, now: time, buttonDown: buttonDown)
        frame += 1
        return state.takeHeldClickPointerMove(now: time, buttonDown: buttonDown)
    }
    func held(_ x: Double, _ y: Double) -> GestureContact { GestureContact(id: 9, x: x, y: y) }
    _ = feed([held(0.5, 0.2)], at: 1, buttonDown: false)
    _ = feed([held(0.5, 0.2)], at: 1.01)
    // Not locked yet: macOS moves the pointer itself.
    #expect(feed([held(0.51, 0.2)], at: 1.02) == nil)
    _ = feed([held(0.51, 0.2)] + contacts(), at: 1.03)
    _ = state.dockDecision(phase: 1, now: 1.031, handling: .withhold)
    #expect(state.pointerLockedBesideHeldClick)
    // The swipe fingers are still down.
    #expect(feed([held(0.52, 0.2)] + contacts(dx: -0.05), at: 1.05) == nil)
    _ = feed([held(0.52, 0.2)], at: 1.1)
    // Alone and locked: right on the pad is right on screen, up on the pad is up on
    // screen. The first move of a burst reads the cursor; the next ones do not.
    let move = feed([held(0.53, 0.21)], at: 1.11)
    #expect(move.map { abs($0.dx - 10) < 0.001 && abs($0.dy + 10 * trackpadAspect) < 0.001 } == true)
    #expect(move?.reanchor == true)
    #expect(feed([held(0.54, 0.21)], at: 1.12)?.reanchor == false)
    #expect(feed([held(0.54, 0.21)], at: 1.13) == nil)
    // A frame the validator rejects (its timestamp goes back) posts nothing again.
    _ = feed([held(0.55, 0.21)], at: 1.14)
    #expect(feed([held(0.55, 0.21)], at: 1.135) == nil)
    // A real drag from macOS stops Stagehand's moves, and the next one reads the cursor.
    state.lastRealPointerDrag = 1.15
    state.syntheticAnchorValid = false
    #expect(feed([held(0.56, 0.21)], at: 1.16) == nil)
    #expect(feed([held(0.57, 0.21)], at: 1.25)?.reanchor == true)
    #expect(state.syntheticStats.reanchors == 2)
    // The drop ends the lock.
    #expect(feed([held(0.58, 0.21)], at: 1.3, buttonDown: false) == nil)
    #expect(!state.pointerLockedBesideHeldClick)
    #expect(!state.syntheticAnchorValid)
}
