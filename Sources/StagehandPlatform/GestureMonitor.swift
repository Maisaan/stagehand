import AppKit
import Carbon
import Darwin
import os
import StagehandCore

// Private ABI reference: https://github.com/cyanyux/trident/blob/main/Sources/TridentCore/TouchModels.swift
// The runtime checks the layout before starting. Missing symbols disable gestures, not keyboard controls.
private struct RawPoint { var x: Float; var y: Float }
private struct RawVector { var position: RawPoint; var velocity: RawPoint }
private struct RawContact {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: UInt32
    var finger: Int32
    var hand: Int32
    var normalized: RawVector
    var pressure: Float
    var unused1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: RawVector
    var unused2: Int32
    var unused3: Int32
    var density: Float
}

/// Layout of the private contact record, checked before any frame is read.
private let rawContactStride = 96
private let rawContactNormalizedOffset = 32
private let rawContactAbsoluteOffset = 68
/// MultitouchSupport reports more contacts than any trackpad has only when the frame is corrupt.
private let maximumContactsPerFrame: Int32 = 32
/// Contact states that mean a finger is on the surface: 3 is "make" (just landed), 4 is "touching".
private let touchStateMake: UInt32 = 3
private let touchStateTouching: UInt32 = 4
/// Momentum scroll events that follow a lift within this window belong to the gesture.
let momentumSuppressionWindow: TimeInterval = 0.15
/// Events are withheld only while contact frames are still arriving. If the framework
/// stops reporting frames mid-sequence, scrolling recovers after this long.
let inputSuppressionStaleInterval: TimeInterval = 0.1
/// After an owned lift, the sequence's own scroll and touch events are withheld until new
/// contacts land or a new stream begins, for at most this long. WindowServer delivered
/// them up to 475 ms after Stagehand's zero-contact frame (diagnostic log, 2026-11-03).
let liftTailInterval: TimeInterval = 1.0

/// Which app-bound events a three-finger sequence withholds from the app under the pointer.
enum SuppressibleInputEvent: Equatable, Sendable {
    /// Raw `CGScrollPhase` and `CGMomentumScrollPhase` values of a scroll wheel event.
    case scroll(phase: Int64, momentumPhase: Int64)
    /// Touch, swipe, and begin/end gesture events derived from the same contacts.
    case gesture
    /// A begin-gesture event: a new sequence, which ends a lift tail.
    case gestureStart
    /// The Dock's own gestures, among them its swipe between Spaces and full-screen apps.
    case dockControl
}

/// Decides which app-bound input a trackpad contact sequence owns.
///
/// WindowServer derives two event families from the same fingers: scroll wheel events and
/// gesture events carrying the touches. Apps build their own swipes on either (a browser's
/// back/forward arms on the first scroll deltas, then follows the touches), so Stagehand must
/// withhold both, and must do so for the whole sequence. Owning a sequence from its first
/// frame with enough fingers, until every finger lifts, means an app never sees a scroll
/// stream that starts mid-sequence or a swipe whose beginning was withheld. After the lift,
/// the sequence's terminal scroll and touch events and its momentum are still withheld: the
/// terminal touch event carries the final finger positions an app's swipe would commit on
/// (Chromium navigates back or forward on touchesEnded), and momentum would scroll content
/// under a ribbon that already moved. The terminal events trail the zero-contact frame by
/// up to about half a second, so the tail lasts until a new sequence shows itself: new
/// contacts, a new scroll stream's first phase, or a begin-gesture event. Touch phases
/// cannot tell a landing finger: an NSEvent made from the tap's gesture event carries no
/// touches (input recording, 2026-11-03).
///
/// Fingers rarely land together. Frames before the third finger lands belong to the app,
/// so a browser may already have armed its swipe on two fingers; withholding the rest of
/// the sequence, its end included, keeps it from committing.
///
/// The cost is that any third contact during a two-finger scroll, a resting thumb or a palm
/// the hardware accepted, holds that scroll until all fingers lift.
struct GestureInputOwnership: Equatable, Sendable {
    /// Momentum from an owned lift stays withheld until its end phase, or until the
    /// stream has been silent this long and must belong to something else.
    static let momentumInactivityInterval: TimeInterval = 0.5

    private(set) var ownsSequence = false
    private(set) var lastContactFrameTime: TimeInterval = 0
    private(set) var lastLiftTime: TimeInterval = 0
    /// True from an owned lift until a new sequence starts. The lifted sequence's last
    /// scroll and gesture events may arrive after the zero-contact frame and belong to it.
    private(set) var liftTailPending = false
    /// True from an owned lift until the app starts its own live scroll (phase began).
    /// Momentum may only be claimed while this holds; a later two-finger flick's momentum is
    /// the app's even when it begins within the window after the owned lift. A may-begin
    /// does not count: macOS sends one the moment fingers touch, also just before the
    /// swipe's own momentum begins, and a may-begin alone never has momentum of its own.
    private(set) var momentumEligible = false
    private(set) var ownsMomentum = false
    private var lastMomentumTime: TimeInterval = 0

    /// Record one accepted contact frame. `eligible` is false when the sequence was
    /// handed to the app on landing (a shortcut swipe without its modifiers, for one).
    mutating func observe(contactCount: Int, fingerCount: Int, eligible: Bool, now: TimeInterval) {
        if contactCount == 0 {
            if ownsSequence {
                lastLiftTime = now
                liftTailPending = true
                momentumEligible = true
            }
            ownsSequence = false
            return
        }
        lastContactFrameTime = now
        liftTailPending = false
        if !ownsSequence, eligible, contactCount >= fingerCount { ownsSequence = true }
    }

    /// The lifted sequence's trailing events are still arriving.
    func inLiftTail(now: TimeInterval) -> Bool {
        liftTailPending && now - lastLiftTime < liftTailInterval
    }

    /// Decide one app-bound event. Mutating: momentum ownership follows the stream's phases.
    mutating func suppress(_ event: SuppressibleInputEvent, now: TimeInterval) -> Bool {
        let framesFresh = now - lastContactFrameTime < inputSuppressionStaleInterval
        switch event {
        case .dockControl:
            // Withheld only beside a held click, by GestureCallbackState.suppress.
            return false
        case .gesture:
            return (ownsSequence && framesFresh) || inLiftTail(now: now)
        case .gestureStart:
            if ownsSequence, framesFresh { return true }
            liftTailPending = false
            return false
        case .scroll(let phase, let momentumPhase):
            if ownsSequence, framesFresh { return true }
            guard momentumPhase != 0 else {
                // A new live scroll ends the lift tail, and the momentum that follows it
                // belongs to the app even if it begins soon after the owned lift. A momentum
                // stream already claimed stays claimed until it ends: macOS keeps sending the
                // swipe's momentum after the next fingers touch (recording, 2026-11-03: 33 of
                // 39 claimed streams leaked partway after a may-begin, and T3 Code navigated).
                if phase == 1 || phase == 128 {
                    if phase == 1 { momentumEligible = false }
                    liftTailPending = false
                    return false
                }
                // Phase 0 is a mouse wheel, never part of a trackpad sequence.
                return phase != 0 && inLiftTail(now: now)
            }
            // A momentum begin is a new stream: decide it afresh.
            if momentumPhase == 1 { ownsMomentum = false }
            if ownsMomentum, now - lastMomentumTime > Self.momentumInactivityInterval { ownsMomentum = false }
            if !ownsMomentum, momentumEligible, now - lastLiftTime < momentumSuppressionWindow {
                ownsMomentum = true
            }
            guard ownsMomentum else { return false }
            lastMomentumTime = now
            if momentumPhase == 3 { ownsMomentum = false }
            return true
        }
    }
}

