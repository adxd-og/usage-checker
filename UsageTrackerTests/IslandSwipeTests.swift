import AppKit
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4: a two-finger swipe right over the island goes Back. One
/// gesture's horizontal travel, in the direction the fingers moved, fires once past 60 pt when
/// it is at least twice its vertical drift; a swipe left, a scroll, a mouse wheel and the
/// momentum after a flick never do. Only over the island itself: a gesture that begins outside
/// its drawn shape never counts, and one that leaves the shape is cancelled for good (Codex
/// review finding 5 — the island's window is larger than its shape).
final class IslandSwipeTests: XCTestCase {
    func testSixtyPointsToTheRightAreOneSwipe() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 10, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 25, deltaY: 1, inside: true))
        XCTAssertTrue(swipe.feed(phase: .changed, fingerDeltaX: 25, deltaY: 1, inside: true), "60 pt, level")
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 40, deltaY: 0, inside: true), "once per gesture")
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: true))
    }

    func testTheNextGestureCanSwipeAgain() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertTrue(swipe.feed(phase: .changed, fingerDeltaX: 70, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertTrue(swipe.feed(phase: .changed, fingerDeltaX: 70, deltaY: 0, inside: true))
    }

    func testASwipeLeftIsNotBack() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: -10, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: -80, deltaY: 0, inside: true))
    }

    func testADiagonalIsAScrollNotASwipe() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 70, deltaY: 40, inside: true), "70 is less than twice 40")
    }

    func testAWheelAndTheMomentumAfterAFlickNeverSwipe() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .none, fingerDeltaX: 200, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 30, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .none, fingerDeltaX: 200, deltaY: 0, inside: true), "momentum after the gesture")
    }

    func testTravelWithoutABeginningIsNotTracked() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 100, deltaY: 0, inside: true))
    }

    func testAGestureThatBeginsOutsideTheShapeNeverSwipes() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: false))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 100, deltaY: 0, inside: true), "it moved in later")
    }

    func testLeavingTheShapeCancelsTheGestureForGood() {
        var swipe = IslandSwipe()
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 40, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 30, deltaY: 0, inside: false), "70 pt, but over the transparent rest")
        XCTAssertFalse(swipe.feed(phase: .changed, fingerDeltaX: 30, deltaY: 0, inside: true), "back inside: still cancelled")
        XCTAssertFalse(swipe.feed(phase: .ended, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertFalse(swipe.feed(phase: .began, fingerDeltaX: 0, deltaY: 0, inside: true))
        XCTAssertTrue(swipe.feed(phase: .changed, fingerDeltaX: 70, deltaY: 0, inside: true), "the next gesture counts")
    }

    func testTheFingersDirectionFollowsTheScrollingSetting() {
        XCTAssertEqual(IslandSwipe.fingerDeltaX(scrollingDeltaX: 12, invertedFromDevice: true), 12, "natural scrolling")
        XCTAssertEqual(IslandSwipe.fingerDeltaX(scrollingDeltaX: 12, invertedFromDevice: false), -12)
    }

    func testAScrollEventsPhaseIsItsGesturesAndMomentumIsNone() {
        XCTAssertEqual(IslandSwipe.phase(gesture: .began, momentum: []), .began)
        XCTAssertEqual(IslandSwipe.phase(gesture: .changed, momentum: []), .changed)
        XCTAssertEqual(IslandSwipe.phase(gesture: .stationary, momentum: []), .changed)
        XCTAssertEqual(IslandSwipe.phase(gesture: .ended, momentum: []), .ended)
        XCTAssertEqual(IslandSwipe.phase(gesture: .cancelled, momentum: []), .ended)
        XCTAssertEqual(IslandSwipe.phase(gesture: .mayBegin, momentum: []), .none)
        XCTAssertEqual(IslandSwipe.phase(gesture: [], momentum: []), .none, "a mouse wheel")
        XCTAssertEqual(IslandSwipe.phase(gesture: [], momentum: .changed), .none, "momentum")
    }
}
