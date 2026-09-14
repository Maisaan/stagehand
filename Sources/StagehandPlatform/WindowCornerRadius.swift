import AppKit
import Darwin

/// Reads the focused window's native corner metadata. Call when its identity changes,
/// then reuse the result for ordinary frame updates; this performs a window-list query.
@MainActor
public enum WindowCornerRadius {
    public static func cornerRadius(processID: Int32, frame: CGRect) -> CGFloat? {
        guard validFrame(frame), processID > 0,
              let metadata = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let number = matchingWindowNumber(processID: processID, frame: frame, metadata: metadata) else {
            return nil
        }
        return nativeRadius(number)
    }

    static func matchingWindowNumber(processID: Int32, frame: CGRect, metadata: [[String: Any]]) -> CGWindowID? {
        guard validFrame(frame), processID > 0 else { return nil }
        let matches = metadata.compactMap { window -> CGWindowID? in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                  validFrame(bounds),
                  abs(bounds.minX - frame.minX) <= 1,
                  abs(bounds.minY - frame.minY) <= 1,
                  abs(bounds.width - frame.width) <= 1,
                  abs(bounds.height - frame.height) <= 1,
                  let rawNumber = window[kCGWindowNumber as String] as? NSNumber,
                  let number = CGWindowID(exactly: rawNumber.int64Value), number != kCGNullWindowID else {
                return nil
            }
            return number
        }
        // Matching only a PID is insufficient when one app has multiple windows. Refuse
        // ambiguous overlapping frames instead of borrowing a neighboring window's radius.
        return matches.count == 1 ? matches[0] : nil
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    // ABI and ownership reference:
    // https://github.com/FelixKratz/JankyBorders/blob/main/src/windows.c
    // https://github.com/FelixKratz/JankyBorders/blob/main/src/misc/extern.h
    // Despite its "Get" name, GetCornerRadii returns an owned reference in that implementation.
    private static let nativeRadius: (CGWindowID) -> CGFloat? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL),
              let connectionSymbol = dlsym(framework, "SLSMainConnectionID"),
              let querySymbol = dlsym(framework, "SLSWindowQueryWindows"),
              let windowsSymbol = dlsym(framework, "SLSWindowQueryResultCopyWindows"),
              let advanceSymbol = dlsym(framework, "SLSWindowIteratorAdvance"),
              let cornersSymbol = dlsym(framework, "SLSWindowIteratorGetCornerRadii") else {
            return { _ in nil }
        }
        // Keep this single library reference for process lifetime while its pointers are used.
        let connection = unsafeBitCast(connectionSymbol, to: (@convention(c) () -> Int32).self)
        let query = unsafeBitCast(querySymbol, to: (@convention(c) (Int32, CFArray, UInt32) -> Unmanaged<CFTypeRef>?).self)
        let windows = unsafeBitCast(windowsSymbol, to: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self)
        let advance = unsafeBitCast(advanceSymbol, to: (@convention(c) (CFTypeRef) -> Bool).self)
        let corners = unsafeBitCast(cornersSymbol, to: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self)
        return { windowNumber in
            let client = connection()
            guard client != 0 else { return nil }
            let ids = [NSNumber(value: windowNumber)] as CFArray
            guard let result = query(client, ids, 0)?.takeRetainedValue() else { return nil }
            return withExtendedLifetime(result) {
                guard let iterator = windows(result)?.takeRetainedValue() else { return nil }
                return withExtendedLifetime(iterator) {
                    guard advance(iterator), let radii = corners(iterator)?.takeRetainedValue(),
                          let values = radii as? [NSNumber], let value = values.first else { return nil }
                    let radius = CGFloat(value.doubleValue)
                    // Zero is a valid square window, not a missing-value sentinel.
                    return radius.isFinite && radius >= 0 ? radius : nil
                }
            }
        }
    }()
}