/// Scroll and gesture events the input tap passed to the app around owned sequences,
/// counted since gestures started, for the diagnostic log. An app that saw the start of a
/// sequence, a stretch whose frames went stale, or events after the lift can run its own
/// swipe (a browser's back or forward) beside Stagehand's.
struct AppInputLeakStats: Equatable, Sendable {
    struct Counts: Equatable, Sendable {
        var scroll = 0
        var gesture = 0
        var summary: String { "\(scroll)s/\(gesture)g" }
    }

    /// Sequences that became owned.
    private(set) var ownedSequences = 0
    /// Passed while contacts were down, before the sequence became owned.
    private(set) var beforeOwnership = Counts()
    /// Passed while a sequence was owned but its contact frames had stopped arriving.
    private(set) var whileStale = Counts()
    /// Passed within `liftWindow` after an owned lift, before new contacts landed.
    private(set) var afterLift = Counts()
    /// Momentum streams that began within `liftWindow` after an owned lift and passed.
    private(set) var momentumAfterLift = 0
    /// Withheld after an owned lift by the lift tail, not counting momentum.
    private(set) var withheldInTail = Counts()
    /// Latest event counted in `withheldInTail`, after its lift.
    private(set) var longestWithheldInTailMilliseconds = 0
    /// Latest event counted in `afterLift`, after its lift.
    private(set) var longestAfterLiftMilliseconds = 0
    /// Longest gap between contact frames inside an owned sequence.
    private(set) var longestOwnedFrameGapMilliseconds = 0
    /// Longest time from the first contact to ownership.
    private(set) var longestLandingMilliseconds = 0
    var rejectedFrames = 0

    /// Event kinds, for splitting what passed after a lift and what the tail withheld.
    /// Scroll entries are `CGScrollPhase` values; gesture entries are raw CG event types.
    static let kindLabels = ["s0", "s1", "s2", "s4", "s8", "s128", "s?", "g19", "g20", "g29", "g30", "g31", "g?"]
    static func kindIndex(_ kind: SuppressibleInputEvent, rawType: UInt32) -> Int {
        if case .scroll(let phase, _) = kind {
            return [0, 1, 2, 4, 8, 128].firstIndex(of: phase) ?? 6
        }
        return [19, 20, 29, 30, 31].firstIndex(of: rawType).map { $0 + 7 } ?? 12
    }
    private(set) var afterLiftKinds = [Int](repeating: 0, count: 13)
    private(set) var tailKinds = [Int](repeating: 0, count: 13)
    /// What ended each lift tail: new contacts, a scroll began or may-begin, a
    /// begin-gesture event, or the cap running out with events still arriving.
    static let tailEndLabels = ["contacts", "scrollBegan", "mayBegin", "beginGesture", "cap"]
    private(set) var tailEnds = [Int](repeating: 0, count: 5)
    /// Passed after a lift though the event was made before the lift: the lifted
    /// sequence's own input, delivered late.
    private(set) var passedMadeBeforeLift = 0
    /// Longest wait between an event's own time and the tap seeing it, after a lift.
    private(set) var longestDeliveryLagMilliseconds = 0

    static let liftWindow: TimeInterval = 2

    private var contactsDown = false
    private var landingTime: TimeInterval = 0
    private var lastFrameTime: TimeInterval = 0
    private var pendingBeforeOwnership = Counts()
    private var ownedLiftTime: TimeInterval?
    private var capCounted = false

    mutating func observe(contactCount: Int, ownedBefore: Bool, ownedAfter: Bool, now: TimeInterval) {
        if contactCount == 0 {
            if ownedBefore {
                ownedLiftTime = now
                capCounted = false
            }
            contactsDown = false
            pendingBeforeOwnership = Counts()
            return
        }
        if !contactsDown {
            contactsDown = true
            landingTime = now
            ownedLiftTime = nil
            pendingBeforeOwnership = Counts()
        } else if ownedBefore {
            longestOwnedFrameGapMilliseconds = max(longestOwnedFrameGapMilliseconds,
                                                   Int(((now - lastFrameTime) * 1000).rounded()))
        }
        lastFrameTime = now
        if !ownedBefore, ownedAfter {
            ownedSequences &+= 1
            beforeOwnership.scroll &+= pendingBeforeOwnership.scroll
            beforeOwnership.gesture &+= pendingBeforeOwnership.gesture
            pendingBeforeOwnership = Counts()
            longestLandingMilliseconds = max(longestLandingMilliseconds, Int(((now - landingTime) * 1000).rounded()))
        }
    }

    mutating func recordTailEnd(_ index: Int) { tailEnds[index] &+= 1 }

    private mutating func recordTiming(eventTime: TimeInterval?, lift: TimeInterval, now: TimeInterval) {
        guard let eventTime else { return }
        if eventTime < lift { passedMadeBeforeLift &+= 1 }
        longestDeliveryLagMilliseconds = max(longestDeliveryLagMilliseconds, Int(((now - eventTime) * 1000).rounded()))
    }

    mutating func recordPassed(_ kind: SuppressibleInputEvent, ownership: GestureInputOwnership, now: TimeInterval,
                               rawType: UInt32 = 0, eventTime: TimeInterval? = nil) {
        func add(_ counts: inout Counts) {
            if case .scroll = kind { counts.scroll &+= 1 } else { counts.gesture &+= 1 }
        }
        if ownership.ownsSequence {
            add(&whileStale)
        } else if contactsDown {
            add(&pendingBeforeOwnership)
        } else if let lift = ownedLiftTime, now - lift < Self.liftWindow {
            if case .scroll(_, let momentumPhase) = kind, momentumPhase != 0 {
                if momentumPhase == 1 { momentumAfterLift &+= 1 }
                return
            }
            add(&afterLift)
            afterLiftKinds[Self.kindIndex(kind, rawType: rawType)] &+= 1
            longestAfterLiftMilliseconds = max(longestAfterLiftMilliseconds, Int(((now - lift) * 1000).rounded()))
            if ownership.liftTailPending, !ownership.inLiftTail(now: now), !capCounted {
                capCounted = true
                tailEnds[4] &+= 1
            }
            recordTiming(eventTime: eventTime, lift: lift, now: now)
        }
    }

