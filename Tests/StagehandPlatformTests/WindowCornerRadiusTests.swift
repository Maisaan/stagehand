import AppKit
import Testing
@testable import StagehandPlatform

private func cornerMetadata(number: Int, pid: Int = 42, layer: Int = 0, frame: CGRect) -> [String: Any] {
    [kCGWindowNumber as String: NSNumber(value: number),
     kCGWindowOwnerPID as String: NSNumber(value: pid),
     kCGWindowLayer as String: NSNumber(value: layer),
     kCGWindowBounds as String: frame.dictionaryRepresentation]
}

@MainActor @Test func windowCornerLookupRequiresMatchingProcessFrameAndNormalLayer() {
    let frame = CGRect(x: 20, y: 40, width: 500, height: 400)
    let metadata = [cornerMetadata(number: 1, pid: 99, frame: frame),
                    cornerMetadata(number: 2, layer: 3, frame: frame),
                    cornerMetadata(number: 3, frame: frame.offsetBy(dx: 600, dy: 0)),
                    cornerMetadata(number: 4, frame: frame)]
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: frame, metadata: metadata) == 4)
}

@MainActor @Test func windowCornerLookupRefusesAmbiguousOrMissingWindows() {
    let frame = CGRect(x: 20, y: 40, width: 500, height: 400)
    let metadata = [cornerMetadata(number: 1, frame: frame), cornerMetadata(number: 2, frame: frame)]
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: frame, metadata: metadata) == nil)
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: frame, metadata: []) == nil)
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: frame, metadata: [[:]]) == nil)
}

@MainActor @Test func windowCornerLookupRejectsInvalidBoundsAndWindowNumbers() {
    let frame = CGRect(x: 20, y: 40, width: 500, height: 400)
    for number in [0, -1] {
        #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: frame, metadata: [cornerMetadata(number: number, frame: frame)]) == nil)
    }
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: .zero, metadata: [cornerMetadata(number: 1, frame: frame)]) == nil)
    let invalid = CGRect(x: CGFloat.nan, y: 40, width: 500, height: 400)
    #expect(WindowCornerRadius.matchingWindowNumber(processID: 42, frame: invalid, metadata: [cornerMetadata(number: 1, frame: frame)]) == nil)
}
