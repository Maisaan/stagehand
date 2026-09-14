import ApplicationServices

/// Tracks subscriptions individually so a busy launching app can be retried without
/// replacing its observer or repeatedly registering subscriptions that succeeded.
struct ApplicationObservation {
    private(set) var pending = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                kAXApplicationHiddenNotification, kAXApplicationShownNotification]
    private(set) var attempts = 0

    mutating func register(using subscribe: (String) -> AXError) -> Bool {
        guard attempts < 6, !pending.isEmpty else { return false }
        attempts += 1
        pending = pending.filter { subscribe($0) == .cannotComplete }
        return !pending.isEmpty && attempts < 6
    }
}
