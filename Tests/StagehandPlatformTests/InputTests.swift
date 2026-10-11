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
    #expect(ShortcutBinding.load(from: defaults) == loaded)
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

    let loaded = ShortcutBinding.load(from: defaults)
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