    mutating func recordWithheld(_ kind: SuppressibleInputEvent, ownership: GestureInputOwnership, now: TimeInterval,
                                 rawType: UInt32 = 0) {
        guard !ownership.ownsSequence, !contactsDown, let lift = ownedLiftTime else { return }
        switch kind {
        case .scroll(_, let momentumPhase) where momentumPhase != 0: return
        case .scroll: withheldInTail.scroll &+= 1
        default: withheldInTail.gesture &+= 1
        }
        tailKinds[Self.kindIndex(kind, rawType: rawType)] &+= 1
        longestWithheldInTailMilliseconds = max(longestWithheldInTailMilliseconds, Int(((now - lift) * 1000).rounded()))
    }

    var summary: String {
        "owned=\(ownedSequences) before=\(beforeOwnership.summary) stale=\(whileStale.summary) "
            + "afterLift=\(afterLift.summary) afterLiftMs=\(longestAfterLiftMilliseconds) "
            + "momentumAfterLift=\(momentumAfterLift) tail=\(withheldInTail.summary) "
            + "tailMs=\(longestWithheldInTailMilliseconds) "
            + "landingMs=\(longestLandingMilliseconds) frameGapMs=\(longestOwnedFrameGapMilliseconds) "
            + "rejected=\(rejectedFrames) "
            + "afterLiftKinds=\(Self.labeled(afterLiftKinds, Self.kindLabels)) "
            + "tailKinds=\(Self.labeled(tailKinds, Self.kindLabels)) "
            + "tailEnds=\(Self.labeled(tailEnds, Self.tailEndLabels)) "
            + "madeBeforeLift=\(passedMadeBeforeLift) lagMs=\(longestDeliveryLagMilliseconds)"
    }

    /// Nonzero counts as `label:count`, comma-separated; `-` when all are zero.
    private static func labeled(_ counts: [Int], _ labels: [String]) -> String {
        let parts = zip(labels, counts).filter { $0.1 != 0 }.map { "\($0.0):\($0.1)" }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }
}

/// Event types the input tap filters: scroll wheel plus the gesture family AppKit turns
/// into `touches*WithEvent`, `swipe(with:)`, and begin/end gesture. Core Graphics has no
/// public names for the gesture types; the raw values are `NSEvent.EventType`'s.
let suppressibleEventTypeMask: CGEventMask = [
    CGEventType.scrollWheel.rawValue,
    UInt32(NSEvent.EventType.beginGesture.rawValue),
    UInt32(NSEvent.EventType.endGesture.rawValue),
    UInt32(NSEvent.EventType.gesture.rawValue),
    UInt32(NSEvent.EventType.swipe.rawValue),
    dockControlEventType,
    // Passed through untouched; seen only to tell real pointer drags from Stagehand's own.
    CGEventType.leftMouseDragged.rawValue
].reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1)) }

/// kCGSEventDockControl: the events WindowServer sends the Dock for its trackpad gestures,
/// including the swipe between Spaces (HID type 23, kIOHIDEventTypeDockSwipe). Private;
/// named in https://github.com/jurplel/InstantSpaceSwitcher/blob/main/Sources/ISS/ISS.c,
/// which intercepts them with a session event tap like this one.
let dockControlEventType: UInt32 = 30

/// Rejects contact frames that cannot have come from a working trackpad. The private
/// framework has no contract; after a macOS update it may report garbage with the right
/// struct size, and the recognizer must not act on it.
struct GestureFrameValidator: Sendable {
    struct Touch: Sendable {
        var frame: Int32
        var state: UInt32
        var x: Float
        var y: Float
        var isTouching: Bool
    }

    /// MultitouchSupport states run 0 (not tracking) through 7 (out of range).
    static let maximumTouchState: UInt32 = 7
    /// Positions are normalized 0...1; a small tolerance absorbs edge rounding.
    static let positionTolerance: Float = 0.05
    /// Consecutive corrupt frames before gestures turn themselves off.
    static let maximumBadFrames = 10

    private(set) var badFrames = 0
    private var lastTimestamp: Double = 0
    private var lastFrame: Int32 = 0
    var isExhausted: Bool { badFrames >= Self.maximumBadFrames }

    /// Returns false when the frame must be ignored. A rejected frame also resets the
    /// baseline so one clock reset counts once rather than failing every later frame.
    mutating func accept(timestamp: Double, touches: [Touch]) -> Bool {
        let range = -Self.positionTolerance...(1 + Self.positionTolerance)
        let valid = timestamp.isFinite && timestamp >= lastTimestamp && touches.allSatisfy { touch in
            touch.state <= Self.maximumTouchState && touch.frame >= lastFrame
                && (!touch.isTouching || (touch.x.isFinite && touch.y.isFinite && range.contains(touch.x) && range.contains(touch.y)))
        }
        lastTimestamp = timestamp.isFinite ? timestamp : 0
        lastFrame = touches.map(\.frame).max() ?? lastFrame
        if valid {
            badFrames = 0
        } else {
            badFrames += 1
        }
        return valid
    }
}

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

func shortcutGestureModifiers(for flags: CGEventFlags, bindings: [ShortcutBinding]) -> UInt32? {
    let modifiers = ShortcutBinding.carbonModifiers(for: flags)
    let arrowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    return arrowKeys.contains {
        ShortcutBinding.action(forKey: UInt32($0), modifiers: modifiers, in: bindings) != nil
    } ? modifiers : nil
}

func gestureShortcutAction(
    axis: GestureAxis, displacement: Double, modifiers: UInt32, bindings: [ShortcutBinding],
    reverseDirection: Bool = true
) -> NavigationAction? {
    let displacement = reverseDirection ? -displacement : displacement
    let key: UInt32
    switch axis {
    case .horizontal: key = UInt32(displacement < 0 ? kVK_LeftArrow : kVK_RightArrow)
    case .vertical: key = UInt32(displacement > 0 ? kVK_UpArrow : kVK_DownArrow)
    }
    return ShortcutBinding.action(forKey: key, modifiers: modifiers, in: bindings)
}

