import CoreGraphics
import Foundation

/// The hover hint over the notch (notch-island spec 2026-10-29 § 3.1, D13) on an injected clock: the
/// pointer enters, the controller waits `IslandMotion.hintDelay`, the shape breathes; the pointer
/// leaves, it reverses from where it is. Reduce Motion shows an outline and moves nothing. It never
/// opens anything, and shows nothing over an open island. Pure.
struct NotchHint: Equatable, Sendable {
    /// What the resting view draws at one moment.
    struct Look: Equatable, Sendable {
        let down: CGFloat
        let widen: CGFloat
        let outlined: Bool

        static let rest = Look(down: 0, widen: 0, outlined: false)
    }

    private(set) var pointerInside = false
    /// The hint shows, or is on its way up.
    private(set) var isUp = false
    private var outlined = false
    private var track = IslandSpringTrack.resting(at: 0)

    /// The spring moves: frames are wanted.
    var needsFrames: Bool { track.isMoving }

    /// Nothing shows and nothing moves: the window goes back to its resting frame.
    var isAtRest: Bool { !isUp && !track.isMoving }

    /// The pointer came in. True: start the wait. A repeated enter, or one with the hint up, asks nothing.
    mutating func pointerEntered() -> Bool {
        let wasInside = pointerInside
        pointerInside = true
        return !wasInside && !isUp
    }

    /// The wait is over: up, if the pointer stayed and the island is closed.
    mutating func delayElapsed(at now: TimeInterval, islandClosed: Bool, reduceMotion: Bool) {
        guard pointerInside, !isUp, islandClosed else { return }
        isUp = true
        if reduceMotion {
            outlined = true
        } else {
            track = track.retargeted(to: 1, with: IslandMotion.hintUp, at: now)
        }
    }

    /// The pointer went out: back from where it is.
    mutating func pointerLeft(at now: TimeInterval) {
        pointerInside = false
        guard isUp else { return }
        isUp = false
        outlined = false
        if track.to != 0 {
            track = track.retargeted(to: 0, with: IslandMotion.hintBack, at: now)
        }
    }

    /// The island is opening, or the displays changed: gone at once. A pointer still inside brings
    /// no hint back until it has left and come in again.
    mutating func end() {
        isUp = false
        outlined = false
        track = .resting(at: 0)
    }

    /// One frame: a spring at rest stops asking for frames.
    mutating func advance(to now: TimeInterval) {
        if track.isMoving, track.isAtRest(at: now) {
            track = .resting(at: track.to)
        }
    }

    func look(at time: TimeInterval) -> Look {
        let value = CGFloat(max(track.value(at: time), 0))
        return Look(down: IslandMotion.hintDown * value, widen: IslandMotion.hintWiden * value, outlined: outlined)
    }
}
