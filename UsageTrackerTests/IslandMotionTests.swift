import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.2: the numbers live in `IslandMotion` (springs open
/// 0.42 / 0.82, close 0.38 / 1.0, drill 0.40 / 0.86, back 0.32 / 1.0; the content's 120 ms
/// delay, 280 ms in, 100 ms out, 8 pt rise; Reduce Motion's 150 ms cross-fade), which motion
/// an open takes, and a spring as a function of time that turns around from where it is.
final class IslandMotionTests: XCTestCase {
    private func assertSpring(
        _ spring: Spring, response: Double, damping: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(spring.response, response, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(spring.dampingRatio, damping, accuracy: 1e-9, file: file, line: line)
    }

    func testTheSpringsAreTheSpecsNumbers() {
        assertSpring(IslandMotion.open, response: 0.42, damping: 0.82)
        assertSpring(IslandMotion.close, response: 0.38, damping: 1.0)
        assertSpring(IslandMotion.drill, response: 0.40, damping: 0.86)
        assertSpring(IslandMotion.back, response: 0.32, damping: 1.0)
    }

    func testTheContentStageTakesTheSpecsTimes() {
        XCTAssertEqual(IslandMotion.contentDelay, 0.12)
        XCTAssertEqual(IslandMotion.contentIn, 0.28)
        XCTAssertEqual(IslandMotion.contentOut, 0.10)
        XCTAssertEqual(IslandMotion.contentRise, 8)
        XCTAssertEqual(IslandMotion.reducedFade, 0.15)
        XCTAssertEqual(IslandMotion.drillSlide, 8)
    }

    func testTheIslandsContentRisesAndThePanelFadesInPlace() {
        XCTAssertEqual(IslandMotion.rise(for: .island), 8)
        XCTAssertEqual(IslandMotion.rise(for: .panel), 0, "the panel's content is its body: it never moves")
    }

    func testTheIslandSpringsThePanelFadesAndReduceMotionCrossFadesBoth() {
        XCTAssertEqual(IslandMotion.style(kind: .island, reduceMotion: false), .spring)
        XCTAssertEqual(IslandMotion.style(kind: .panel, reduceMotion: false), .contentOnly)
        XCTAssertEqual(IslandMotion.style(kind: .island, reduceMotion: true), .crossFade)
        XCTAssertEqual(IslandMotion.style(kind: .panel, reduceMotion: true), .crossFade)
    }

    func testTheContentEasesInAndOutAndUnderReduceMotionGoesWithTheIsland() {
        let fadeIn = IslandMotion.Fade(duration: 0.28, curve: .easeOut)
        let fadeOut = IslandMotion.Fade(duration: 0.10, curve: .easeOut)
        XCTAssertEqual(IslandMotion.contentFade(showing: true, style: .spring), fadeIn)
        XCTAssertEqual(IslandMotion.contentFade(showing: false, style: .spring), fadeOut)
        XCTAssertEqual(IslandMotion.contentFade(showing: true, style: .contentOnly), fadeIn)
        XCTAssertEqual(IslandMotion.contentFade(showing: false, style: .contentOnly), fadeOut)
        XCTAssertNil(IslandMotion.contentFade(showing: true, style: .crossFade))
        XCTAssertNil(IslandMotion.contentFade(showing: false, style: .crossFade))
    }

    func testOnlyReduceMotionFadesTheWholeIsland() {
        XCTAssertEqual(IslandMotion.islandFade(style: .crossFade), IslandMotion.Fade(duration: 0.15, curve: .linear))
        XCTAssertNil(IslandMotion.islandFade(style: .spring))
        XCTAssertNil(IslandMotion.islandFade(style: .contentOnly))
    }

    func testTheOpenSpringOvershootsByAboutOnePercent() {
        let track = IslandSpringTrack.resting(at: 0).retargeted(to: 1, with: IslandMotion.open, at: 0)
        let peak = stride(from: 0.0, through: 1.5, by: 0.001).map { track.value(at: $0) }.max() ?? 0
        XCTAssertEqual(peak, 1.0111, accuracy: 0.0005)
    }

    func testTheCloseSpringNeverPassesTheNotch() {
        let track = IslandSpringTrack.resting(at: 1).retargeted(to: 0, with: IslandMotion.close, at: 0)
        let lowest = stride(from: 0.0, through: 1.5, by: 0.001).map { track.value(at: $0) }.min() ?? -1
        XCTAssertGreaterThanOrEqual(lowest, -1e-9)
    }

    func testATrackFollowsSwiftUIsSpringFromItsStart() {
        let track = IslandSpringTrack.resting(at: 0).retargeted(to: 1, with: IslandMotion.open, at: 5)
        XCTAssertEqual(track.value(at: 5), 0, accuracy: 1e-12)
        XCTAssertEqual(track.value(at: 5.12), IslandMotion.open.value(target: 1.0, time: 5.12 - 5), accuracy: 1e-9)
        XCTAssertEqual(track.value(at: 5.12), 0.6, accuracy: 0.001)
    }

    func testATrackHoldsItsStartingValueBeforeItsStart() {
        let track = IslandSpringTrack.resting(at: 0.4).retargeted(to: 1, with: IslandMotion.open, at: 5)
        XCTAssertEqual(track.value(at: 4.9), 0.4, accuracy: 1e-12)
    }

    func testARetargetKeepsTheValueAndTheVelocityOfThatMoment() {
        let opening = IslandSpringTrack.resting(at: 0).retargeted(to: 1, with: IslandMotion.open, at: 0)
        let closing = opening.retargeted(to: 0, with: IslandMotion.close, at: 0.2)
        XCTAssertEqual(closing.value(at: 0.2), opening.value(at: 0.2), accuracy: 1e-12)
        XCTAssertEqual(closing.velocity(at: 0.2), opening.velocity(at: 0.2), accuracy: 1e-9)
        XCTAssertEqual(closing.value(at: 0.2), 0.8902, accuracy: 0.001)
        XCTAssertGreaterThan(closing.velocity(at: 0.2), 0, "still rising at the turn: it carries on a moment, then falls")
    }

    func testATrackIsAtRestOnlyCloseToItsTargetAndSlow() {
        let track = IslandSpringTrack.resting(at: 0).retargeted(to: 1, with: IslandMotion.open, at: 0)
        XCTAssertTrue(track.isMoving)
        XCTAssertFalse(track.isAtRest(at: 0.367), "at the overshoot's peak")
        XCTAssertFalse(track.isAtRest(at: 0.5))
        XCTAssertTrue(track.isAtRest(at: 0.7))
    }

    func testARestingTrackStaysWhereItIs() {
        let track = IslandSpringTrack.resting(at: 1)
        XCTAssertFalse(track.isMoving)
        XCTAssertEqual(track.value(at: 0), 1)
        XCTAssertEqual(track.value(at: 99), 1)
        XCTAssertEqual(track.velocity(at: 99), 0)
        XCTAssertTrue(track.isAtRest(at: 0))
    }
}
