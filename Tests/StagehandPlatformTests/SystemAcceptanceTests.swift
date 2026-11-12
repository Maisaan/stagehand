import CoreGraphics
import Foundation
import Testing
@testable import StagehandPlatform

private func scaled(_ width: Int, _ height: Int, refresh: Double = 120, usable: Bool = true) -> DisplayModeOption {
    DisplayModeOption(width: width, height: height, pixelWidth: width * 2, pixelHeight: height * 2,
                      refreshRate: refresh, usableForDesktop: usable)
}

private let builtInDefault = scaled(1512, 982)

@Test func scaledModeChoiceTakesTheNearestSizeWithTheSameDensityAndShape() {
    let modes = [
        builtInDefault,
        scaled(1710, 1112),
        scaled(1352, 878),
        scaled(1147, 745),
        DisplayModeOption(width: 1400, height: 909, pixelWidth: 1400, pixelHeight: 909, refreshRate: 120),
        scaled(1500, 844),
        scaled(1480, 961, usable: false)
    ]
    #expect(DisplayModeOption.alternative(to: builtInDefault, among: modes) == scaled(1352, 878))
}

@Test func scaledModeChoicePrefersTheLargerSizeOnATie() {
    let modes = [scaled(1412, 917), scaled(1612, 1047)]
    #expect(DisplayModeOption.alternative(to: builtInDefault, among: modes) == scaled(1612, 1047))
}

@Test func scaledModeChoicePrefersTheCurrentRefreshRate() {
    let modes = [scaled(1500, 974, refresh: 60), scaled(1352, 878)]
    #expect(DisplayModeOption.alternative(to: builtInDefault, among: modes) == scaled(1352, 878))
}

@Test func scaledModeChoiceIsNilWithoutAnotherSize() {
    let modes = [builtInDefault, DisplayModeOption(width: 1512, height: 982, pixelWidth: 1512, pixelHeight: 982,
                                                   refreshRate: 120)]
    #expect(DisplayModeOption.alternative(to: builtInDefault, among: modes) == nil)
}

private func hotKey(enabled: Bool, keyCode: Int, flags: Int) -> [String: Any] {
    ["enabled": NSNumber(value: enabled),
     "value": ["parameters": [NSNumber(value: 65_535), NSNumber(value: keyCode), NSNumber(value: flags)],
               "type": "standard"] as [String: Any]]
}

private let controlFunction = 0x840000
private func controlArrows() -> [String: Any] {
    ["79": hotKey(enabled: true, keyCode: 123, flags: controlFunction),
     "81": hotKey(enabled: true, keyCode: 124, flags: controlFunction)]
}

@Test func symbolicHotKeyReadsTheBoundKeyAndModifiers() {
    let reading = SymbolicHotKeys.reading(.right, in: controlArrows())
    #expect(reading == .bound(SpaceSwitchShortcut(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])))
    if case .bound(let shortcut) = reading { #expect(shortcut.displayName == "Control+Right Arrow") }
}

@Test func symbolicHotKeyDropsFlagsThatAreNotModifiers() {
    let hotKeys: [String: Any] = ["79": hotKey(enabled: true, keyCode: 123, flags: 0x140000 | 0x1)]
    #expect(SymbolicHotKeys.reading(.left, in: hotKeys)
        == .bound(SpaceSwitchShortcut(keyCode: 123, flags: [.maskControl, .maskCommand])))
}

@Test func symbolicHotKeyReportsDisabledUnboundAndMissingShortcuts() {
    let hotKeys: [String: Any] = [
        "79": hotKey(enabled: false, keyCode: 123, flags: controlFunction),
        "81": hotKey(enabled: true, keyCode: 65_535, flags: 0)
    ]
    #expect(SymbolicHotKeys.reading(.left, in: hotKeys) == .disabled)
    #expect(SymbolicHotKeys.reading(.right, in: hotKeys) == .unbound)
    #expect(SymbolicHotKeys.reading(.right, in: [:]) == .missing)
    #expect(SymbolicHotKeys.reading(.right, in: nil) == .missing)
}

@Test func displaySpacesParseWindowServerLists() {
    let raw: [[String: Any]] = [[
        "Display Identifier": "37D8832A-2D66-02CA-B9F7-8F30A301B230",
        "Current Space": ["ManagedSpaceID": NSNumber(value: 4)],
        "Spaces": [
            ["ManagedSpaceID": NSNumber(value: 1), "type": NSNumber(value: 0)],
            ["ManagedSpaceID": NSNumber(value: 4), "type": NSNumber(value: 0)],
            ["ManagedSpaceID": NSNumber(value: 9), "type": NSNumber(value: 4)]
        ]
    ], ["Spaces": []]]
    #expect(DisplaySpaces.parse(raw) == [DisplaySpaces(
        identifier: "37D8832A-2D66-02CA-B9F7-8F30A301B230", currentSpaceID: 4,
        spaces: [.init(id: 1, isDesktop: true), .init(id: 4, isDesktop: true), .init(id: 9, isDesktop: false)])])
}

