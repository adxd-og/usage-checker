import XCTest
@testable import Omelette

/// "Days at limit, 7 days" (liquid-glass spec § Screens, "Insights"; § Decisions, "What
/// limit hit counts"): of the last N local days, the ones whose peak reached
/// `QuotaAnalytics.capacityThreshold`, and how many were seen at all.
final class QuotaAnalyticsDaysAtCapacityTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private func calendar(secondsFromGMT: Int = 0) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Noon UTC, `offset` days from `now`.
    private func noon(_ offset: Int) -> Date {
        now.addingTimeInterval(Double(offset) * 86_400)
    }

    private func records(_ points: [(at: Date, percents: [String: Double])]) -> [HistoryRecord] {
        Fixture.quotaHistory(points: points)
    }

    func testOnlyTheLastSevenLocalDaysAreCounted() {
        let history = records([
            (noon(-7), ["session": 100]),
            (noon(-6), ["session": 96]),
            (noon(-2), ["session": 40]),
            (noon(0), ["session": 95])
        ])

        let days = QuotaAnalytics.daysAtCapacity(
            records: history, bucketIDs: ["session"], lastDays: 7, now: now, calendar: calendar()
        )

        // The eighth day back is outside; today counts, and so does its 95.
        XCTAssertEqual(days, QuotaDaysAtCapacity(atCapacity: 2, observed: 3, span: 7))
    }

    func testTheLimitIsReachedAtNinetyFivePercent() {
        let history = records([
            (noon(-1), ["session": 94.9]),
            (noon(-3), ["session": 95])
        ])

        let days = QuotaAnalytics.daysAtCapacity(
            records: history, bucketIDs: ["session"], lastDays: 7, now: now, calendar: calendar()
        )

        XCTAssertEqual(days.atCapacity, 1)
        XCTAssertEqual(days.observed, 2)
    }

    func testAnyWindowAskedAboutPutsItsDayAtTheLimitAndNoOtherDoes() {
        // The weekly window at its limit makes a day at the limit. A promotional pool
        // at 100% is not one of the windows asked about, so its day is not even seen.
        let history = records([
            (noon(-1), ["session": 20, "weekly": 97]),
            (noon(-2), ["promo": 100])
        ])

        let days = QuotaAnalytics.daysAtCapacity(
            records: history, bucketIDs: ["session", "weekly"], lastDays: 7, now: now, calendar: calendar()
        )

        XCTAssertEqual(days, QuotaDaysAtCapacity(atCapacity: 1, observed: 1, span: 7))
    }

    func testTheDaysAreTheCalendarsOwn() {
        // 2026-08-30 22:30 UTC is 31 August 01:30 at UTC+3: the first day of the span
        // there, and the day before the span in UTC.
        let history = records([(Date(timeIntervalSince1970: 1_788_129_000), ["session": 99])])

        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: 7, now: now, calendar: calendar()
            ).observed,
            0
        )
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: history, bucketIDs: ["session"], lastDays: 7, now: now,
                calendar: calendar(secondsFromGMT: 3 * 3600)
            ),
            QuotaDaysAtCapacity(atCapacity: 1, observed: 1, span: 7)
        )
    }

    func testNoReadingsOrNoWindowsCountNothing() {
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: [], bucketIDs: ["session"], lastDays: 7, now: now, calendar: calendar()
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)
        )
        XCTAssertEqual(
            QuotaAnalytics.daysAtCapacity(
                records: records([(noon(0), ["session": 100])]), bucketIDs: [], lastDays: 7,
                now: now, calendar: calendar()
            ),
            QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)
        )
    }
}
