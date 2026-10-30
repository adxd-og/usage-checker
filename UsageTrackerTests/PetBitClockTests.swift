import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime and the owner's note of 2026-10-30 (first look at
/// the pet): "accumulated visible open time, next-bit deadline … one bit at most every 7–10 s of
/// visible open time, each open's first 2–4 s into it, never in the first 1.5 s".
final class PetBitClockTests: XCTestCase {
    /// Monday 2026-10-26 13:48 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_793_022_480)

    func testBeforeAnyOpenTheDeadlineIsOneSpacingAway() {
        XCTAssertEqual(PetBitClock(random: PetRandomFixture.sequence([0])).nextBitAt, 7)
        XCTAssertEqual(PetBitClock(random: PetRandomFixture.sequence([0.5])).nextBitAt, 8.5)
        let latest = PetBitClock(random: PetRandomFixture.sequence([1])).nextBitAt
        XCTAssertLessThanOrEqual(latest, 10, "the range is closed: the largest draw may round to 10.0")
        XCTAssertGreaterThan(latest, 9.99)
    }

    func testAnOpensFirstBitIsDue2To4SecondsIntoIt() {
        for (draw, due) in [(0.0, 2.0), (0.5, 3.0)] {
            let random = PetRandomFixture.sequence([0.99, draw])
            var clock = PetBitClock(random: random)
            clock.resume(at: t0, random: random)
            XCTAssertEqual(clock.nextBitAt, due)
            XCTAssertFalse(clock.isDue(at: t0 + due - 0.1))
            XCTAssertTrue(clock.isDue(at: t0 + due))
        }
        let random = PetRandomFixture.sequence([0.99, 1])
        var latest = PetBitClock(random: random)
        latest.resume(at: t0, random: random)
        XCTAssertLessThanOrEqual(latest.nextBitAt, 4, "the range is closed: the largest draw may round to 4.0")
        XCTAssertGreaterThan(latest.nextBitAt, 3.99)
    }

    func testAnOpenAfterALongClosedTimeHasItsFirstBit2To4SecondsIn() {
        let random = PetRandomFixture.sequence([0, 0, 0, 0.5])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.reschedule(at: t0 + 2, random: random)
        XCTAssertEqual(clock.nextBitAt, 9, "2 s seen and a spacing of 7")
        clock.pause(at: t0 + 3)
        clock.resume(at: t0 + 10_000, random: random)
        XCTAssertEqual(clock.nextBitAt, 6, "3 s seen and 3 s into this open, sooner than the 9 it had")
        XCTAssertFalse(clock.isDue(at: t0 + 10_002.9))
        XCTAssertTrue(clock.isDue(at: t0 + 10_003))
    }

    func testADeadlineSoonerThanTheOpensDrawStands() {
        let random = PetRandomFixture.sequence([0, 0, 0.99])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.pause(at: t0 + 1)
        clock.resume(at: t0 + 100, random: random)
        XCTAssertEqual(clock.nextBitAt, 2, "due at 2 s of visible time, not 1 s + 3.98 s")
    }

    func testResumingWhileRunningChangesNothingAndDrawsNothing() {
        var draws = 0
        let random = PetRandom {
            draws += 1
            return 0
        }
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        XCTAssertEqual(draws, 2, "the clock's first deadline, the open's first bit")
        let before = clock
        clock.resume(at: t0 + 1, random: random)
        clock.resume(at: t0 + 2, random: random)
        XCTAssertEqual(draws, 2, "a tick calls it every frame")
        XCTAssertEqual(clock, before)
    }

    func testABitIsDueOnceTheVisibleTimeReachesTheDeadline() {
        let random = PetRandomFixture.sequence([0, 0.5])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        XCTAssertFalse(clock.isDue(at: t0 + 2.9))
        XCTAssertTrue(clock.isDue(at: t0 + 3))
    }

    func testOpenTimeAddsUpAcrossOpensAndClosedTimeDoesNotCount() {
        let random = PetRandomFixture.sequence([0, 0, 0])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.pause(at: t0 + 12)
        XCTAssertEqual(clock.visibleTime(at: t0 + 500), 12)
        XCTAssertFalse(clock.isDue(at: t0 + 500), "closed, never due")
        clock.resume(at: t0 + 600, random: random)
        XCTAssertEqual(clock.visibleTime(at: t0 + 607), 19)
    }

    func testNeverInTheFirstSecondAndAHalfOfAnOpen() {
        let random = PetRandomFixture.sequence([0, 0, 0])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.pause(at: t0 + 30)
        clock.resume(at: t0 + 100, random: random)
        XCTAssertFalse(clock.mayStartBit(at: t0 + 101.4))
        XCTAssertFalse(clock.isDue(at: t0 + 101.4), "30 s banked, past the deadline, but the open is 1.4 s old")
        XCTAssertTrue(clock.mayStartBit(at: t0 + 101.5))
        XCTAssertTrue(clock.isDue(at: t0 + 101.5))
    }

    func testAfterABitTheNextIsDue7To10SecondsOfVisibleTimeLater() {
        let random = PetRandomFixture.sequence([0, 0, 0.5])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.reschedule(at: t0 + 3, random: random)
        XCTAssertEqual(clock.nextBitAt, 11.5)
        XCTAssertFalse(clock.isDue(at: t0 + 11.4))
        XCTAssertTrue(clock.isDue(at: t0 + 11.5))
    }

    func testResumingTwiceKeepsTheFirstStartAndPausingTwiceCountsOnce() {
        let random = PetRandomFixture.sequence([0, 0])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0, random: random)
        clock.resume(at: t0 + 5, random: random)
        XCTAssertEqual(clock.visibleTime(at: t0 + 10), 10)
        clock.pause(at: t0 + 10)
        clock.pause(at: t0 + 20)
        XCTAssertEqual(clock.visibleTime(at: t0 + 30), 10)
        XCTAssertFalse(clock.isRunning)
    }

    func testAClockSetBackAddsNothing() {
        let random = PetRandomFixture.sequence([0, 0])
        var clock = PetBitClock(random: random)
        clock.resume(at: t0 + 10, random: random)
        XCTAssertEqual(clock.visibleTime(at: t0), 0)
        clock.pause(at: t0)
        XCTAssertEqual(clock.visibleTime(at: t0 + 100), 0)
    }
}
