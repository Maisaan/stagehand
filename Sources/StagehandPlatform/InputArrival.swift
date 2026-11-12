import Foundation

/// When a navigating input reached Stagehand, on the system-uptime clock. Times only,
/// never what was typed.
public struct InputArrival: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// The keyboard tap. `eventUptime` is the key event's own time.
        case keyboardTap
        /// A trackpad frame. `eventUptime` is the frame's own time when it reads as uptime.
        case trackpad
        /// A Carbon hot key. Its handler runs on main and carries no event time, so the
        /// callback's time is all there is.
        case hotKeyCallback
    }

    public let source: Source
    /// The input's own time, converted to uptime; nil when it has none or it is unreadable.
    public let eventUptime: TimeInterval?
    /// When Stagehand's callback saw it, on the thread that receives it.
    public let receivedUptime: TimeInterval
    /// When the main thread ran its handler.
    public internal(set) var deliveredUptime: TimeInterval?
    /// Trackpad only: when this gesture's fingers first touched.
    public let touchesLandedUptime: TimeInterval?

    public init(source: Source, eventUptime: TimeInterval?, receivedUptime: TimeInterval,
                deliveredUptime: TimeInterval? = nil, touchesLandedUptime: TimeInterval? = nil) {
        self.source = source
        self.eventUptime = eventUptime
        self.receivedUptime = receivedUptime
        self.deliveredUptime = deliveredUptime
        self.touchesLandedUptime = touchesLandedUptime
    }

    /// The input whose handler is running on the main thread right now. A change queued
    /// synchronously from that handler takes its arrival from here.
    @MainActor public private(set) static var beingDelivered: InputArrival?

    /// Runs `handler` with `arrival` as `beingDelivered`, stamped with the delivery time.
    @MainActor public static func delivering(_ arrival: InputArrival?, _ handler: () -> Void) {
        let outer = beingDelivered
        var delivered = arrival
        if delivered?.deliveredUptime == nil { delivered?.deliveredUptime = ProcessInfo.processInfo.systemUptime }
        beingDelivered = delivered
        defer { beingDelivered = outer }
        handler()
    }
}

/// Typing held for a focus transfer and replayed once the destination was confirmed.
/// Counts and ages only, never key contents.
public struct HeldInputRelease: Equatable, Sendable {
    public let heldEvents: Int
    /// From the transfer's start to the commit.
    public let transferAge: TimeInterval
    /// The oldest held event's age at the commit; nil with nothing held or no readable event time.
    public let oldestHeldEventAge: TimeInterval?
    /// When the replay was posted to the destination process: posted, not received.
    public let postedUptime: TimeInterval
}

/// A touch frame's own time on the `systemUptime` clock. The private framework does not
/// document its clock, so a time more than a minute from `now` is not trusted.
func touchFrameUptime(_ timestamp: Double, now: TimeInterval) -> TimeInterval? {
    guard timestamp.isFinite, abs(timestamp - now) < 60 else { return nil }
    return timestamp
}