struct GestureCallbackState {
    var enabled = false
    var unmodifiedEnabled = false
    var shortcutEnabled = false
    var reverseShortcutDirection = true
    var shortcutBindings: [ShortcutBinding] = []
    var shortcutModifiers: UInt32?
    var shortcutAxis: GestureAxis?
    var ignoredUntilLift = false
    /// Contacts that were touching before the left button went down, with no swipe under
    /// way: the finger holding a click, as when carrying a file to drop. They are left out
    /// of recognition and input ownership until each lifts, so the other fingers can swipe.
    var heldClickContactIDs: Set<Int32> = []
    var buttonWasDown = false
    var previousContactIDs: Set<Int32> = []
    /// The held click carries a drag-and-drop, as the main thread found from the drag
    /// pasteboard. Swipes beside it then take `heldDropFingerCount` fingers, and the
    /// two-finger scroll a carried item could otherwise use is Stagehand's. Cleared when
    /// the button comes up.
    var heldClickCarriesDrop = false
    /// Fingers have landed beside a held click not yet known to carry a drop, and the
    /// main thread has been asked once for this landing to check.
    var dropCheckRequested = false
    var dropCheckDue = false
    var requestDropCheck: (@Sendable () -> Void)?
    /// Dock gesture events withheld beside a held click since gestures started.
    var withheldDockControlEvents = 0
    /// How far held-click fingers have moved since gestures started, in trackpad widths.
    /// Diagnostics compare it with the pointer events macOS sends during a drag.
    var heldClickTravel: Double = 0
    var previousFilteredCount = 0
    /// macOS took the held click and the fingers beside it for its own four-finger
    /// gesture during this press. Its trackpad handling then stops moving the pointer for
    /// the whole touch until every finger lifts, and the held finger does not lift until
    /// the drop (SkyLight SystemGestures, 2026-10-26; with Stagehand's gestures off too).
    var pointerLockedBesideHeldClick = false
    var lastRealPointerDrag: TimeInterval = 0
    /// The held finger's movement in the last frame, in trackpad widths and heights.
    var heldClickFrameDelta: (x: Double, y: Double) = (0, 0)
    /// Pointer points per trackpad width for moves Stagehand makes on macOS's behalf.
    var heldDragPointsPerPadWidth: Double = 1_800
    var syntheticPointerEvents = 0
    /// The pointer position Stagehand last moved to is still the cursor's. Cleared when
    /// macOS moves the pointer itself and when the lock ends; the next move then reads
    /// the cursor once instead of every frame.
    var syntheticAnchorValid = false
    var lastSyntheticFrame: TimeInterval = 0
    var syntheticStats = SyntheticPointerStats()
    var heldClickPositions: [Int32: (x: Double, y: Double)] = [:]
    var recognizer = NavigationGestureRecognizer()
    var ownership = GestureInputOwnership()
    var appInputLeaks = AppInputLeakStats()
    var frameValidator = GestureFrameValidator()
    /// Set once corrupt frames exhaust the validator; delivered to the monitor on main.
    var failure: String?
    var pendingEvents = GestureEventBuffer()
    /// When the fingers now on the pad first touched; nil once they all lift.
    var touchesLandedUptime: TimeInterval?
    var deliveryScheduled = false
    var scheduleDelivery: (@Sendable () -> Void)?
}

private let gestureCallbackState = OSAllocatedUnfairLock(initialState: GestureCallbackState())
let traceGestures = ProcessInfo.processInfo.arguments.contains("--trace-gestures")

private let contactCallback: ContactCallback = { _, raw, count, timestamp, _ in
    guard count >= 0, count <= maximumContactsPerFrame, count == 0 || raw != nil else { return 0 }
    var contacts: [GestureContact] = []
    var touches: [GestureFrameValidator.Touch] = []
    contacts.reserveCapacity(Int(count))
    touches.reserveCapacity(Int(count))
    if let raw {
        let buffer = raw.assumingMemoryBound(to: RawContact.self)
        for index in 0..<Int(count) {
            let touch = buffer[index]
            let isTouching = touch.state == touchStateMake || touch.state == touchStateTouching
            touches.append(.init(frame: touch.frame, state: touch.state, x: touch.normalized.position.x,
                                 y: touch.normalized.position.y, isTouching: isTouching))
            if isTouching {
                contacts.append(GestureContact(id: touch.identifier, x: Double(touch.normalized.position.x), y: Double(touch.normalized.position.y)))
            }
        }
    }
    let snapshot = contacts
    let frameTouches = touches
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let buttonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
    let now = ProcessInfo.processInfo.systemUptime
    let (delivery, move, dropCheck) = gestureCallbackState.withLock { state in
        (state.process(contacts: snapshot, touches: frameTouches, rawCount: count, flags: flags,
                       timestamp: timestamp, now: now, buttonDown: buttonDown),
         state.takeHeldClickPointerMove(now: now, buttonDown: buttonDown),
         state.takeDropCheck())
    }
    delivery?()
    dropCheck?()
    if let move {
        let posted = postHeldClickDrag(move)
        gestureCallbackState.withLock { $0.syntheticStats.recordPost(posted) }
    }
    return 0
}

/// One frame's pointer move for a held click macOS has locked, in points.
struct HeldClickPointerMove: Equatable, Sendable {
    var dx: Double
    var dy: Double
    /// Read the cursor before moving: Stagehand's last position may no longer be its.
    var reanchor: Bool
}

/// How Stagehand's pointer moves for a held click went, for drag_and_drop_ended.
public struct SyntheticPointerStats: Equatable, Sendable {
    /// Drags posted, frames whose movement stayed under a point (kept for the next),
    /// and times the cursor had to be read again.
    public var posts = 0
    public var subPointFrames = 0
    public var reanchors = 0
    /// Since the last reset: the longest wait between frames that moved the pointer,
    /// and the slowest post.
    public var longestFrameGapMilliseconds: Double = 0
    public var slowestPostMicroseconds: Double = 0

    public init() {}

    mutating func recordPost(_ result: (posted: Bool, microseconds: Double)) {
        if result.posted {
            posts &+= 1
            slowestPostMicroseconds = max(slowestPostMicroseconds, result.microseconds)
        } else {
            subPointFrames &+= 1
        }
    }
}

/// Real drags arriving within this long stop Stagehand's own pointer moves.
let syntheticPointerHoldoff: TimeInterval = 0.05
/// Height over width of a MacBook trackpad, about 10 by 16 cm.
let trackpadAspect = 0.62
/// Marks pointer events Stagehand posts, so the input tap does not count them as real.
let syntheticPointerTag: Int64 = 0x5354_4844 // "STHD"
nonisolated(unsafe) private let syntheticPointerSource: CGEventSource? = {
    let source = CGEventSource(stateID: .hidSystemState)
    source?.userData = syntheticPointerTag
    return source
}()

// Used only on the MultitouchSupport callback thread. Where Stagehand has put the
// pointer (fractional: sub-point movement adds up), where it last posted it, and the
// displays' bounds, read again with the cursor at each reanchor.
nonisolated(unsafe) private var syntheticAnchor = CGPoint.zero
nonisolated(unsafe) private var syntheticPosted = CGPoint.zero
nonisolated(unsafe) private var syntheticBounds = CGRect.null