private let builtInUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

private func display(_ identifier: String = builtInUUID, current: UInt64?, desktops: [UInt64],
                     fullScreen: [UInt64] = []) -> DisplaySpaces {
    DisplaySpaces(identifier: identifier, currentSpaceID: current,
                  spaces: desktops.map { .init(id: $0, isDesktop: true) } + fullScreen.map { .init(id: $0, isDesktop: false) })
}

private func plan(_ direction: SpaceSwitchDirection) -> DesktopSwitchReadiness {
    let left = SpaceSwitchShortcut(keyCode: 123, flags: [.maskControl, .maskSecondaryFn])
    let right = SpaceSwitchShortcut(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])
    return .ready(DesktopSwitchPlan(direction: direction, away: direction == .right ? right : left,
                                    back: direction == .right ? left : right))
}

@Test func desktopSwitchLeavesTowardTheNeighborThatExists() {
    #expect(DesktopSwitchReadiness.check(displays: [display(current: 1, desktops: [1, 2])],
                                         builtInIdentifier: builtInUUID, hotKeys: controlArrows()) == plan(.right))
    #expect(DesktopSwitchReadiness.check(displays: [display(current: 2, desktops: [1, 2])],
                                         builtInIdentifier: builtInUUID, hotKeys: controlArrows()) == plan(.left))
}

@Test func desktopSwitchFindsTheBuiltInDisplayAmongSeveral() {
    let displays = [display("EXTERNAL", current: 7, desktops: [7, 8]),
                    display(current: 2, desktops: [1, 2])]
    #expect(DesktopSwitchReadiness.check(displays: displays, builtInIdentifier: builtInUUID.lowercased(),
                                         hotKeys: controlArrows()) == plan(.left))
    #expect(DesktopSwitchReadiness.check(displays: [display("Main", current: 1, desktops: [1, 2])],
                                         builtInIdentifier: builtInUUID, hotKeys: controlArrows()) == plan(.right))
    #expect(DesktopSwitchReadiness.check(displays: displays, builtInIdentifier: nil, hotKeys: controlArrows())
        == .notRun("could not find the built-in display's Desktops"))
}

@Test func desktopSwitchDoesNotRunWithOneDesktop() {
    let readiness = DesktopSwitchReadiness.check(
        displays: [display(current: 1, desktops: [1], fullScreen: [5])], builtInIdentifier: builtInUUID,
        hotKeys: controlArrows())
    #expect(readiness == .notRun("the built-in display has one Desktop; add a second in Mission Control"))
}

@Test func desktopSwitchDoesNotRunWithoutReadings() {
    #expect(DesktopSwitchReadiness.check(displays: nil, builtInIdentifier: builtInUUID, hotKeys: controlArrows())
        == .notRun("WindowServer did not list the Desktops"))
    #expect(DesktopSwitchReadiness.check(displays: [display(current: nil, desktops: [1, 2])],
                                         builtInIdentifier: builtInUUID, hotKeys: controlArrows())
        == .notRun("the built-in display's current Desktop is unknown"))
}

@Test func desktopSwitchNeedsTheShortcutBackAsWell() {
    let hotKeys: [String: Any] = ["81": controlArrows()["81"]!,
                                  "79": hotKey(enabled: false, keyCode: 123, flags: controlFunction)]
    let readiness = DesktopSwitchReadiness.check(displays: [display(current: 1, desktops: [1, 2])],
                                                 builtInIdentifier: builtInUUID, hotKeys: hotKeys)
    guard case .notRun(let reason) = readiness else {
        Issue.record("expected not run, got \(readiness)")
        return
    }
    #expect(reason.hasPrefix("\"Move left a space\" is off"))
    let missing = DesktopSwitchReadiness.check(displays: [display(current: 1, desktops: [1, 2])],
                                               builtInIdentifier: builtInUUID, hotKeys: ["81": controlArrows()["81"]!])
    guard case .notRun(let missingReason) = missing else {
        Issue.record("expected not run, got \(missing)")
        return
    }
    #expect(missingReason.hasPrefix("\"Move left a space\" is not in com.apple.symbolichotkeys"))
}
