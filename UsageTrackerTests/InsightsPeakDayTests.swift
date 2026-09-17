import XCTest
@testable import Omelette

/// Insights' "Biggest day" card. The daily rows behind it now reach back a year, for
/// the Activity cards' sake; this card keeps the ninety days it has always had.
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md § Retention.
final class InsightsPeakDayTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func daily(_ dayOffset: Int, cost: Double) -> CLIDailySummary {
        let cal = utc
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
        return CLIDailySummary(
            day: day, totalCost: cost, totalTokens: 0, tokens: .zero,
            turns: cost > 0 ? 1 : 0, byFamily: [:]
        )
    }

    /// The card carries no range in its title, so a peak from last autumn would be a
    /// silent change of meaning rather than more information.
    func testTheBiggestDayIgnoresAnythingOlderThanNinetyDays() {
        let peak = InsightsView.peakDay(
            in: [daily(-200, cost: 99), daily(-5, cost: 3)], now: now, calendar: utc
        )
        XCTAssertEqual(peak?.cost ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(peak?.day, utc.date(byAdding: .day, value: -5, to: utc.startOfDay(for: now)))
    }

    /// The same boundary the Activity 90-day card uses: the ninetieth day back counts.
    func testTheNinetiethDayBackStillCounts() {
        let peak = InsightsView.peakDay(in: [daily(-89, cost: 7)], now: now, calendar: utc)
        XCTAssertEqual(peak?.cost ?? 0, 7, accuracy: 1e-9)
        XCTAssertEqual(peak?.day, utc.date(byAdding: .day, value: -89, to: utc.startOfDay(for: now)))
    }

    func testAQuarterWithoutSpendHasNoBiggestDay() {
        XCTAssertNil(InsightsView.peakDay(in: [daily(-5, cost: 0)], now: now, calendar: utc))
        XCTAssertNil(InsightsView.peakDay(in: [], now: now, calendar: utc))
        XCTAssertNil(InsightsView.peakDay(in: [daily(-200, cost: 99)], now: now, calendar: utc))
    }
}
