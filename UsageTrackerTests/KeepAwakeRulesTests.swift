import XCTest
@testable import Omelette

/// Spec 2026-10-26 keep awake with the lid closed, § Design › Behaviour ("Timed only":
/// 1 minute to 7 d 23 h 59 min, no indefinitely; "Battery floor": on battery and below 25 %) and
/// § UI (`KeepAwakeRules.duration(days:hours:minutes:)` rejects zero, negatives and anything
/// from 8 days on; hours and minutes carry over; no clamping).
final class KeepAwakeRulesTests: XCTestCase {
    func testDaysHoursAndMinutesAddUpToSeconds() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 1, hours: 2, minutes: 3), 93_780)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 1), 60)
    }

    func testZeroIsRefused() {
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 0))
    }

    func testHoursAndMinutesOverTheirRangeCarryOver() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 30, minutes: 0), 108_000)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 75), 4_500)
        XCTAssertEqual(KeepAwakeRules.duration(days: 6, hours: 24, minutes: 0), 604_800)
    }

    func testANegativeFieldIsRefusedNotClamped() {
        XCTAssertNil(KeepAwakeRules.duration(days: -1, hours: 0, minutes: 5))
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: -3, minutes: 0))
    }

    func testSevenDaysIsAcceptedAndAnythingPastItIsRefusedNotCapped() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 0, minutes: 0), 604_800)
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 23, minutes: 59), 691_140)
        XCTAssertNil(KeepAwakeRules.duration(days: 7, hours: 23, minutes: 60))
        XCTAssertNil(KeepAwakeRules.duration(days: 8, hours: 0, minutes: 0))
        XCTAssertNil(KeepAwakeRules.duration(days: 9, hours: 0, minutes: 0))
        XCTAssertEqual(KeepAwakeRules.duration(days: 6, hours: 23, minutes: 61), 604_860)
        XCTAssertNil(KeepAwakeRules.duration(days: 7, hours: 23, minutes: 61))
    }

    /// The daemon's own check (D4): the privileged side refuses rather than caps.
    func testTheHelperAcceptsOneMinuteToSevenDaysAndNothingElse() {
        XCTAssertTrue(KeepAwakeRules.accepts(duration: 60))
        XCTAssertTrue(KeepAwakeRules.accepts(duration: 604_800))
        XCTAssertTrue(KeepAwakeRules.accepts(duration: 691_140))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 59.9))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 691_140.5))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 0))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: -60))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: .infinity))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: .nan))
    }

    func testARememberedDurationSplitsBackIntoTheThreeFields() {
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 60), KeepAwakeRules.Parts(days: 0, hours: 1, minutes: 0))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 1_470), KeepAwakeRules.Parts(days: 1, hours: 0, minutes: 30))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 10_080), KeepAwakeRules.Parts(days: 7, hours: 0, minutes: 0))
    }

    func testARememberedDurationOutsideTheRangeComesBackInsideIt() {
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 0), KeepAwakeRules.Parts(days: 0, hours: 0, minutes: 1))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 20_000), KeepAwakeRules.Parts(days: 7, hours: 23, minutes: 59))
    }

    func testBelowTwentyFivePercentOnBatteryIsBelowTheFloor() {
        XCTAssertTrue(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: true, percent: 24)))
        XCTAssertFalse(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: true, percent: 25)))
        XCTAssertFalse(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: false, percent: 5)))
    }

    /// § Behaviour › Visible: the app "keeps a local countdown for the deadline".
    func testAnArmedStatePastItsDeadlineReadsAsEndedByTheDeadline() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        let armed = KeepAwakeState.armed(deadline: t0, floorEnabled: true)
        XCTAssertEqual(KeepAwakeRules.effectiveState(armed, now: t0), .ended(at: t0, reason: .deadline))
        XCTAssertEqual(KeepAwakeRules.effectiveState(armed, now: t0 - 1), armed)
        XCTAssertEqual(KeepAwakeRules.effectiveState(.idle, now: t0), .idle)
        XCTAssertEqual(KeepAwakeRules.effectiveState(.ended(at: t0, reason: .cancelled), now: t0 + 60), .ended(at: t0, reason: .cancelled))
    }

    func testOnlyAnArmedStateBeforeItsDeadlineIsActive() {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertTrue(KeepAwakeRules.isActive(.armed(deadline: t0 + 60, floorEnabled: true), now: t0))
        XCTAssertFalse(KeepAwakeRules.isActive(.armed(deadline: t0 + 60, floorEnabled: true), now: t0 + 60))
        XCTAssertFalse(KeepAwakeRules.isActive(.idle, now: t0))
        XCTAssertFalse(KeepAwakeRules.isActive(.ended(at: t0, reason: .deadline), now: t0))
    }
}
