import AppKit
import Testing
@testable import StagehandPlatform

@MainActor @Test func rapidNavigationCanSkipOnlyTransfersWithoutTyping() throws {
    var destinations: [Int32] = []
    let gate = FocusInputGate(postEvent: { _, pid in destinations.append(pid) })
    defer { gate.cancelAll() }
    let empty = gate.beginTransfer()
    #expect(gate.cancelTransferIfEmpty(token: empty))
    #expect(!gate.cancelTransferIfEmpty(token: empty))
    let typed = gate.beginTransfer()
    let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(gate.processKeyboardEvent(type: .keyDown, event: down))
    #expect(!gate.cancelTransferIfEmpty(token: typed))
    let next = gate.beginTransfer()
    #expect(gate.cancelTransferIfEmpty(token: next))
    gate.commitTransfer(token: typed, processIdentifier: 123)
    #expect(destinations == [123])
    let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    #expect(gate.processKeyboardEvent(type: .keyUp, event: up))
    #expect(destinations == [123, 123])
}
