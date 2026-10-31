import SwiftUI

/// The island's motion numbers (notch-island spec 2026-10-29 § 3.2): the springs, the content
/// stage's timing, the fades, and which motion an open or a close takes. The sequence in
/// time lives in `IslandTransition`. Pure.
enum IslandMotion {
    // MARK: Springs (SwiftUI response / damping ratio; spec § 2, the competitors' values)

    /// The shape out of the notch to the open island (CodeIsland, codex-island).
    static let open = Spring(response: 0.42, dampingRatio: 0.82)
    /// The shape back into the notch, critically damped: it never passes the notch.
    static let close = Spring(response: 0.38, dampingRatio: 1.0)
    /// A tile growing into its provider page (P3b's drill-down).
    static let drill = Spring(response: 0.40, dampingRatio: 0.86)
    /// A provider page going back into its tile (P3b).
    static let back = Spring(response: 0.32, dampingRatio: 1.0)
    /// The notch's breath going up and back (D13): the island's own springs, as the P0 spike had them.
    static let hintUp = open
    static let hintBack = close

    // MARK: The content stage

    /// After the shape sets off, the content waits this long ...
    static let contentDelay: TimeInterval = 0.12
    /// ... then fades in and rises over this long.
    static let contentIn: TimeInterval = 0.28
    /// On a close the content fades out over this long, then the shape shrinks.
    static let contentOut: TimeInterval = 0.10
    /// How far the island's content rises as it comes in, and sinks as it goes.
    static let contentRise: CGFloat = 8
    /// Reduce Motion: open, close and drill are a cross-fade this long.
    static let reducedFade: TimeInterval = 0.15
    /// A drill with no source tile (an ear, a shortcut): the page slides this far as it
    /// cross-fades (P3b).
    static let drillSlide: CGFloat = 8

    // MARK: The notch hint (§ 3.1, D13; the P0 spike's numbers)

    /// How long the pointer stays on the notch before it breathes.
    static let hintDelay: TimeInterval = 0.15
    /// How far the notch's lower edge moves down (the spec's 4–6).
    static let hintDown: CGFloat = 5
    /// How far each side moves out.
    static let hintWiden: CGFloat = 3

    /// A spring is at rest this close to its target and this slow (the P0 spike's values):
    /// 0.0005 of a 700 pt open is a third of a point.
    static let restDistance: Double = 0.0005
    static let restSpeed: Double = 0.01

    /// How far the content sits below its place while hidden. On the island it rises inside
    /// the shape, which is what the hit test reads; the panel's content is its body, so it
    /// fades in place and is never drawn away from where it takes the mouse.
    static func rise(for kind: IslandDisplayResolver.Kind) -> CGFloat {
        switch kind {
        case .island: return contentRise
        case .panel: return 0
        }
    }

    // MARK: Which motion

    enum Style: Equatable, Sendable {
        /// The island: its shape springs out of the notch and back, the content staged after
        /// it on the way in and before it on the way out.
        case spring
        /// The panel: no shape of its own to spring (its content is its body), so the content
        /// stage alone.
        case contentOnly
        /// Reduce Motion: the whole island or panel cross-fades at full size.
        case crossFade
    }

    /// The island springs, the panel fades its content, Reduce Motion cross-fades either.
    static func style(kind: IslandDisplayResolver.Kind, reduceMotion: Bool) -> Style {
        if reduceMotion { return .crossFade }
        switch kind {
        case .island: return .spring
        case .panel: return .contentOnly
        }
    }

    // MARK: Fades

    struct Fade: Equatable, Sendable {
        enum Curve: Equatable, Sendable {
            case easeOut
            case linear
        }

        let duration: TimeInterval
        let curve: Curve

        var animation: Animation {
            switch curve {
            case .easeOut: return .easeOut(duration: duration)
            case .linear: return .linear(duration: duration)
            }
        }
    }

    /// How the content comes in (`showing`) or goes out: eased, 280 ms in, 100 ms out. Under
    /// Reduce Motion it goes with the whole island's cross-fade instead: nil, at once.
    static func contentFade(showing: Bool, style: Style) -> Fade? {
        switch style {
        case .spring, .contentOnly:
            return Fade(duration: showing ? contentIn : contentOut, curve: .easeOut)
        case .crossFade:
            return nil
        }
    }

    /// How the whole island fades: only under Reduce Motion, 150 ms, linear; otherwise at once.
    static func islandFade(style: Style) -> Fade? {
        style == .crossFade ? Fade(duration: reducedFade, curve: .linear) : nil
    }
}

/// One value moved by a SwiftUI `Spring`, as a function of time (spec § 3.2): where it set
/// off, toward what, how fast. Evaluated from SwiftUI's own curve at any time, never stepped,
/// so the island's motion follows an injected clock exactly. A retarget sets off again from
/// the value and velocity of that moment, so an interrupted motion turns around without a
/// jump. Pure.
struct IslandSpringTrack: Equatable, Sendable {
    let from: Double
    let to: Double
    let initialVelocity: Double
    let start: TimeInterval
    /// nil: at rest at `to`.
    let spring: Spring?

    /// At rest at `value`.
    static func resting(at value: Double) -> IslandSpringTrack {
        IslandSpringTrack(from: value, to: value, initialVelocity: 0, start: 0, spring: nil)
    }

    var isMoving: Bool { spring != nil }

    /// The value at `time`; before the start, the starting value.
    func value(at time: TimeInterval) -> Double {
        guard let spring else { return to }
        return from + spring.value(target: to - from, initialVelocity: initialVelocity, time: max(time - start, 0))
    }

    /// The velocity at `time`, in value per second.
    func velocity(at time: TimeInterval) -> Double {
        guard let spring else { return 0 }
        return spring.velocity(target: to - from, initialVelocity: initialVelocity, time: max(time - start, 0))
    }

    /// Close enough to the target and slow enough to stop (`IslandMotion.restDistance`,
    /// `restSpeed`). A resting track always is.
    func isAtRest(at time: TimeInterval) -> Bool {
        guard isMoving else { return true }
        return abs(value(at: time) - to) < IslandMotion.restDistance
            && abs(velocity(at: time)) < IslandMotion.restSpeed
    }

    /// Toward `target` with `spring` from `time`, setting off from this track's value and
    /// velocity at that moment.
    func retargeted(to target: Double, with spring: Spring, at time: TimeInterval) -> IslandSpringTrack {
        IslandSpringTrack(
            from: value(at: time), to: target, initialVelocity: velocity(at: time), start: time, spring: spring
        )
    }
}