/// Moves the pointer, and the item a held click is carrying, by a drag Stagehand posts.
/// Called on the MultitouchSupport thread; CGEvent posting is thread-safe. The cursor
/// is read only at a reanchor: posting is asynchronous, so a read every frame could
/// return a position from before the previous post and lose that frame's movement.
/// Movement under a point is kept for the next frame instead of posted, so a resting
/// finger's jitter does not shake the cursor.
private func postHeldClickDrag(_ move: HeldClickPointerMove) -> (posted: Bool, microseconds: Double) {
    if move.reanchor {
        guard let current = CGEvent(source: nil)?.location else { return (false, 0) }
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        guard CGGetActiveDisplayList(8, &displays, &count) == .success, count > 0 else { return (false, 0) }
        syntheticBounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        syntheticAnchor = current
        syntheticPosted = current
    }
    let bounds = syntheticBounds
    let target = CGPoint(x: min(max(syntheticAnchor.x + move.dx, bounds.minX), bounds.maxX - 1),
                         y: min(max(syntheticAnchor.y + move.dy, bounds.minY), bounds.maxY - 1))
    syntheticAnchor = target
    guard abs(target.x - syntheticPosted.x) >= 1 || abs(target.y - syntheticPosted.y) >= 1 else { return (false, 0) }
    let began = DispatchTime.now().uptimeNanoseconds
    guard let event = CGEvent(mouseEventSource: syntheticPointerSource, mouseType: .leftMouseDragged,
                              mouseCursorPosition: target, mouseButton: .left) else { return (false, 0) }
    event.setIntegerValueField(.mouseEventDeltaX, value: Int64((target.x - syntheticPosted.x).rounded()))
    event.setIntegerValueField(.mouseEventDeltaY, value: Int64((target.y - syntheticPosted.y).rounded()))
    event.post(tap: .cghidEventTap)
    syntheticPosted = target
    return (true, Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000)
}

extension GestureCallbackState {
    /// Handle one contact frame. Returns the delivery closure to run outside the lock when
    /// main-actor delivery needs scheduling. `now` is the uptime the input tap compares against.
    mutating func process(contacts touching: [GestureContact], touches frameTouches: [GestureFrameValidator.Touch],
                          rawCount count: Int32, flags: CGEventFlags, timestamp: Double,
                          now: TimeInterval, buttonDown: Bool = false) -> (@Sendable () -> Void)? {
        guard enabled else { return nil }
        guard frameValidator.accept(timestamp: timestamp, touches: frameTouches) else {
            // Drop the frame and any gesture it was part of. Enough corrupt frames in a
            // row mean the private data layout no longer matches; stop trusting it.
            // Ownership is left alone: the fingers are still down, and a stream of rejected
            // frames stops refreshing it, so the stale check releases the app's input.
            let wasDragging = recognizer.isDragging
            if ownership.ownsSequence { appInputLeaks.rejectedFrames &+= 1 }
            recognizer.cancelUntilLift()
            if wasDragging { pendingEvents.append(.cancelled) }
            if frameValidator.isExhausted {
                enabled = false
                failure = "Trackpad data from this version of macOS looks invalid, so gestures are off until Stagehand relaunches. Keyboard shortcuts still work."
            }
            if traceGestures {
                NSLog("[DEBUG-gesture] rejected frame t=%.3f raw=%d bad=%d", timestamp, count, frameValidator.badFrames)
            }
            guard wasDragging || failure != nil, !deliveryScheduled else { return nil }
            deliveryScheduled = true
            return scheduleDelivery
        }
        // After validation: a corrupt frame's contact IDs must not drop the held click.
        let snapshot = excludingHeldClick(from: touching, buttonDown: buttonDown)
        touchesLandedUptime = snapshot.isEmpty ? nil : touchesLandedUptime ?? now
        if snapshot.isEmpty {
            dropCheckRequested = false
        } else if buttonDown, !heldClickContactIDs.isEmpty, !heldClickCarriesDrop, !dropCheckRequested {
            // Only the main thread can read the drag pasteboard. Until it answers, these
            // fingers count as an ordinary swipe; the recognizer has no origin yet with
            // fewer fingers than that, so the answer can still change the count.
            dropCheckRequested = true
            dropCheckDue = true
        }
        if ignoredUntilLift {
            if snapshot.isEmpty { ignoredUntilLift = false }
            observeOwnership(contactCount: snapshot.count, eligible: false, now: now)
            return nil
        }
        let carriesDrop = buttonDown && heldClickCarriesDrop && !heldClickContactIDs.isEmpty
        recognizer.useFingerCount(carriesDrop ? NavigationGestureRecognizer.heldDropFingerCount
                                              : recognizer.configuredFingerCount)
        let modifiers = ShortcutBinding.carbonModifiers(for: flags)
        if !recognizer.hasContactSequence && snapshot.count >= recognizer.fingerCount {
            shortcutModifiers = shortcutEnabled
                ? shortcutGestureModifiers(for: flags, bindings: shortcutBindings) : nil
            if shortcutModifiers == nil && !unmodifiedEnabled {
                ignoredUntilLift = true
                observeOwnership(contactCount: snapshot.count, eligible: false, now: now)
                return nil
            }
        }
        // Own the app-bound input from the first frame with enough fingers, before the
        // recognizer has an origin or an axis. Deciding later lets an app arm its own swipe
        // on the first scroll deltas and touches. Ownership lasts until every finger lifts
        // even if the recognizer cancels, so the app never receives the tail of a sequence
        // whose beginning it did not see.
        observeOwnership(contactCount: snapshot.count, eligible: true, now: now)
        let modifiersChanged = shortcutModifiers.map { $0 != modifiers } ?? false
        let modifierCancelled = recognizer.isDragging && modifiersChanged
        if recognizer.hasContactSequence && modifiersChanged {
            recognizer.cancelUntilLift()
            if modifierCancelled { pendingEvents.append(.cancelled) }
        }
        var event = recognizer.update(contacts: snapshot, timestamp: timestamp)
        if let shortcutModifiers {
            switch event {
            case .began(let axis, let displacement, _):
                shortcutAxis = axis
                // A shortcut swipe acts on release like its arrow key. The plain gesture's
                // live ribbon preview follows a different direction and must not run here.
                event = .began(axis: axis, displacement: displacement, mode: .shortcut)
            case .ended(let displacement, let velocity, let action, _):
                let shortcutAction = action.flatMap { _ in
                    shortcutAxis.flatMap {
                        gestureShortcutAction(axis: $0, displacement: displacement,
                                              modifiers: shortcutModifiers, bindings: shortcutBindings,
                                              reverseDirection: reverseShortcutDirection)
                    }
                }
                event = .ended(displacement: displacement, velocity: velocity,
                               action: shortcutAction, mode: .shortcut)
            default: break
            }
        }
        if case .ended = event {
            shortcutModifiers = nil
            shortcutAxis = nil
        }
        if case .cancelled = event {
            shortcutModifiers = nil
            shortcutAxis = nil
        }
        if traceGestures, let event {
            if !heldClickContactIDs.isEmpty { NSLog("[DEBUG-gesture] held click excluded: %d", heldClickContactIDs.count) }
            switch event {
            case .changed: break
            default:
                NSLog("[DEBUG-gesture] contact t=%.3f raw=%d active=%d event=%@ reason=%@", timestamp, count,
                      snapshot.count, String(describing: event), recognizer.cancellationReason ?? "none")
            }
        }
        if let event {
            pendingEvents.append(event, arrival: InputArrival(
                source: .trackpad, eventUptime: touchFrameUptime(timestamp, now: now), receivedUptime: now,
                touchesLandedUptime: touchesLandedUptime))
        }
        guard event != nil || modifierCancelled else { return nil }
        guard !deliveryScheduled else { return nil }
        deliveryScheduled = true
        return scheduleDelivery
    }
}

