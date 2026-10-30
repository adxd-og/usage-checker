import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.2 (Drill-down, Interrupt, Reduce Motion) and § 3.4: a page
/// move on an injected clock — the drill spring 0.40 / 0.86 toward a page, the back spring
/// 0.32 / 1.0 toward All, Reduce Motion's 150 ms cross-fade; a reversal turns around from the
/// value and the velocity of that moment; the move settles on the first advance after it
/// rests; a cut and a reset stop it. Times are literal seconds.
final class IslandDrillTests: XCTestCase {
    private let claude = IslandNavigation.Page.provider("claude")
    private let codex = IslandNavigation.Page.provider("codex")

    func testAtRestThePageIsShownWholeAndNothingMoves() {
        let drill = IslandDrill(at: codex)
        XCTAssertFalse(drill.isMoving)
        XCTAssertEqual(drill.to, codex)
        XCTAssertEqual(drill.frame(at: 5), .resting(at: codex))
        XCTAssertEqual(drill.progress(at: 5), 1)
        XCTAssertEqual(drill.velocity(at: 5), 0)
    }

    func testATilesDrillFollowsTheDrillSpring() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 10)
        XCTAssertTrue(drill.isMoving)
        let frame = drill.frame(at: 10.1)
        XCTAssertEqual(frame.from, .all)
        XCTAssertEqual(frame.to, codex)
        XCTAssertEqual(frame.motion, .reveal)
        XCTAssertEqual(drill.progress(at: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(frame.progress, IslandMotion.drill.value(target: 1.0, time: 0.1), accuracy: 1e-9)
    }

    func testTheDrillOvershootsByLessThanOnePercent() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 0)
        let peak = stride(from: 0.0, through: 1.5, by: 0.001).map { drill.progress(at: $0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThan(peak, 1.01)
    }

    func testBackFollowsTheBackSpringAndNeverPassesAll() {
        var drill = IslandDrill(at: codex)
        drill.move(to: .all, motion: .reveal, at: 0)
        XCTAssertEqual(drill.progress(at: 0.1), IslandMotion.back.value(target: 1.0, time: 0.1), accuracy: 1e-9)
        let peak = stride(from: 0.0, through: 1.5, by: 0.001).map { drill.progress(at: $0) }.max() ?? 2
        XCTAssertLessThanOrEqual(peak, 1 + 1e-9)
    }

    func testEveryMoveTowardAPageTakesTheDrillSpring() {
        var shortcut = IslandDrill(at: .all)
        shortcut.move(to: codex, motion: .slide, at: 0)
        XCTAssertEqual(shortcut.progress(at: 0.1), IslandMotion.drill.value(target: 1.0, time: 0.1), accuracy: 1e-9)
        var sibling = IslandDrill(at: claude)
        sibling.move(to: codex, motion: .slide, at: 0)
        XCTAssertEqual(sibling.progress(at: 0.1), IslandMotion.drill.value(target: 1.0, time: 0.1), accuracy: 1e-9)
    }

    func testTheMoveSettlesOnTheFirstAdvanceAfterItRests() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 10)
        drill.advance(to: 10.2)
        XCTAssertTrue(drill.isMoving, "still on its way at 200 ms")
        drill.advance(to: 11.5)
        XCTAssertFalse(drill.isMoving)
        XCTAssertEqual(drill.frame(at: 11.5), .resting(at: codex))
    }

    func testAReversalTurnsAroundFromTheValueAndTheVelocityOfThatMoment() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 0)
        let value = drill.progress(at: 0.1)
        let speed = drill.velocity(at: 0.1)
        drill.move(to: .all, motion: .reveal, at: 0.1)
        let frame = drill.frame(at: 0.1)
        XCTAssertEqual(frame.from, codex)
        XCTAssertEqual(frame.to, .all)
        XCTAssertEqual(frame.motion, .reveal)
        XCTAssertEqual(drill.progress(at: 0.1), 1 - value, accuracy: 1e-12)
        XCTAssertEqual(drill.velocity(at: 0.1), -speed, accuracy: 1e-9)
        XCTAssertEqual(
            drill.progress(at: 0.3),
            1 - value + IslandMotion.back.value(target: value, initialVelocity: -speed, time: 0.2),
            accuracy: 1e-9
        )
    }

    func testAReversedSlideStaysASlide() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .slide, at: 0)
        drill.move(to: .all, motion: .reveal, at: 0.05)
        XCTAssertEqual(drill.frame(at: 0.05).motion, .slide, "the move keeps its look as it turns")
    }

    func testUnderReduceMotionTheMoveIsAHundredAndFiftyMillisecondFade() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .fade, at: 0)
        XCTAssertEqual(drill.progress(at: 0.075), 0.5, accuracy: 1e-12)
        drill.advance(to: 0.149)
        XCTAssertTrue(drill.isMoving)
        drill.advance(to: 0.15)
        XCTAssertFalse(drill.isMoving)
        XCTAssertEqual(drill.frame(at: 0.15), .resting(at: codex))
    }

    func testAReducedReversalFadesBackFromWhereItWas() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .fade, at: 0)
        drill.move(to: .all, motion: .fade, at: 0.06)
        XCTAssertEqual(drill.progress(at: 0.06), 0.6, accuracy: 1e-9)
        XCTAssertEqual(drill.progress(at: 0.12), 1, accuracy: 1e-9)
        drill.advance(to: 0.13)
        XCTAssertEqual(drill.frame(at: 0.13), .resting(at: .all))
    }

    func testACutMovesAtOnce() {
        var drill = IslandDrill(at: codex)
        drill.move(to: .all, motion: .cut, at: 3)
        XCTAssertFalse(drill.isMoving)
        XCTAssertEqual(drill.frame(at: 3), .resting(at: .all))
    }

    func testAMoveToWhereItAlreadyGoesChangesNothing() {
        var resting = IslandDrill(at: .all)
        resting.move(to: .all, motion: .reveal, at: 0)
        XCTAssertEqual(resting, IslandDrill(at: .all))
        var moving = IslandDrill(at: .all)
        moving.move(to: codex, motion: .reveal, at: 0)
        let before = moving
        moving.move(to: codex, motion: .slide, at: 0.05)
        XCTAssertEqual(moving, before)
    }

    func testAThirdPageMidMoveSetsOffFromThePageMoreInView() {
        var early = IslandDrill(at: .all)
        early.move(to: claude, motion: .reveal, at: 0)
        early.move(to: codex, motion: .slide, at: 0.01)
        XCTAssertEqual(early.frame(at: 0.01).from, .all)
        XCTAssertEqual(early.frame(at: 0.01).to, codex)
        XCTAssertEqual(early.progress(at: 0.01), 0, accuracy: 1e-12)
        var late = IslandDrill(at: .all)
        late.move(to: claude, motion: .reveal, at: 0)
        late.move(to: codex, motion: .slide, at: 0.3)
        XCTAssertEqual(late.frame(at: 0.3).from, claude)
        XCTAssertEqual(late.frame(at: 0.3).motion, .slide)
    }

    func testAResetStopsAnyMove() {
        var drill = IslandDrill(at: .all)
        drill.move(to: codex, motion: .reveal, at: 0)
        drill.reset(at: .all)
        XCTAssertFalse(drill.isMoving)
        XCTAssertEqual(drill.frame(at: 0.1), .resting(at: .all))
    }

    func testEachMoveTakesItsMotion() {
        XCTAssertEqual(IslandDrill.motion(for: .drillFromTile, reduceMotion: false), .reveal)
        XCTAssertEqual(IslandDrill.motion(for: .back, reduceMotion: false), .reveal)
        XCTAssertEqual(IslandDrill.motion(for: .drillWithoutTile, reduceMotion: false), .slide)
        XCTAssertEqual(IslandDrill.motion(for: .sibling, reduceMotion: false), .slide)
        XCTAssertEqual(IslandDrill.motion(for: .cut, reduceMotion: false), .cut)
        for move in [IslandNavigation.Move.drillFromTile, .back, .drillWithoutTile, .sibling] {
            XCTAssertEqual(IslandDrill.motion(for: move, reduceMotion: true), .fade, "\(move)")
        }
        XCTAssertEqual(IslandDrill.motion(for: .cut, reduceMotion: true), .cut)
    }
}
