import XCTest
@testable import Omelette

/// How the period picker names its periods: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 1 ("This week",
/// "Week of 2 Oct", …; sessions as "Today 10:40–15:40") and § Accounts without percent
/// windows, Periods ("the last 7 days, then 7–14 days ago, …"). Days follow the chat
/// list's ladder: today, a weekday within the week, a date beyond.
final class LimitsPeriodCopyTests: XCTestCase {
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    /// 2026-09-06 20:00 UTC, a Sunday evening.
    private var evening: Date { at("2026-09-06T20:00:00Z") }

    private func name(_ period: LimitsPeriod, mode: LimitMode = .subscription, span: LimitsSpan = .week) -> String {
        LimitsCopy.periodName(period, mode: mode, span: span, now: evening, calendar: calendar, locale: locale)
    }

    /// A past window from `start` to `end`, as its readings named it.
    private func past(_ start: String, _ end: String) -> LimitsPeriod {
        .past(LimitPastWindow(start: at(start), end: at(end), resets: at(end)...at(end)))
    }

    func testTheCurrentPeriodIsNamedForItsWindowOrSpend() {
        XCTAssertEqual(name(.current), "This week")
        XCTAssertEqual(name(.current, span: .session), "This session")
        XCTAssertEqual(name(.current, span: .month), "This month", "Codex Free's 30 days")
        XCTAssertEqual(name(.current, mode: .payAsYouGo(weeklyBudget: nil)), "Last 7 days")
        XCTAssertEqual(name(.current, mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)), "This month")
    }

    func testAPastWeekIsTheWeekOfItsFirstDay() {
        XCTAssertEqual(name(past("2026-08-27T10:00:00Z", "2026-09-03T10:00:00Z")), "Week of 27 Aug")
        XCTAssertEqual(name(past("2026-08-02T10:00:00Z", "2026-09-01T10:00:00Z"), span: .month), "Month of 2 Aug")
    }

    func testAPastSessionIsItsDayAndHours() {
        XCTAssertEqual(name(past("2026-09-06T10:40:00Z", "2026-09-06T15:40:00Z"), span: .session), "Today 10:40–15:40")
        XCTAssertEqual(name(past("2026-09-05T10:40:00Z", "2026-09-05T15:40:00Z"), span: .session), "Sat 10:40–15:40")
        XCTAssertEqual(name(past("2026-08-27T10:40:00Z", "2026-08-27T15:40:00Z"), span: .session), "27 Aug 10:40–15:40")
    }

    func testASessionAcrossMidnightNamesBothDays() {
        let end = at("2026-09-05T03:30:00Z")
        XCTAssertEqual(
            name(past("2026-09-04T22:30:00Z", "2026-09-05T03:30:00Z"), span: .session),
            "Fri 22:30 – Sat \(HistoryCopy.time(end, calendar: calendar, locale: locale))"
        )
    }

    func testAnEarlierWeekIsCountedInDays() {
        XCTAssertEqual(name(.weeksAgo(1), mode: .payAsYouGo(weeklyBudget: 500)), "7–14 days ago")
        XCTAssertEqual(name(.weeksAgo(3), mode: .payAsYouGo(weeklyBudget: nil)), "21–28 days ago")
    }

    func testNothingSpentNamesThePickedWeek() {
        XCTAssertEqual(
            LimitsCopy.message(for: .noSpend, providerName: "Claude", period: .current),
            "Nothing spent in the last 7 days."
        )
        XCTAssertEqual(
            LimitsCopy.message(for: .noSpend, providerName: "Claude", period: .weeksAgo(2)),
            "Nothing spent 14–21 days ago."
        )
        XCTAssertEqual(LimitsCopy.message(for: .loading, providerName: "Claude", period: .weeksAgo(1)), "Loading…")
    }

    func testThePickerIsCalledPeriodAndOneMomentIsNotARange() {
        XCTAssertEqual(LimitsCopy.periodPickerLabel, "Period")
        let moment = at("2026-09-06T14:20:00Z")
        XCTAssertEqual(
            LimitsCopy.timeRange(from: moment, to: moment, now: evening, calendar: calendar, locale: locale),
            "Today 14:20"
        )
    }
}
