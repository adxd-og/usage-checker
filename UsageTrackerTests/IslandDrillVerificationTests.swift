import SwiftUI
import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.2 (Drill-down: 0.40 / 0.86, back
/// 0.32 / 1.0, no source tile → cross-fade + 8 pt slide; Interrupt: reverses from the current
/// value; Reduce Motion: 150 ms cross-fade) — the literal numbers, and the reversal swept over
/// every kind of move and every moment of it rather than at one instant.
@MainActor
final class IslandDrillVerificationTests: XCTestCase {
    private typealias Page = IslandNavigation.Page
    private let claude = Page.provider("claude")
    private let codex = Page.provider("codex")

    private struct Scenario {
        let name: String
        let from: Page
        let to: Page
        let motion: IslandDrill.Motion
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "drill", from: .all, to: codex, motion: .reveal),
            Scenario(name: "back", from: codex, to: .all, motion: .reveal),
            Scenario(name: "shortcut slide", from: .all, to: codex, motion: .slide),
            Scenario(name: "sibling slide", from: claude, to: codex, motion: .slide),
            Scenario(name: "slide back to all", from: codex, to: .all, motion: .slide),
        ]
    }

    // MARK: The spec's numbers

    func testTheSpringsAreTheSpecsNumbers() {
        XCTAssertEqual(IslandDrill.spring(toward: codex), Spring(response: 0.40, dampingRatio: 0.86))
        XCTAssertEqual(IslandDrill.spring(toward: .all), Spring(response: 0.32, dampingRatio: 1.0))
        XCTAssertEqual(IslandMotion.drillSlide, 8, "the slide")
        XCTAssertEqual(IslandMotion.reducedFade, 0.15, "Reduce Motion's cross-fade")
    }

    func testADrillAndABackRunOnTheirOwnSpringsAtEveryMoment() {
        let drillSpring = Spring(response: 0.40, dampingRatio: 0.86)
        let backSpring = Spring(response: 0.32, dampingRatio: 1.0)
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 7)
        var back = IslandDrill(at: codex)
        back.move(to: .all, motion: .reveal, at: 7)
        for dt in stride(from: 0.0, through: 1.0, by: 0.025) {
            XCTAssertEqual(drill.progress(at: 7 + dt), drillSpring.value(target: 1, time: dt), accuracy: 1e-9, "drill \(dt)")
            XCTAssertEqual(drill.velocity(at: 7 + dt), drillSpring.velocity(target: 1, time: dt), accuracy: 1e-9, "drill v \(dt)")
            XCTAssertEqual(back.progress(at: 7 + dt), backSpring.value(target: 1, time: dt), accuracy: 1e-9, "back \(dt)")
        }
    }

    // MARK: Reversal continuity (§ 3.2, Interrupt)

    func testAReversalAtEveryMomentKeepsTheValueAndTheVelocityOfThatMoment() {
        for scenario in scenarios {
            for step in 0...80 {
                let t = Double(step) * 0.0075
                var drill = IslandDrill(at: scenario.from)
                drill.move(to: scenario.to, motion: scenario.motion, at: 0)
                var probe = drill
                probe.advance(to: t)
                guard probe.isMoving else { continue }
                let value = drill.progress(at: t)
                let speed = drill.velocity(at: t)
                // The turning-around request has whatever look the reducer gives it: the move's
                // own stays.
                drill.move(to: scenario.from, motion: .reveal, at: t)
                let tag = "\(scenario.name) at \(t)"
                XCTAssertTrue(drill.isMoving, tag)
                XCTAssertEqual(drill.from, scenario.to, tag)
                XCTAssertEqual(drill.to, scenario.from, tag)
                XCTAssertEqual(drill.frame(at: t).motion, scenario.motion, "keeps its look: \(tag)")
                XCTAssertEqual(drill.progress(at: t), 1 - value, accuracy: 1e-12, "value: \(tag)")
                XCTAssertEqual(drill.velocity(at: t), -speed, accuracy: 1e-9, "velocity: \(tag)")
                // The turned move is the target's spring from there.
                let spring = IslandDrill.spring(toward: scenario.from)
                let later = IslandSpringTrack(
                    from: 1 - value, to: 1, initialVelocity: -speed, start: t, spring: spring
                ).value(at: t + 0.13)
                XCTAssertEqual(drill.progress(at: t + 0.13), later, accuracy: 1e-9, "path: \(tag)")
                // And it settles on the page it turned to.
                drill.advance(to: t + 5)
                XCTAssertFalse(drill.isMoving, tag)
                XCTAssertEqual(drill.frame(at: t + 5), .resting(at: scenario.from), tag)
            }
        }
    }

    func testTheOvershootOfADrillReversesFromBeyondTheEnd() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 0)
        // The drill spring peaks just past 1; find a moment there.
        let peakTime = stride(from: 0.0, through: 1.0, by: 0.001).max { drill.progress(at: $0) < drill.progress(at: $1) } ?? 0
        let peak = drill.progress(at: peakTime)
        XCTAssertGreaterThan(peak, 1)
        var probe = drill
        probe.advance(to: peakTime)
        XCTAssertTrue(probe.isMoving, "it has not settled at its peak")
        drill.move(to: .all, motion: .reveal, at: peakTime)
        XCTAssertEqual(drill.progress(at: peakTime), 1 - peak, accuracy: 1e-12, "a hair below 0, not clamped away")
    }

    func testRepeatedReversalsNeverBreakTheValue() {
        for scenario in scenarios {
            var drill = IslandDrill(at: scenario.from)
            drill.move(to: scenario.to, motion: scenario.motion, at: 0)
            var target = scenario.from
            var t = 0.0
            for _ in 0..<6 {
                t += 0.031
                var probe = drill
                probe.advance(to: t)
                guard probe.isMoving else { break }
                let before = drill.progress(at: t)
                drill.move(to: target, motion: .reveal, at: t)
                XCTAssertEqual(drill.progress(at: t), 1 - before, accuracy: 1e-12, "\(scenario.name) \(t)")
                XCTAssertEqual(drill.frame(at: t).motion, scenario.motion)
                target = target == scenario.from ? scenario.to : scenario.from
            }
            drill.advance(to: t + 5)
            XCTAssertFalse(drill.isMoving)
            XCTAssertEqual(drill.to, target == scenario.from ? scenario.to : scenario.from, scenario.name)
        }
    }

    // MARK: Reduce Motion

    func testUnderReduceMotionEveryMoveButACutIsTheFadeAndACutStaysACut() {
        for move: IslandNavigation.Move in [.drillFromTile, .drillWithoutTile, .back, .sibling] {
            XCTAssertEqual(IslandDrill.motion(for: move, reduceMotion: true), .fade, "\(move)")
            XCTAssertNotEqual(IslandDrill.motion(for: move, reduceMotion: false), .fade, "\(move)")
            XCTAssertNotEqual(IslandDrill.motion(for: move, reduceMotion: false), .cut, "\(move)")
        }
        XCTAssertEqual(IslandDrill.motion(for: .cut, reduceMotion: true), .cut)
        XCTAssertEqual(IslandDrill.motion(for: .cut, reduceMotion: false), .cut)
    }

    func testEachMoveHasItsLookWithoutReduceMotion() {
        XCTAssertEqual(IslandDrill.motion(for: .drillFromTile, reduceMotion: false), .reveal)
        XCTAssertEqual(IslandDrill.motion(for: .back, reduceMotion: false), .reveal)
        XCTAssertEqual(IslandDrill.motion(for: .drillWithoutTile, reduceMotion: false), .slide, "a shortcut has no tile")
        XCTAssertEqual(IslandDrill.motion(for: .sibling, reduceMotion: false), .slide, "a logo has no tile")
        XCTAssertEqual(IslandDrill.motion(for: .cut, reduceMotion: false), .cut)
    }

    func testTheFadeIsLinearOverOneHundredFiftyMilliseconds() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .fade, at: 3)
        for step in 0...10 {
            let dt = 0.015 * Double(step)
            XCTAssertEqual(drill.progress(at: 3 + dt), Double(step) / 10, accuracy: 1e-9, "\(dt)")
        }
        XCTAssertEqual(drill.progress(at: 3.5), 1, "never past 1")
        XCTAssertEqual(drill.progress(at: 2.9), 0, "never before 0")
    }

    func testAReducedReversalAtEveryMomentFadesBackFromWhereItWas() {
        for step in 1..<15 {
            let t = 0.01 * Double(step)
            var drill = IslandDrill(at: .all)
            drill.move(to: codex, motion: .fade, at: 0)
            let value = drill.progress(at: t)
            drill.move(to: .all, motion: .fade, at: t)
            XCTAssertEqual(drill.progress(at: t), 1 - value, accuracy: 1e-12, "\(t)")
            // The rest of the fade takes the share it has left: value × 150 ms.
            let rest = value * IslandMotion.reducedFade
            var early = drill
            early.advance(to: t + rest - 0.001)
            XCTAssertTrue(early.isMoving, "\(t)")
            var done = drill
            done.advance(to: t + rest + 0.001)
            XCTAssertFalse(done.isMoving, "\(t)")
            XCTAssertEqual(done.frame(at: t + rest + 0.001), .resting(at: .all))
        }
    }

    func testAReducedMoveStartedByTheModelFadesInOneHundredFiftyMillisecondsAndSettles() {
        let model = IslandNavigationModel()
        let ids = ["claude", "codex"]
        model.apply(.open(subject: nil), providers: ids, reduceMotion: true, at: 0)
        model.apply(.tile("codex"), providers: ids, reduceMotion: true, at: 10)
        let frame = model.frame
        XCTAssertEqual(frame.motion, .fade)
        XCTAssertEqual(frame.progress, 0, accuracy: 1e-12)
        model.advance(to: 10.075)
        let half = model.frame
        XCTAssertEqual(half.progress, 0.5, accuracy: 1e-9)
        model.advance(to: 10.151)
        let moving = model.isMoving
        let rested = model.frame
        XCTAssertFalse(moving)
        XCTAssertEqual(rested, .resting(at: codex))
    }

    // MARK: A third page

    func testAThirdPageSetsOffFromWhicheverPageIsMoreInViewAtEveryMoment() {
        for step in 0..<30 {
            let t = 0.005 * Double(step)
            var drill = IslandDrill(at: .all)
            drill.move(to: claude, motion: .reveal, at: 0)
            var probe = drill
            probe.advance(to: t)
            guard probe.isMoving else { continue }
            let value = drill.progress(at: t)
            drill.move(to: codex, motion: .slide, at: t)
            XCTAssertEqual(drill.to, codex)
            XCTAssertEqual(drill.from, value < 0.5 ? .all : claude, "value \(value)")
            XCTAssertEqual(drill.progress(at: t), 0, accuracy: 1e-12)
            XCTAssertEqual(drill.frame(at: t).motion, .slide)
        }
    }

    func testACutFromAnyMomentOfAnyMoveIsAtRestAtOnce() {
        for scenario in scenarios {
            for target in [Page.all, claude, codex] {
                var drill = IslandDrill(at: scenario.from)
                drill.move(to: scenario.to, motion: scenario.motion, at: 0)
                drill.move(to: target, motion: .cut, at: 0.05)
                if target == scenario.to {
                    // Already going there: nothing to cut.
                    continue
                }
                XCTAssertFalse(drill.isMoving, "\(scenario.name) \(target)")
                XCTAssertEqual(drill.frame(at: 0.05), .resting(at: target))
            }
        }
    }
}