extension GestureCallbackState {
    mutating func observeOwnership(contactCount: Int, eligible: Bool, now: TimeInterval) {
        let ownedBefore = ownership.ownsSequence
        if contactCount > 0, ownership.inLiftTail(now: now) { appInputLeaks.recordTailEnd(0) }
        ownership.observe(contactCount: contactCount, fingerCount: recognizer.fingerCount,
                          eligible: eligible, now: now)
        appInputLeaks.observe(contactCount: contactCount, ownedBefore: ownedBefore,
                              ownedAfter: ownership.ownsSequence, now: now)
    }

    /// Decide one app-bound event for the input tap.
    ///
    /// The held click is still a finger on the trackpad to macOS: with three fingers
    /// swiping beside it, macOS sees four and starts its own four-finger swipe between
    /// Spaces, which freezes the pointer and the carried item until it gives up. A held
    /// click known to carry a drop takes two swiping fingers instead; three still apply
    /// beside a window drag, and before the main thread has answered. While a
    /// held click is left out and Stagehand owns the other fingers, the Dock's gesture
    /// events are withheld too. Four fingers with no held click stay macOS's swipe.
    /// Passing them instead ran the Space swipe, and passing the first as cancelled made
    /// the Dock follow the held finger (4e4ce6a, 2026-10-26); neither freed the pointer,
    /// which macOS locks either way.
    mutating func suppress(_ kind: SuppressibleInputEvent, now: TimeInterval,
                           rawType: UInt32 = 0, eventTime: TimeInterval? = nil) -> Bool {
        guard enabled else { return false }
        guard case .dockControl = kind else {
            let tailWasActive = ownership.inLiftTail(now: now)
            let suppressed = ownership.suppress(kind, now: now)
            if tailWasActive, !ownership.liftTailPending {
                switch kind {
                case .scroll(phase: 1, _): appInputLeaks.recordTailEnd(1)
                case .scroll: appInputLeaks.recordTailEnd(2)
                default: appInputLeaks.recordTailEnd(3)
                }
            }
            if suppressed {
                appInputLeaks.recordWithheld(kind, ownership: ownership, now: now, rawType: rawType)
            } else {
                appInputLeaks.recordPassed(kind, ownership: ownership, now: now, rawType: rawType, eventTime: eventTime)
            }
            return suppressed
        }
        guard !heldClickContactIDs.isEmpty else { return false }
        // A Dock gesture beside a held click means macOS has locked the touch.
        pointerLockedBesideHeldClick = true
        guard ownership.suppress(.gesture, now: now) else { return false }
        withheldDockControlEvents &+= 1
        if traceGestures { NSLog("[DEBUG-gesture] dock gesture withheld beside a held click") }
        return true
    }

    /// The main thread's drag-pasteboard check this frame asked for, taken once.
    mutating func takeDropCheck() -> (@Sendable () -> Void)? {
        guard dropCheckDue else { return nil }
        dropCheckDue = false
        return requestDropCheck
    }

    /// Record the main thread's answer. Ignored while the button is up: an answer for a
    /// press that already ended must not carry into the next one.
    mutating func setHeldClickCarriesDrop(_ carries: Bool) {
        guard !carries || buttonWasDown else { return }
        heldClickCarriesDrop = carries
    }

    /// The pointer move Stagehand makes for macOS in this frame, in points (CG direction),
    /// or nil. Only while macOS has the touch locked for its own gesture, only the held
    /// finger is down, and macOS has sent no real drag recently: once it moves the pointer
    /// again, Stagehand stops within one frame, so the two never move it together.
    mutating func takeHeldClickPointerMove(now: TimeInterval, buttonDown: Bool) -> HeldClickPointerMove? {
        // Taken once: a frame the validator rejects never reaches excludingHeldClick,
        // and must not post the previous frame's movement again.
        let delta = heldClickFrameDelta
        heldClickFrameDelta = (0, 0)
        if !buttonDown { pointerLockedBesideHeldClick = false }
        if !pointerLockedBesideHeldClick { syntheticAnchorValid = false }
        guard enabled, buttonDown, pointerLockedBesideHeldClick, !heldClickContactIDs.isEmpty,
              previousFilteredCount == 0, now - lastRealPointerDrag > syntheticPointerHoldoff,
              delta.x != 0 || delta.y != 0 else { return nil }
        syntheticPointerEvents &+= 1
        if now - lastSyntheticFrame < 0.5 {
            syntheticStats.longestFrameGapMilliseconds = max(syntheticStats.longestFrameGapMilliseconds,
                                                             (now - lastSyntheticFrame) * 1_000)
        }
        lastSyntheticFrame = now
        let reanchor = !syntheticAnchorValid
        if reanchor { syntheticStats.reanchors &+= 1 }
        syntheticAnchorValid = true
        // MultitouchSupport y grows upward; CG y grows downward. A trackpad is wider than
        // it is tall, so a height is a smaller distance than a width.
        return HeldClickPointerMove(dx: delta.x * heldDragPointsPerPadWidth,
                                    dy: -delta.y * heldDragPointsPerPadWidth * trackpadAspect,
                                    reanchor: reanchor)
    }

