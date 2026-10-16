import XCTest
@testable import Omelette

/// Past windows found in a bucket's readings: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds ("A
/// past window: between two resets, the current window's start … counting as one; a
/// reset is a reading at least 5 points below the previous one"), within the 31-day
/// turn horizon. Ruling Q3 (`.omelette/ledger-limit-analytics.md`): a reset must hold,
/// meaning the next reading, when there is one, is also at least 5 points below the
/// pre-drop value. A lone dip is noise.
final class LimitSharePastWindowsTests: XCTestCase {
    /// The current window's start: 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func series(_ points: [(TimeInterval, Double)]) -> [LimitReading] {
        LimitShareRules.series(
            Fixture.readings(bucketID: "seven_day", points: points.map { (at: at($0.0), percent: $0.1) }),
            bucketID: "seven_day"
        )
    }

    /// Three weeks of a weekly bucket:
    /// - a reading from before the first reset this history holds;
    /// - the resets 14 and 7 days back, each seen a minute either side;
    /// - the current window's own reset, seen a minute after it happened.
    private var threeWeeks: [LimitReading] {
        series([
            (-20 * day, 40),
            (-14 * day - 60, 70), (-14 * day + 60, 0),
            (-13 * day, 20), (-8 * day, 60),
            (-7 * day - 60, 65), (-7 * day + 60, 1),
            (-6 * day, 30), (-1 * day, 50),
            (-60, 55), (60, 0), (hour, 4),
        ])
    }

    func testTheSeriesIsTheBucketsPercentsInTimeOrderClampedToAHundred() {
        let records = Fixture.readings(bucketID: "seven_day", points: [
            (at: at(120), percent: 104), (at: at(0), percent: 12),
        ]) + Fixture.readings(bucketID: "five_hour", points: [(at: at(60), percent: 30)])

        XCTAssertEqual(LimitShareRules.series(records, bucketID: "seven_day"), [
            LimitReading(time: at(0), percent: 12),
            LimitReading(time: at(120), percent: 100),
        ])
    }

    func testADropOfFivePointsIsAResetAndADropOfFourIsNoise() {
        let readings = series([(0, 30), (hour, 26), (2 * hour, 31), (3 * hour, 26), (4 * hour, 26)])
        XCTAssertEqual(
            LimitShareRules.resets(in: readings),
            [LimitReset(lastBefore: at(2 * hour), firstAfter: at(3 * hour))]
        )
    }

    func testALoneDipIsNoiseNotAReset() {
        // The API answered 0 once mid-window and 31 again a minute later.
        let readings = series([(0, 30), (hour, 31), (hour + 60, 0), (hour + 120, 31)])
        XCTAssertEqual(
            LimitShareRules.resets(in: readings), [],
            "the next reading is not 5 points below 31; the running maximum (Task 7) absorbs the dip"
        )
        XCTAssertEqual(
            LimitShareRules.pastWindows(series: readings, before: at(3 * hour), horizonStart: at(-31 * day)), [],
            "no reset, so no window"
        )
    }

    func testADropOnTheLastReadingIsAReset() {
        let readings = series([(0, 30), (hour, 31), (2 * hour, 2)])
        XCTAssertEqual(
            LimitShareRules.resets(in: readings),
            [LimitReset(lastBefore: at(hour), firstAfter: at(2 * hour))],
            "no reading after it says otherwise"
        )
    }

    func testPastWindowsRunFromResetToResetNewestFirst() {
        XCTAssertEqual(
            LimitShareRules.pastWindows(series: threeWeeks, before: start, horizonStart: at(-31 * day)),
            [
                LimitWindow(start: at(-7 * day - 60), end: start),
                LimitWindow(start: at(-14 * day - 60), end: at(-7 * day - 60)),
            ],
            "the newest ends where the current window starts; nothing before the first reset this history holds"
        )
    }

    func testAResetSeenJustBeforeTheCurrentStartIsTheCurrentWindowsOwn() {
        // The provider's clock and the poll's disagree by seconds: the drop lands 20 s early.
        let readings = series([
            (-7 * day - 60, 65), (-7 * day + 60, 1), (-1 * day, 50), (-60, 55), (-20, 0), (600, 2),
        ])
        XCTAssertEqual(
            LimitShareRules.pastWindows(series: readings, before: start, horizonStart: at(-31 * day)),
            [LimitWindow(start: at(-7 * day - 60), end: start)]
        )
    }

    func testAWindowThatBeganBeforeTheTurnHorizonIsLeftOut() {
        XCTAssertEqual(
            LimitShareRules.pastWindows(series: threeWeeks, before: start, horizonStart: at(-10 * day)),
            [LimitWindow(start: at(-7 * day - 60), end: start)]
        )
    }

    func testIdleTimeBetweenTwoSessionsIsNotAPastWindow() {
        let sessions = series([
            (-12 * hour, 9), (-12 * hour + 60, 0),
            (-10 * hour, 3), (-7 * hour, 12), (-7 * hour + 60, 0),
            (-5 * hour, 0), (-2 * hour, 0),
            (600, 1),
        ])
        XCTAssertEqual(
            LimitShareRules.pastWindows(series: sessions, before: start, horizonStart: at(-31 * day)),
            [LimitWindow(start: at(-12 * hour), end: at(-7 * hour))],
            "from the last session's end to this one's start the percent never left 0"
        )
    }
}
