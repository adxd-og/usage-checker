import AppKit
import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.4 (two-finger swipe right goes Back; the
/// owner's 2026-10-30 note: 60 pt of finger travel) with the session's ruling that a swipe counts
/// only if it begins inside the drawn shape and is cancelled once it leaves: the thresholds at
/// their edges, the gesture's phases, momentum, and what a gesture's later events do.
final class IslandSwipeVerificationTests: XCTestCase {
    /// Feeds a whole gesture; the index of the event that fired, if any.
    private func fire(
        _ events: [(IslandSwipe.Phase, CGFloat, CGFloat, Bool)], into swipe: inout IslandSwipe
    ) -> [Int] {
        events.enumerated().compactMap { index, e in
            swipe.feed(phase: e.0, fingerDeltaX: e.1, deltaY: e.2, inside: e.3) ? index : nil
        }
    }

    func testSixtyIsTheThresholdAndJustUnderIsNot() {
        var under = IslandSwipe()
        XCTAssertEqual(fire([(.began, 0, 0, true), (.changed, 59.99, 0, true), (.ended, 0, 0, true)], into: &under), [])
        var exact = IslandSwipe()
        XCTAssertEqual(fire([(.began, 0, 0, true), (.changed, 60, 0, true)], into: &exact), [1])
        var one = IslandSwipe()
        XCTAssertEqual(fire([(.began, 60, 0, true)], into: &one), [0], "the first event may carry it all")
        XCTAssertEqual(IslandSwipe.distance, 60)
        XCTAssertEqual(IslandSwipe.levelness, 2)
    }

    func testTravelAddsUpOverEventsAndSignsCancel() {
        var swipe = IslandSwipe()
        let events: [(IslandSwipe.Phase, CGFloat, CGFloat, Bool)] = [
            (.began, 0, 0, true), (.changed, -50, 0, true), (.changed, 100, 0, true), (.changed, 9, 0, true),
        ]
        // −50 + 100 = 50, then 59: still under; the next nudge crosses.
        XCTAssertEqual(fire(events, into: &swipe), [])
        XCTAssertEqual(swipe.feed(phase: .changed, fingerDeltaX: 1, deltaY: 0, inside: true), true, "net 60")
    }

    func testTheVerticalDriftAllowanceIsHalfTheTravelEitherWay() {
        for sign: CGFloat in [1, -1] {
            var level = IslandSwipe()
            XCTAssertEqual(
                fire([(.began, 0, 0, true), (.changed, 60, 30 * sign, true)], into: &level), [1], "exactly 2×, drift \(sign)"
            )
            var steep = IslandSwipe()
            XCTAssertEqual(
                fire([(.began, 0, 0, true), (.changed, 60, 30.01 * sign, true)], into: &steep), [], "just past 2×, drift \(sign)"
            )
        }
        // A gesture that goes up first and then right fires once the travel outgrows the drift.
        var late = IslandSwipe()
        XCTAssertEqual(
            fire([(.began, 0, 0, true), (.changed, 10, 40, true), (.changed, 60, 0, true), (.changed, 20, 0, true)], into: &late),
            [3], "70 pt against 40 of drift needs 80"
        )
    }

    func testAGestureFiresOnceEvenIfItKeepsGoing() {
        var swipe = IslandSwipe()
        var events: [(IslandSwipe.Phase, CGFloat, CGFloat, Bool)] = [(.began, 0, 0, true)]
        events += Array(repeating: (.changed, 30, 0, true), count: 10)
        events += [(.ended, 0, 0, true)]
        XCTAssertEqual(fire(events, into: &swipe), [2])
    }

    func testEndingTheGestureStopsTrackingAndTheNextOneStartsClean() {
        var swipe = IslandSwipe()
        // 40 pt, ended; the next gesture's 40 pt must not add to it.
        XCTAssertEqual(
            fire([(.began, 0, 0, true), (.changed, 40, 0, true), (.ended, 0, 0, true),
                  (.changed, 40, 0, true), (.began, 40, 0, true)], into: &swipe),
            [], "40 + 40 across two gestures is not a swipe, and events after an end are not tracked"
        )
        // A new began restarts the sum even without an end between.
        var restart = IslandSwipe()
        XCTAssertEqual(
            fire([(.began, 0, 30, true), (.changed, 50, 0, true), (.began, 5, 0, true), (.changed, 55, 0, true)], into: &restart),
            [3], "the second began forgot the first's 30 pt of drift"
        )
    }

    func testMomentumAndWheelEventsInTheMiddleOfAGestureDoNotCountOrCancel() {
        var swipe = IslandSwipe()
        XCTAssertEqual(
            fire([(.began, 0, 0, true), (.changed, 30, 0, true), (.none, 500, 0, true), (.none, 500, 0, false),
                  (.changed, 30, 0, true)], into: &swipe),
            [4], "the .none events are ignored, neither adding travel nor ending the gesture"
        )
    }

    func testOnlyAGestureThatBeganInsideAndStayedInsideSwipes() {
        for outsideAt in 0..<4 {
            var swipe = IslandSwipe()
            var events: [(IslandSwipe.Phase, CGFloat, CGFloat, Bool)] = [
                (.began, 5, 0, true), (.changed, 20, 0, true), (.changed, 20, 0, true), (.changed, 20, 0, true),
            ]
            events[outsideAt].3 = false
            XCTAssertEqual(fire(events, into: &swipe), [], "an event outside at \(outsideAt)")
            // And stays cancelled to its end, whatever follows.
            XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 200, deltaY: 0, inside: true))
            XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: true))
            // The next gesture is a fresh one.
            XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
            XCTAssertTrue(swipe.feed(phase: .changed, fingerDeltaX: 61, deltaY: 0, inside: true))
        }
    }

    func testTheSwipeThatBeginsOutsideCarriesNoTravelIntoTheNextGesture() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 100, deltaY: 0, inside: false), "100 pt, outside")
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: false))
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 10, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 40, deltaY: 0, inside: true), "50, not 150")
    }

    func testAFreshValueNeverSwipesBeforeAnyEvent() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 100, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .none, fingerDeltaX: 100, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 100, deltaY: 0, inside: true))
    }

    func testEveryPhaseCombinationOfAScrollEvent() {
        let phases: [NSEvent.Phase] = [[], .mayBegin, .began, .stationary, .changed, .ended, .cancelled]
        let momenta: [NSEvent.Phase] = [[], .began, .changed, .ended]
        for gesture in phases {
            for momentum in momenta {
                let phase = IslandSwipe.phase(gesture: gesture, momentum: momentum)
                if !momentum.isEmpty { XCTAssertEqual(phase, .none, "momentum \(momentum) wins over \(gesture)") }
                else {
                    switch gesture {
                    case .began: XCTAssertEqual(phase, .began)
                    case .changed, .stationary: XCTAssertEqual(phase, .changed)
                    case .ended, .cancelled: XCTAssertEqual(phase, .ended)
                    default: XCTAssertEqual(phase, .none, "\(gesture)")
                    }
                }
            }
        }
    }

    func testTheFingersDirectionForBothScrollingSettingsAndBothSigns() {
        for delta: CGFloat in [-30, 0, 30] {
            XCTAssertEqual(IslandSwipe.fingerDeltaX(scrollingDeltaX: delta, invertedFromDevice: true), delta)
            XCTAssertEqual(IslandSwipe.fingerDeltaX(scrollingDeltaX: delta, invertedFromDevice: false), -delta)
        }
    }
}
