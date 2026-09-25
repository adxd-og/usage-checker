import XCTest
@testable import Omelette

/// Independent verification of `QuotaAnalytics.daysAtCapacity(records:bucketIDs:lastDays:now:calendar:)`
/// against the liquid-glass spec's "Days at limit, 7 days" (§ Screens, "Insights"; § Decisions,
/// "What limit hit counts") and the P6 plan's Task 5. Written from the spec and the diff, not
/// from the executor's `QuotaAnalyticsDaysAtCapacityTests.swift`.
final class QuotaAnalyticsDaysAtCapacityVerificationTests: XCTestCase {
    private func records(_ points: [(at: Date, percents: [String: Double])]) -> [HistoryRecord] {
        Fixture.quotaHistory(points: points)
    }

    // MARK: - DST: Europe/Berlin's fall-back (2026-10-25, clocks go back at 03:00 CEST)

    /// The brief's explicit check: the 7-day window must still resolve to seven distinct
    /// LOCAL calendar days across a real (not fixed-offset) DST transition, including the
    /// 25-hour fall-back day itself (2026-10-25: Berlin's clocks go back at 03:00 CEST).
    /// `Calendar`'s `.day` arithmetic and `startOfDay(for:)` are DST-aware by construction
    /// given a real named zone; this exercises that with `TimeZone(identifier:
    /// "Europe/Berlin")`, not a synthetic fixed-offset calendar as the executor's DST test
    /// used (`calendar(secondsFromGMT: 3 * 3600)`). Every timestamp is a fixed epoch
    /// (computed independently, `zoneinfo`/Python, not this file's own `Calendar` calls)
    /// of local noon on each of the seven days Oct 22...Oct 28 2026.
    func testDaysAtCapacityAcrossBerlinsFallBackStillCountsSevenDistinctLocalDays() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        berlin.locale = Locale(identifier: "en_US_POSIX")

        // now: 2026-10-28 12:00 Berlin time (CET, after the fall-back).
        let now = Date(timeIntervalSince1970: 1_793_185_200)
        let noons: [Date] = [
            Date(timeIntervalSince1970: 1_792_663_200),  // Oct 22 12:00 Berlin
            Date(timeIntervalSince1970: 1_792_749_600),  // Oct 23 12:00 Berlin
            Date(timeIntervalSince1970: 1_792_836_000),  // Oct 24 12:00 Berlin
            Date(timeIntervalSince1970: 1_792_926_000),  // Oct 25 12:00 Berlin (the 25-hour day)
            Date(timeIntervalSince1970: 1_793_012_400),  // Oct 26 12:00 Berlin
            Date(timeIntervalSince1970: 1_793_098_800),  // Oct 27 12:00 Berlin
            Date(timeIntervalSince1970: 1_793_185_200)   // Oct 28 12:00 Berlin (= now)
        ]
        let history = records(noons.enumerated().map { index, date in
            (date, ["session": index == 3 ? 97.0 : 10.0])  // Oct 25 is the one day at capacity
        })

        let result = QuotaAnalytics.daysAtCapacity(
            records: history, bucketIDs: ["session"], lastDays: 7, now: now, calendar: berlin
        )

        XCTAssertEqual(result, QuotaDaysAtCapacity(atCapacity: 1, observed: 7, span: 7))
    }

    /// A reading placed in the repeated local hour (02:00-03:00 happens twice on the
    /// fall-back night, once as CEST and once as CET) must still land on a single
    /// calendar day, not be double-counted or dropped. Both epochs below are the two
    /// real UTC instants of "02:30 local" that night, computed independently of this
    /// file's own `Calendar`.
    func testAReadingInTheRepeatedFallBackHourStillCountsAsOneDay() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        berlin.locale = Locale(identifier: "en_US_POSIX")

        let firstOccurrence = Date(timeIntervalSince1970: 1_792_888_200)   // 02:30 CEST
        let secondOccurrence = Date(timeIntervalSince1970: 1_792_891_800)  // 02:30 CET, one hour later
        let now = Date(timeIntervalSince1970: 1_792_926_000)               // Oct 25 12:00 Berlin

        let history = records([(firstOccurrence, ["session": 96]), (secondOccurrence, ["session": 50])])

        let result = QuotaAnalytics.daysAtCapacity(
            records: history, bucketIDs: ["session"], lastDays: 7, now: now, calendar: berlin
        )

        // Both readings are 25 October, one calendar day: one day observed, and its
        // peak (96) is the higher of the two, so it counts at capacity.
        XCTAssertEqual(result, QuotaDaysAtCapacity(atCapacity: 1, observed: 1, span: 7))
    }

    // MARK: - Boundary: the first included day

    /// The span is `[today - (lastDays - 1), today]` inclusive, so a record at the exact
    /// start of the first included day counts, and a record one second earlier (the last
    /// instant of the excluded eighth day) does not.
    func testARecordExactlyAtTheStartOfTheFirstIncludedDayCounts() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_US_POSIX")

        let now = Date(timeIntervalSince1970: 1_788_696_000)  // 2026-09-06 12:00 UTC
        let today = utc.startOfDay(for: now)
        let firstIncludedDayStart = utc.date(byAdding: .day, value: -6, to: today)!

        let onBoundary = records([(firstIncludedDayStart, ["session": 100])])
        let oneSecondBefore = records([(firstIncludedDayStart.addingTimeInterval(-1), ["session": 100])])

        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: onBoundary, bucketIDs: ["session"], lastDays: 7, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 1, observed: 1, span: 7)
        )
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: oneSecondBefore, bucketIDs: ["session"], lastDays: 7, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)
        )
    }

    // MARK: - span reflects the requested lastDays, not the observed count

    func testSpanIsTheRequestedLastDaysEvenWhenFarFewerDaysAreObserved() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_788_696_000)

        let history = records([(now, ["session": 20])])

        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: 30, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 1, span: 30)
        )
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: 1, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 1, span: 1)
        )
    }

    /// `lastDays` of zero or less has no valid span to walk; the guard returns an empty
    /// result with `span` clamped to zero rather than echoing a negative number back.
    func testLastDaysZeroOrNegativeReturnsEmptyWithClampedSpan() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        utc.locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_788_696_000)
        let history = records([(now, ["session": 100])])

        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: 0, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 0)
        )
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: -5, now: now, calendar: utc
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 0)
        )
    }
}
