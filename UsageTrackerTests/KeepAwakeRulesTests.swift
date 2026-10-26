import XCTest
@testable import Omelette

/// Spec 2026-10-26 keep awake with the lid closed, § Design › Behaviour ("Timed only":
/// 1 minute to 7 days, no indefinitely; "Battery floor": on battery and below 25 %) and
/// § UI (`KeepAwakeRules.duration(days:hours:minutes:)` clamps, rejects zero, caps at 7 days).
final class KeepAwakeRulesTests: XCTestCase {
    func testDaysHoursAndMinutesAddUpToSeconds() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 1, hours: 2, minutes: 3), 93_780)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 1), 60)
    }

    func testZeroIsRefused() {
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 0))
    }

    func testEachStepperIsClampedToItsRange() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 30, minutes: 0), 82_800)
        XCTAssertEqual(KeepAwakeRules.duration(days: 0, hours: 0, minutes: 75), 3_540)
        XCTAssertEqual(KeepAwakeRules.duration(days: -1, hours: 0, minutes: 5), 300)
        XCTAssertNil(KeepAwakeRules.duration(days: 0, hours: -3, minutes: 0))
    }

    func testAnythingPastSevenDaysIsCappedAtSevenDays() {
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 0, minutes: 0), 604_800)
        XCTAssertEqual(KeepAwakeRules.duration(days: 7, hours: 23, minutes: 59), 604_800)
        XCTAssertEqual(KeepAwakeRules.duration(days: 9, hours: 0, minutes: 0), 604_800)
    }

    /// The daemon's own check (D4): the privileged side refuses rather than caps.
    func testTheHelperAcceptsOneMinuteToSevenDaysAndNothingElse() {
        XCTAssertTrue(KeepAwakeRules.accepts(duration: 60))
        XCTAssertTrue(KeepAwakeRules.accepts(duration: 604_800))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 59.9))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 604_800.5))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: 0))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: -60))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: .infinity))
        XCTAssertFalse(KeepAwakeRules.accepts(duration: .nan))
    }

    func testARememberedDurationSplitsBackIntoTheThreeSteppers() {
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 60), KeepAwakeRules.Parts(days: 0, hours: 1, minutes: 0))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 1_470), KeepAwakeRules.Parts(days: 1, hours: 0, minutes: 30))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 10_080), KeepAwakeRules.Parts(days: 7, hours: 0, minutes: 0))
    }

    func testARememberedDurationOutsideTheRangeComesBackInsideIt() {
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 0), KeepAwakeRules.Parts(days: 0, hours: 0, minutes: 1))
        XCTAssertEqual(KeepAwakeRules.parts(totalMinutes: 20_000), KeepAwakeRules.Parts(days: 7, hours: 0, minutes: 0))
    }

    func testBelowTwentyFivePercentOnBatteryIsBelowTheFloor() {
        XCTAssertTrue(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: true, percent: 24)))
        XCTAssertFalse(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: true, percent: 25)))
        XCTAssertFalse(KeepAwakeRules.isBelowFloor(KeepAwakePower(onBattery: false, percent: 5)))
    }
}
