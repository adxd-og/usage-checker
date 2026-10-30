import SwiftUI
import XCTest
@testable import Omelette

/// Verification of `IslandMotion` and `IslandSpringTrack` against notch-island spec 2026-10-29
/// § 3.2 (the springs; interrupt: reverses from the current value) and plan M1 / M10: the
/// track's velocity is the slope of its value, a retarget keeps both, and the fades the views
/// animate with are the ones the stage names.
final class IslandMotionVerificationTests: XCTestCase {
    private let h = 1e-6

    private func slope(_ track: IslandSpringTrack, at time: TimeInterval) -> Double {
        (track.value(at: time + h) - track.value(at: time - h)) / (2 * h)
    }

    func testATracksVelocityIsTheSlopeOfItsValueAndItSetsOffAtItsInitialVelocity() {
        for spring in [IslandMotion.open, IslandMotion.close, IslandMotion.drill, IslandMotion.back] {
            let rising = IslandSpringTrack(from: 0.2, to: 1, initialVelocity: 3, start: 4, spring: spring)
            XCTAssertEqual(rising.velocity(at: 4), 3, accuracy: 1e-9)
            XCTAssertEqual((rising.value(at: 4 + h) - rising.value(at: 4)) / h, 3, accuracy: 1e-3)
            for offset in [0.02, 0.1, 0.2, 0.37, 0.5, 0.8] {
                XCTAssertEqual(
                    rising.velocity(at: 4 + offset), slope(rising, at: 4 + offset), accuracy: 1e-3, "\(offset)"
                )
            }
        }
    }

    func testAChainOfRetargetsNeverJumpsInValueOrVelocity() {
        var track = IslandSpringTrack.resting(at: 0)
        var time = 0.0
        var target = 1.0
        for _ in 0..<40 {
            let before = (track.value(at: time), track.velocity(at: time))
            track = track.retargeted(to: target, with: target == 1 ? IslandMotion.open : IslandMotion.close, at: time)
            XCTAssertEqual(track.value(at: time), before.0, accuracy: 1e-12)
            XCTAssertEqual(track.velocity(at: time), before.1, accuracy: 1e-9)
            target = 1 - target
            time += 0.043
        }
    }

    func testARetargetAtTheSameInstantTwiceChangesNothing() {
        let a = IslandSpringTrack.resting(at: 0).retargeted(to: 1, with: IslandMotion.open, at: 0)
        let once = a.retargeted(to: 0, with: IslandMotion.close, at: 0.15)
        let twice = once.retargeted(to: 0, with: IslandMotion.close, at: 0.15)
        for time in [0.15, 0.2, 0.4, 0.8] {
            XCTAssertEqual(twice.value(at: time), once.value(at: time), accuracy: 1e-9, "\(time)")
        }
    }

    func testTheCriticallyDampedCloseFromTheOpenNeverGoesBelowTheNotchAtRest() {
        // From the fully open island, and from where the open spring overshoots.
        for start in [1.0, 1.0111] {
            let track = IslandSpringTrack(from: start, to: 1, initialVelocity: 0, start: 0, spring: nil)
                .retargeted(to: 0, with: IslandMotion.close, at: 0)
            let values = stride(from: 0.0, through: 1.5, by: 0.001).map { track.value(at: $0) }
            XCTAssertGreaterThanOrEqual(values.min() ?? -1, -1e-9)
            XCTAssertTrue(track.isAtRest(at: 0.62), "rest from 0.605 s")
            XCTAssertFalse(track.isAtRest(at: 0.58))
        }
    }

    func testTheFadesAnimateWithTheCurveAndDurationTheyName() {
        let ease = IslandMotion.Fade(duration: 0.28, curve: .easeOut)
        let linear = IslandMotion.Fade(duration: 0.15, curve: .linear)
        XCTAssertEqual(ease.animation, Animation.easeOut(duration: 0.28))
        XCTAssertEqual(linear.animation, Animation.linear(duration: 0.15))
        XCTAssertNotEqual(ease.animation, Animation.linear(duration: 0.28))
        XCTAssertNotEqual(linear.animation, Animation.easeOut(duration: 0.15))
        XCTAssertNotEqual(ease.animation, Animation.easeOut(duration: 0.10))
    }
}
