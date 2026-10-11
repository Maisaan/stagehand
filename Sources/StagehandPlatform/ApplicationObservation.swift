import ApplicationServices

enum WindowAvailabilityChange: Equatable {
    case destroyed
    case minimized
    case restored
}

func windowAvailabilityChange(for notification: String) -> WindowAvailabilityChange? {
    switch notification {
    case kAXUIElementDestroyedNotification: .destroyed
    case kAXWindowMiniaturizedNotification: .minimized
    case kAXWindowDeminiaturizedNotification: .restored
    default: nil
    }
}

/// Tracks subscriptions individually so a busy launching app can be retried without
/// replacing its observer or repeatedly registering subscriptions that succeeded.
struct ApplicationObservation {
    static let notifications = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                kAXApplicationHiddenNotification, kAXApplicationShownNotification]
    private(set) var pending = ApplicationObservation.notifications
    private(set) var attempts = 0

    /// Subscriptions that must be removed when the observer is torn down.
    var registered: [String] { Self.notifications.filter { !pending.contains($0) } }

    mutating func register(using subscribe: (String) -> AXError) -> Bool {
        guard !pending.isEmpty else { return false }
        attempts += 1
        pending = pending.filter { subscribe($0) == .cannotComplete }
        return !pending.isEmpty
    }
}
