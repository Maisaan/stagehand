import AppKit
import Darwin

/// Reads a window's native corner metadata using its exact WindowServer identity.
@MainActor
public enum WindowCornerRadius {
    public static func cornerRadius(windowNumber: CGWindowID) -> CGFloat? {
        guard windowNumber != kCGNullWindowID else { return nil }
        return nativeRadius(windowNumber)
    }

    static func validatedRadius(_ values: [NSNumber]) -> CGFloat? {
        guard let first = values.first else { return nil }
        let radius = CGFloat(first.doubleValue)
        guard radius.isFinite, radius >= 0 else { return nil }
        // SkyLight currently returns four values. Their per-corner order is private,
        // so only consume a uniform shape instead of assigning asymmetric corners incorrectly.
        guard values.dropFirst().allSatisfy({ value in
            let candidate = CGFloat(value.doubleValue)
            return candidate.isFinite && candidate >= 0 && abs(candidate - radius) <= 0.25
        }) else { return nil }
        return radius
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
                          let values = radii as? [NSNumber] else { return nil }
                    // Zero is a valid square window, not a missing-value sentinel.
                    return validatedRadius(values)
                }
            }
        }
    }()
}
