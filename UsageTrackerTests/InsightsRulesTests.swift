import XCTest
@testable import Omelette

/// The Insights tab's rules (liquid-glass spec § Screens, "Insights"; § Decisions,
/// "What limit hit counts"). The clock is 2026-09-06 12:00 UTC, a Sunday, and every
/// calendar is pinned.
final class InsightsRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-04-01 00:30 CEST: three days after Berlin's clocks went forward (Sunday
    /// 29 March).
    private let berlinNow = Date(timeIntervalSince1970: 1_774_996_200)

    private var berlin: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Noon UTC, `offset` days from `now`.
    private func noon(_ offset: Int) -> Date {
        now.addingTimeInterval(Double(offset) * 86_400)
    }

    /// The start of the UTC day `offset` days from `now`: what a `CLIDailySummary.day` holds.
    private func day(_ offset: Int) -> Date {
        utc.date(byAdding: .day, value: offset, to: utc.startOfDay(for: now))!
    }

    /// The start of the Berlin day `offset` days from `berlinNow`.
    private func berlinDay(_ offset: Int) -> Date {
        berlin.date(byAdding: .day, value: offset, to: berlin.startOfDay(for: berlinNow))!
    }

    private func daily(_ day: Date, cost: Double) -> CLIDailySummary {
        CLIDailySummary(
            day: day, totalCost: cost, totalTokens: 0, tokens: .zero,
            turns: cost > 0 ? 1 : 0, byFamily: [:]
        )
    }

    private func model(
        _ name: String, _ cost: Double
    ) -> (model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown) {
        (model: name, cost: cost, tokens: 1, breakdown: .zero)
    }

    private func project(_ name: String, cost: Double, turns: Int = 1) -> ProjectSummary {
        ProjectSummary(
            slug: "slug-" + name, displayName: name, totalCost: cost,
            totalTokens: 0, turns: turns, lastActivity: now
        )
    }

    private func breakdown(
        daily: [CLIDailySummary] = [],
        byModelToday: [(model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown)] = []
    ) -> CLIBreakdown {
        CLIBreakdown(
            todayCost: 0, todayTokens: 0, todayTokenBreakdown: .zero, todayTurns: 0,
            weekCost: 0, monthCost: 0, byModelToday: byModelToday, daily: daily,
            projectsWeek: [], projectsMonth: [], updatedAt: now
        )
    }

    // MARK: - Days at limit

    func testDaysAtLimitCoversTodayAndTheSixDaysBefore() {
        XCTAssertEqual(InsightsRules.daysAtLimitSpan, 7)
        let history = Fixture.quotaHistory(service: "claude", points: [
            (noon(-7), ["five_hour": 100]),
            (noon(-6), ["five_hour": 96]),
            (noon(-2), ["five_hour": 94.9, "seven_day": 60]),
            (noon(0), ["five_hour": 95])
        ])

        let days = InsightsRules.daysAtLimit(
            records: history, bucketIDs: ["five_hour", "seven_day"], now: now, calendar: utc
        )

        XCTAssertEqual(days, QuotaDaysAtCapacity(atCapacity: 2, observed: 3, span: 7))
    }

    /// Spec § Screens: the figure is on every provider's page, a quota-only one included.
    func testAQuotaOnlyProviderIsCountedTheSameWay() {
        let history = Fixture.quotaHistory(service: "antigravity", points: [
            (noon(-1), ["gemini_pro": 100]),
            (noon(-4), ["gemini_pro": 12])
        ])

        let days = InsightsRules.daysAtLimit(
            records: history, bucketIDs: ["gemini_pro"], now: now, calendar: utc
        )

        XCTAssertEqual(days, QuotaDaysAtCapacity(atCapacity: 1, observed: 2, span: 7))
    }

    /// Review F1: a quota-only provider whose history has not moved still gets a new pass
    /// after midnight, because "Days at limit" belongs to the new day.
    func testANewLocalDayIsANewPass() {
        func key(_ at: Date) -> InsightsCacheKey {
            InsightsRules.cacheKey(
                service: "antigravity", cliUpdatedAt: .distantPast, historyCount: 12,
                lastHistoryAt: noon(-1), quotaBucketIDs: ["gemini_pro"], now: at, calendar: utc
            )
        }
        let lateSunday = day(1).addingTimeInterval(-60)  // 23:59 on Sunday 6 September
        let earlyMonday = day(1).addingTimeInterval(60)  // 00:01 on Monday 7 September

        XCTAssertNotEqual(key(lateSunday), key(earlyMonday))
        XCTAssertEqual(key(now), key(lateSunday))
        XCTAssertEqual(key(earlyMonday).day, day(1))
    }

    // MARK: - Summary

    func testACostProvidersSummaryLeavesTheQuotaPassOut() {
        let history = Fixture.quotaHistory(service: "claude", points: [(noon(-1), ["five_hour": 99])])
        let cli = breakdown(daily: [daily(day(-3), cost: 12)], byModelToday: [model("Opus 5", 7)])

        let summary = InsightsRules.summary(
            cli: cli, history: history, coreBucketIDs: ["five_hour"], hasCostLog: true,
            now: now, calendar: utc
        )

        XCTAssertEqual(summary.quota, .empty)
        XCTAssertEqual(summary.daysAtLimit, QuotaDaysAtCapacity(atCapacity: 1, observed: 1, span: 7))
        XCTAssertEqual(summary.biggestDay, InsightsDayCost(day: day(-3), cost: 12))
        XCTAssertEqual(summary.mostUsedModelToday, InsightsModelCost(model: "Opus 5", cost: 7))
    }

    func testAQuotaOnlyProvidersSummaryCarriesItsQuotaInsights() {
        let history = Fixture.quotaHistory(service: "antigravity", points: [
            (noon(-2), ["gemini_pro": 40]),
            (noon(0), ["gemini_pro": 96])
        ])

        let summary = InsightsRules.summary(
            cli: nil, history: history, coreBucketIDs: ["gemini_pro"], hasCostLog: false,
            now: now, calendar: utc
        )

        XCTAssertEqual(
            summary.quota,
            QuotaAnalytics.insights(records: history, bucketIDs: ["gemini_pro"], calendar: utc, now: now)
        )
        XCTAssertEqual(summary.quota.todayPeak, 96)
        XCTAssertEqual(summary.daysAtLimit, QuotaDaysAtCapacity(atCapacity: 1, observed: 2, span: 7))
        XCTAssertNil(summary.biggestDay)
        XCTAssertNil(summary.mostUsedModelToday)
        XCTAssertEqual(summary.dailyAverage, InsightsDailyAverage(average: nil, activeDays: 0))
    }

    func testAWindowIsNamedByTheLiveSnapshotOrFromItsID() {
        let buckets = [QuotaBucketInfo(id: "gemini_pro", label: "Gemini Pro", isCore: true, isLive: true)]

        XCTAssertEqual(InsightsRules.windowLabel(for: "gemini_pro", in: buckets), "Gemini Pro")
        XCTAssertEqual(InsightsRules.windowLabel(for: "seven_day_opus", in: buckets), "Seven Day Opus")
    }
}