    /// Leaves out the finger holding a click. It must have been touching in the frame
    /// before the button went down, and fewer fingers than a swipe were down, with no
    /// swipe under way: a swipe that presses the pad keeps its fingers, and fingers that
    /// land while a mouse button is already held are new in that frame.
    mutating func excludingHeldClick(from contacts: [GestureContact], buttonDown: Bool) -> [GestureContact] {
        let ids = Set(contacts.map(\.id))
        heldClickContactIDs.formIntersection(ids)
        if buttonDown, !buttonWasDown, !recognizer.hasContactSequence {
            if contacts.count < recognizer.configuredFingerCount {
                heldClickContactIDs = ids.intersection(previousContactIDs)
            } else if traceGestures {
                // The swipe fingers were down before the click: nothing is left out, and
                // the extra contact keeps a swipe from beginning, as before.
                NSLog("[DEBUG-gesture] click with %d contacts down; no held click left out", contacts.count)
            }
        }
        buttonWasDown = buttonDown
        previousContactIDs = ids
        heldClickFrameDelta = (0, 0)
        if !buttonDown {
            pointerLockedBesideHeldClick = false
            heldClickCarriesDrop = false
        }
        guard !heldClickContactIDs.isEmpty else {
            heldClickPositions.removeAll()
            pointerLockedBesideHeldClick = false
            return contacts
        }
        for contact in contacts where heldClickContactIDs.contains(contact.id) {
            if let previous = heldClickPositions[contact.id] {
                heldClickTravel += hypot(contact.x - previous.x, contact.y - previous.y)
                heldClickFrameDelta.x += contact.x - previous.x
                heldClickFrameDelta.y += contact.y - previous.y
            }
            heldClickPositions[contact.id] = (contact.x, contact.y)
        }
        heldClickPositions = heldClickPositions.filter { heldClickContactIDs.contains($0.key) }
        let filtered = contacts.filter { !heldClickContactIDs.contains($0.id) }
        previousFilteredCount = filtered.count
        return filtered
    }
}

@MainActor
final class GestureMonitor {
    /// Hidden preference that keeps the private framework from being loaded at all.
    static let disablePreferenceKey = "StagehandDisableTrackpadGestures"

    var onGesture: ((GestureNavigationEvent) -> Void)?
    /// Called on main when fingers land beside a held click: check whether it carries a
    /// drag-and-drop and answer with `setHeldClickCarriesDrop`.
    var onDropCheckRequested: (() -> Void)?
    /// Called on main after corrupt frames turned gestures off. `start()` keeps returning
    /// the message for the rest of the process.
    var onFailure: ((String) -> Void)?
    private(set) var isRunning = false
    private var dataFailure: String?
    private var framework: UnsafeMutableRawPointer?
    private var device: UnsafeMutableRawPointer?
    private var unregister: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void)?
    private var stopDevice: (@convention(c) (UnsafeMutableRawPointer) -> Void)?
    private var scrollTap: InputTapThread?
    private var generation: UInt64 = 0

    func start(fingerCount: Int = 4, unmodifiedEnabled: Bool, shortcutEnabled: Bool,
               shortcutBindings: [ShortcutBinding], reverseShortcutDirection: Bool) -> String? {
        guard !isRunning else { return nil }
        if UserDefaults.standard.bool(forKey: Self.disablePreferenceKey) {
            return "Trackpad gestures are turned off by the \(Self.disablePreferenceKey) setting. Keyboard shortcuts still work."
        }
        if let dataFailure { return dataFailure }
        guard AXIsProcessTrusted() else { return "Allow Stagehand in Accessibility settings to use gestures." }
        guard MemoryLayout<RawContact>.stride == rawContactStride,
              MemoryLayout<RawContact>.offset(of: \.normalized) == rawContactNormalizedOffset,
              MemoryLayout<RawContact>.offset(of: \.absolute) == rawContactAbsoluteOffset else {
            return "This version of macOS does not expose trackpad data Stagehand can use. Keyboard shortcuts still work."
        }
        guard installScrollTap() else { return "Gesture navigation couldn't start. Re-enable Accessibility for Stagehand, then try again." }
        // Keep the framework loaded for process lifetime: a late framework callback must never
        // jump into unloaded code. Only one built-in trackpad is in scope for the MVP.
        if framework == nil { framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL) }
        guard let framework,
              let createSymbol = dlsym(framework, "MTDeviceCreateDefault"),
              let registerSymbol = dlsym(framework, "MTRegisterContactFrameCallback"),
              let unregisterSymbol = dlsym(framework, "MTUnregisterContactFrameCallback"),
              let startSymbol = dlsym(framework, "MTDeviceStart"),
              let stopSymbol = dlsym(framework, "MTDeviceStop") else {
            removeScrollTap()
            return "Gesture navigation isn't available on this version of macOS. Keyboard shortcuts still work."
        }
        let create = unsafeBitCast(createSymbol, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        let register = unsafeBitCast(registerSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        let startDevice = unsafeBitCast(startSymbol, to: (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self)
        unregister = unsafeBitCast(unregisterSymbol, to: (@convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void).self)
        stopDevice = unsafeBitCast(stopSymbol, to: (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        guard let device = self.device ?? create() else {
            removeScrollTap()
            return "Stagehand couldn't find a built-in trackpad. Keyboard shortcuts still work."
        }
        self.device = device
        // Pointer distance for one trackpad width when Stagehand moves the pointer for a
        // held click. Hidden preference StagehandHeldDragPointsPerPadWidth, else 1.25
        // widths of the main display.
        let heldDragPointsPerPadWidth = (UserDefaults.standard.object(forKey: "StagehandHeldDragPointsPerPadWidth") as? Double)
            ?? 1.25 * Double(CGDisplayBounds(CGMainDisplayID()).width)
        let activeGeneration = generation
        gestureCallbackState.withLock { state in
            state = GestureCallbackState()
            state.recognizer = NavigationGestureRecognizer(fingerCount: fingerCount)
            state.enabled = true
            state.unmodifiedEnabled = unmodifiedEnabled
            state.shortcutEnabled = shortcutEnabled
            state.shortcutBindings = shortcutBindings
            state.reverseShortcutDirection = reverseShortcutDirection
            state.heldDragPointsPerPadWidth = heldDragPointsPerPadWidth
            state.requestDropCheck = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.generation == activeGeneration else { return }
                    self.onDropCheckRequested?()
                }
            }
            state.scheduleDelivery = { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, self.generation == activeGeneration else { return }
                    let (events, failure) = gestureCallbackState.withLock { state in
                        state.deliveryScheduled = false
                        return (state.pendingEvents.drainWithArrivals(), state.failure)
                    }
                    for (event, arrival) in events {
                        guard self.isRunning, self.generation == activeGeneration else { return }
                        InputArrival.delivering(arrival) { self.onGesture?(event) }
                        // The handoff ran synchronously and began its transfer if it navigated.
                        // Only now may the keyboard tap stop treating this release as pending.
                        if case .ended = event {
                            gestureCallbackState.withLock { $0.pendingEvents.completionDelivered() }
                        }
                    }
                    if let failure, self.isRunning, self.generation == activeGeneration {
                        self.dataFailure = failure
                        self.stop()
                        self.onFailure?(failure)
                    }
                }
            }
        }
        register(device, contactCallback)
        isRunning = true
        startDevice(device, 0)
        return nil
    }

    func stop() {
        if traceGestures, isRunning { NSLog("[DEBUG-gesture] monitor stopped") }
        gestureCallbackState.withLock { $0 = GestureCallbackState() }
        generation &+= 1
        let wasRunning = isRunning
        isRunning = false
        // Deliver cancellation synchronously before changing settings or dropping queued phases.
        if wasRunning { onGesture?(.cancelled) }
        if let device, wasRunning {
            unregister?(device, contactCallback)
            stopDevice?(device)
        }
        // Keep one default-device reference for process lifetime. Releasing a device while
        // its private dequeue thread exits can race the framework's own final release.
        // Reuse this handle on restart instead of allocating/leaking one per preference edit.
        removeScrollTap()
    }

    /// After sleep the framework's device handle may stop delivering frames. Forget it so
    /// the next start creates a fresh one. The old handle is intentionally not released
    /// (see `stop()`); one leaked reference per wake is the price of not racing the
    /// framework's dequeue thread.
    func invalidateDevice() {
        guard !isRunning else { return }
        device = nil
    }

    func takePendingGestureCompletion() -> GestureNavigationCompletion? {
        guard isRunning else { return nil }
        return gestureCallbackState.withLock { state in
            guard state.enabled else { return nil }
            return state.pendingEvents.takeCompletion()
        }
    }

    /// Safe from any thread. The keyboard tap uses it to hold typing that follows a release
    /// whose main-queue delivery has not run yet.
    nonisolated static func hasPendingGestureCompletion() -> Bool {
        gestureCallbackState.withLock { $0.enabled && $0.pendingEvents.hasCompletion }
    }

    /// Whether the held left button carries a drag-and-drop. Safe from any thread.
    nonisolated static func setHeldClickCarriesDrop(_ carries: Bool) {
        gestureCallbackState.withLock { $0.setHeldClickCarriesDrop(carries) }
    }

    /// Dock gesture events withheld beside a held click since gestures last started.
    nonisolated static func withheldDockControlEventCount() -> Int {
        gestureCallbackState.withLock { $0.withheldDockControlEvents }
    }

    /// What the input tap passed to apps around owned sequences since gestures last started.
    nonisolated static func appInputLeakSummary() -> String {
        gestureCallbackState.withLock { $0.appInputLeaks.summary }
    }

    /// How far held-click fingers have moved since gestures last started, in trackpad widths.
    nonisolated static func heldClickTravel() -> Double {
        gestureCallbackState.withLock { $0.heldClickTravel }
    }

    /// Pointer drags Stagehand posted for a held click since gestures last started.
    nonisolated static func syntheticPointerEventCount() -> Int {
        gestureCallbackState.withLock { $0.syntheticStats.posts }
    }

    /// How Stagehand's pointer moves went; `reset` clears the maxima for the next press.
    nonisolated static func syntheticPointerStats(reset: Bool) -> SyntheticPointerStats {
        gestureCallbackState.withLock { state in
            let stats = state.syntheticStats
            if reset {
                state.syntheticStats.longestFrameGapMilliseconds = 0
                state.syntheticStats.slowestPostMicroseconds = 0
            }
            return stats
        }
    }

    func cancelGestureSequence() {
        if traceGestures { NSLog("[DEBUG-gesture] sequence interrupted by app") }
        gestureCallbackState.withLock { state in
            state.recognizer.cancelUntilLift()
            state.pendingEvents.removeAll()
        }
    }

    private func installScrollTap() -> Bool {
        let scrollTap = InputTapThread()
        guard scrollTap.start() else { return false }
        self.scrollTap = scrollTap
        return true
    }

    private func removeScrollTap() {
        scrollTap?.stop()
        scrollTap = nil
    }
}

