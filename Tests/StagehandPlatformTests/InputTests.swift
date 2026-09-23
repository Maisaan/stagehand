import AppKit
import Carbon
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

    let loaded = ShortcutBinding.load(from: defaults)
    #expect(loaded.first { $0.id == "focusNext" } == ShortcutBinding.defaultBinding(id: "focusNext"))
    #expect(loaded.first { $0.id == "focusPrevious" }?.isEnabled == true)
    #expect(loaded.first { $0.id == "showSettings" }?.isEnabled == false)
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
    var discarded = 0
    let gate = FocusInputGate(postEvent: { _, _ in posted += 1 })
    gate.onInputDiscarded = { discarded += $0 }
    let token = gate.beginTransfer()
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    for _ in 0 ..< 129 { #expect(gate.processKeyboardEvent(type: .keyDown, event: event)) }
    gate.commitTransfer(token: token, processIdentifier: 100)
    #expect(discarded == 129)
    #expect(posted == 0)
}
