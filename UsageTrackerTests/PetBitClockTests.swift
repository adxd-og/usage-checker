import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime: "accumulated visible open time, next-bit
/// deadline … one bit at most every 20–40 s of visible open time, never in the first 1.5 s".
final class PetBitClockTests: XCTestCase {
    /// Monday 2026-10-26 13:48 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_793_022_480)

    func testTheFirstBitIsDue20To40SecondsOfVisibleTimeIn() {
        XCTAssertEqual(PetBitClock(random: PetRandomFixture.sequence([0])).nextBitAt, 20)
        XCTAssertEqual(PetBitClock(random: PetRandomFixture.sequence([0.5])).nextBitAt, 30)
        let latest = PetBitClock(random: PetRandomFixture.sequence([1])).nextBitAt
        XCTAssertLessThanOrEqual(latest, 40, "the range is closed: the largest draw may round to 40.0")
        XCTAssertGreaterThan(latest, 39.99)
    }

    func testABitIsDueOnceTheVisibleTimeReachesTheDeadline() {
        var clock = PetBitClock(random: PetRandomFixture.sequence([0]))
        clock.resume(at: t0)
        XCTAssertFalse(clock.isDue(at: t0 + 19.9))
        XCTAssertTrue(clock.isDue(at: t0 + 20))
    }

    func testOpenTimeAddsUpAcrossOpensAndClosedTimeDoesNotCount() {
        var clock = PetBitClock(random: PetRandomFixture.sequence([0]))
        clock.resume(at: t0)
        clock.pause(at: t0 + 12)
        XCTAssertEqual(clock.visibleTime(at: t0 + 500), 12)
        XCTAssertFalse(clock.isDue(at: t0 + 500), "closed, never due")
        clock.resume(at: t0 + 600)
        XCTAssertEqual(clock.visibleTime(at: t0 + 607), 19)
        XCTAssertFalse(clock.isDue(at: t0 + 607.9))
        XCTAssertTrue(clock.isDue(at: t0 + 608))
    }

    func testNeverInTheFirstSecondAndAHalfOfAnOpen() {
        var clock = PetBitClock(random: PetRandomFixture.sequence([0]))
        clock.resume(at: t0)
        clock.pause(at: t0 + 30)
        clock.resume(at: t0 + 100)
        XCTAssertFalse(clock.mayStartBit(at: t0 + 101.4))
        XCTAssertFalse(clock.isDue(at: t0 + 101.4), "30 s banked, past the deadline, but the open is 1.4 s old")
        XCTAssertTrue(clock.mayStartBit(at: t0 + 101.5))
        XCTAssertTrue(clock.isDue(at: t0 + 101.5))
    }

    func testAfterABitTheNextIsDue20To40SecondsOfVisibleTimeLater() {
        let random = PetRandomFixture.sequence([0, 0.5])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0)
        clock.reschedule(at: t0 + 21, random: random)
        XCTAssertEqual(clock.nextBitAt, 51)
        XCTAssertFalse(clock.isDue(at: t0 + 50.9))
        XCTAssertTrue(clock.isDue(at: t0 + 51))
    }

    func testResumingTwiceKeepsTheFirstStartAndPausingTwiceCountsOnce() {
        var clock = PetBitClock(random: PetRandomFixture.sequence([0]))
        clock.resume(at: t0)
        clock.resume(at: t0 + 5)
        XCTAssertEqual(clock.visibleTime(at: t0 + 10), 10)
        clock.pause(at: t0 + 10)
        clock.pause(at: t0 + 20)
        XCTAssertEqual(clock.visibleTime(at: t0 + 30), 10)
        XCTAssertFalse(clock.isRunning)
    }

    func testAClockSetBackAddsNothing() {
        var clock = PetBitClock(random: PetRandomFixture.sequence([0]))
        clock.resume(at: t0 + 10)
        XCTAssertEqual(clock.visibleTime(at: t0), 0)
        clock.pause(at: t0)
        XCTAssertEqual(clock.visibleTime(at: t0 + 100), 0)
    }
}
