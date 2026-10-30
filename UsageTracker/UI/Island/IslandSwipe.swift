import AppKit

/// A two-finger swipe right over the island goes Back (notch-island spec 2026-10-29 § 3.4).
/// AppKit hands a trackpad's two-finger travel as scroll-wheel events with a gesture phase;
/// this value adds one gesture's horizontal travel in the direction the fingers moved and fires
/// once when it is far and level enough. A mouse wheel (no gesture phase) and the momentum
/// after a flick never count. Only over the island itself: the island's window is larger than
/// its drawn shape, so a gesture counts only if its first event is inside the shape, and one
/// event outside it (or on another window) cancels the gesture for good (plan ruling R12, Codex
/// review finding 5). The controller feeds it every scroll event while the island is open and
/// lets the event go on, so scrolling is untouched. Pure.
struct IslandSwipe: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case began, changed, ended
        /// A wheel without a gesture phase, the fingers resting, or the momentum after a flick.
        case none
    }

    /// The fingers' travel to the right that makes a swipe, in points (owner 2026-10-30).
    static let distance: CGFloat = 60
    /// The travel must be at least this many times its vertical drift: a swipe, not a scroll.
    static let levelness: CGFloat = 2

    private var tracking = false
    private var fired = false
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0

    init() {}

    /// The fingers' horizontal movement for a scroll event's `scrollingDeltaX`: with natural
    /// scrolling (`isDirectionInvertedFromDevice`) the delta follows the fingers; without it
    /// the delta follows the content, the other way.
    static func fingerDeltaX(scrollingDeltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? scrollingDeltaX : -scrollingDeltaX
    }

    /// A scroll event's phase for the swipe: its gesture's, or none for a wheel, for fingers
    /// that rest without moving, and for the momentum after a flick.
    static func phase(gesture: NSEvent.Phase, momentum: NSEvent.Phase) -> Phase {
        guard momentum.isEmpty else { return .none }
        if gesture.contains(.began) { return .began }
        if gesture.contains(.changed) || gesture.contains(.stationary) { return .changed }
        if gesture.contains(.ended) || gesture.contains(.cancelled) { return .ended }
        return .none
    }

    /// One scroll event, with whether the pointer is inside the island's drawn shape; true
    /// exactly once per gesture, on the event that makes it a swipe right.
    mutating func feed(phase: Phase, fingerDeltaX: CGFloat, deltaY: CGFloat, inside: Bool) -> Bool {
        switch phase {
        case .began:
            tracking = inside
            fired = false
            dx = fingerDeltaX
            dy = deltaY
        case .changed:
            guard tracking else { return false }
            guard inside else {
                tracking = false
                return false
            }
            dx += fingerDeltaX
            dy += deltaY
        case .ended:
            tracking = false
            return false
        case .none:
            return false
        }
        guard tracking, !fired, dx >= Self.distance, dx >= Self.levelness * abs(dy) else { return false }
        fired = true
        return true
    }
}