private let inputTapCallback: CGEventTapCallBack = { _, type, event, context in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let context { Unmanaged<InputTapThread>.fromOpaque(context).takeUnretainedValue().reenable() }
        return Unmanaged.passUnretained(event)
    }
    let kind: SuppressibleInputEvent = if type == .scrollWheel {
        .scroll(phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
    } else if type.rawValue == dockControlEventType {
        .dockControl
    } else if type.rawValue == UInt32(NSEvent.EventType.beginGesture.rawValue) {
        .gestureStart
    } else {
        .gesture
    }
    let now = ProcessInfo.processInfo.systemUptime
    if type == .leftMouseDragged {
        if event.getIntegerValueField(.eventSourceUserData) != syntheticPointerTag {
            gestureCallbackState.withLock {
                $0.lastRealPointerDrag = now
                $0.syntheticAnchorValid = false
            }
        }
        return Unmanaged.passUnretained(event)
    }
    let eventTime = eventUptime(event.timestamp, now: now)
    let suppress = gestureCallbackState.withLock { state in
        state.suppress(kind, now: now, rawType: type.rawValue, eventTime: eventTime)
    }
    return suppress ? nil : Unmanaged.passUnretained(event)
}

private let machTicksToSeconds: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1e9
}()

/// An event's own time on the `systemUptime` clock. `CGEventTimestamp` is documented in
/// nanoseconds but has been mach ticks on Apple silicon; take whichever reading is near now.
func eventUptime(_ timestamp: CGEventTimestamp, now: TimeInterval) -> TimeInterval? {
    guard timestamp != 0 else { return nil }
    let asNanoseconds = Double(timestamp) / 1e9
    let asTicks = Double(timestamp) * machTicksToSeconds
    let best = abs(asNanoseconds - now) < abs(asTicks - now) ? asNanoseconds : asTicks
    return abs(best - now) < 60 ? best : nil
}

/// Hosts the input tap on its own run loop. The tap filters every scroll and gesture
/// event on the system, so it must not wait behind Accessibility calls on the main
/// thread. Its callback only reads `gestureCallbackState`, which is lock-protected.
private final class InputTapThread: @unchecked Sendable {
    // Written on the tap thread before `ready` is signaled, then only read.
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    func start() -> Bool {
        // The thread retains this object until its run loop exits after `stop()`.
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                              options: .defaultTap, eventsOfInterest: suppressibleEventTypeMask,
                                              callback: inputTapCallback, userInfo: context) else {
                ready.signal()
                return
            }
            self.tap = tap
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // Invalidating the tap from another thread does not wake this run loop, so
            // `stop()` also stops it. The validity check covers a stop that lands first.
            while CFMachPortIsValid(tap),
                  CFRunLoopRunInMode(.defaultMode, 1e10, false) != .stopped {}
        }
        thread.name = "Stagehand input tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return tap != nil
    }

    func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
    }
}
