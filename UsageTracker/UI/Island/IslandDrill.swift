import SwiftUI

/// The content moving between two pages in time (notch-island spec 2026-10-29 § 3.2,
/// Drill-down; § 3.4): the tile growing into its page on the drill spring (0.40 / 0.86), the
/// page going back into its tile on the back spring (0.32 / 1.0), a cross-fade with an 8 pt
/// slide where there is no tile to grow from, and Reduce Motion's 150 ms cross-fade. Like
/// `IslandTransition`, a value on an injected clock: `progress(at:)` is the move at any time,
/// a reversal turns around from the value and the velocity of that moment (§ 3.2, Interrupt),
/// and the move settles on the first `advance` after it has come to rest — no timer, no
/// animation completion. Pure.
struct IslandDrill: Equatable, Sendable {
    typealias Page = IslandNavigation.Page

    /// How a move looks (`IslandDrillLook` draws it).
    enum Motion: Equatable, Sendable {
        /// The tile grows into its page, or the page goes back into its tile.
        case reveal
        /// Cross-fade, the outgoing page sinking and the incoming one rising
        /// `IslandMotion.drillSlide`.
        case slide
        /// Reduce Motion: a 150 ms cross-fade, nothing moves.
        case fade
        /// At once.
        case cut
    }

    /// One moment of a move, as the views draw it. At rest `from == to`.
    struct Frame: Equatable, Sendable {
        let from: Page
        let to: Page
        let motion: Motion
        /// 0 at `from`, 1 at `to`; past 1 while the drill spring overshoots.
        let progress: Double

        static func resting(at page: Page) -> Frame {
            Frame(from: page, to: page, motion: .cut, progress: 1)
        }

        var isMoving: Bool { from != to }
    }

    /// The look a reducer's move takes (§ 3.2): the reveal for a tile's drill and every Back
    /// (the tile is always on All), the slide where there is no tile (a shortcut, a sibling),
    /// the cross-fade under Reduce Motion, at once for a cut.
    static func motion(for move: IslandNavigation.Move, reduceMotion: Bool) -> Motion {
        if move == .cut { return .cut }
        if reduceMotion { return .fade }
        switch move {
        case .drillFromTile, .back: return .reveal
        case .drillWithoutTile, .sibling: return .slide
        case .cut: return .cut
        }
    }

    /// Back's critically damped spring toward All, the drill's toward a page.
    static func spring(toward page: Page) -> Spring {
        page == .all ? IslandMotion.back : IslandMotion.drill
    }

    /// The page left; `to` again at rest.
    private(set) var from: Page
    /// The page moved to, or shown at rest.
    private(set) var to: Page
    private(set) var motion: Motion = .cut
    private var track: IslandSpringTrack = .resting(at: 1)
    /// Reduce Motion's fade: where it set off and when.
    private var fadeFrom: Double = 0
    private var fadeStart: TimeInterval = 0

    init(at page: Page = .all) {
        from = page
        to = page
    }

    var isMoving: Bool { from != to }

    /// 0 at `from`, 1 at `to`; 1 at rest.
    func progress(at time: TimeInterval) -> Double {
        guard isMoving else { return 1 }
        switch motion {
        case .reveal, .slide: return track.value(at: time)
        case .fade: return min(1, fadeFrom + max(0, time - fadeStart) / IslandMotion.reducedFade)
        case .cut: return 1
        }
    }

    /// Progress per second.
    func velocity(at time: TimeInterval) -> Double {
        guard isMoving else { return 0 }
        switch motion {
        case .reveal, .slide: return track.velocity(at: time)
        case .fade: return progress(at: time) < 1 ? 1 / IslandMotion.reducedFade : 0
        case .cut: return 0
        }
    }

    func frame(at time: TimeInterval) -> Frame {
        guard isMoving else { return .resting(at: to) }
        return Frame(from: from, to: to, motion: motion, progress: progress(at: time))
    }

    /// Moves to `page` with `motion` from `now`, after applying what was due by then. Nothing
    /// when it already rests on or moves to `page`. A cut lands at once. Toward the page it is
    /// coming from, the move turns around from its value and velocity and keeps its look; toward
    /// a third page it sets off afresh from the page more in view.
    mutating func move(to page: Page, motion: Motion, at now: TimeInterval) {
        advance(to: now)
        guard page != to else { return }
        guard motion != .cut else {
            reset(at: page)
            return
        }
        if isMoving, page == from {
            let value = progress(at: now)
            let speed = velocity(at: now)
            from = to
            to = page
            setOff(from: 1 - value, velocity: -speed, at: now)
            return
        }
        from = isMoving && progress(at: now) < 0.5 ? from : to
        to = page
        self.motion = motion
        setOff(from: 0, velocity: 0, at: now)
    }

    /// Settles the move once it is at rest: the spring close to its target and slow, the fade
    /// run out. A `now` before that changes nothing.
    mutating func advance(to now: TimeInterval) {
        guard isMoving else { return }
        let settled: Bool
        switch motion {
        case .reveal, .slide: settled = track.isAtRest(at: now)
        case .fade: settled = progress(at: now) >= 1
        case .cut: settled = true
        }
        if settled {
            reset(at: to)
        }
    }

    /// At rest on `page` at once, from any move: an open, a cut.
    mutating func reset(at page: Page) {
        self = IslandDrill(at: page)
    }

    private mutating func setOff(from value: Double, velocity: Double, at now: TimeInterval) {
        switch motion {
        case .reveal, .slide:
            track = IslandSpringTrack(
                from: value, to: 1, initialVelocity: velocity, start: now, spring: Self.spring(toward: to)
            )
        case .fade:
            fadeFrom = value
            fadeStart = now
        case .cut:
            break
        }
    }
}
