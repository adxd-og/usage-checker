import XCTest
@testable import Omelette

/// A spend limit's month: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Accounts without percent windows, with ruling C7.
/// - Spend limit: "the server's used credits minus this Mac's spend in the month, when
///   positive".
/// - Periods: "calendar months, current month only".
/// - This Mac's month spend comes from the cost log's day totals, which survive the fold
///   past the 31-day turn horizon.
/// - The part of it the turns no longer itemise is one "Earlier this month" row, never
///   Outside.
final class LimitSpendMonthTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// Europe/Vilnius. Summer time ended on Sunday 25 October 2026, so October there is
    /// 31 days and an hour long.
    private let vilnius: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vilnius")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// $1,240 of a $2,000 monthly limit used, as the server counts it.
    private var team: ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62),
            weekCost: 300
        )
    }

    private func date(_ month: Int, _ dayOfMonth: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        vilnius.date(from: DateComponents(year: 2026, month: month, day: dayOfMonth, hour: hour, minute: minute))!
    }

    /// One row of the cost log's daily totals, keyed by the local day's start, as
    /// `CLIBreakdown.daily` holds it.
    private func dayTotal(_ month: Int, _ dayOfMonth: Int, cost: Double) -> CLIDailySummary {
        CLIDailySummary(
            day: date(month, dayOfMonth), totalCost: cost, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:]
        )
    }

    func testASpendLimitCountsThisMacsWholeMonthAndItsFoldedDaysAsEarlierThisMonth() throws {
        let now = date(10, 31, 23, 30)
        let request = try XCTUnwrap(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: vilnius)
        )
        XCTAssertEqual(request.period, LimitWindow(start: date(10, 1), end: now))
        XCTAssertEqual(
            now.timeIntervalSince(date(10, 1)), 31 * day + 1_800,
            "31 days and 30 minutes: the month reaches past the 31-day turn horizon"
        )

        // The aggregators keep turns for 31 days. The turn at 00:15 on 1 October has been
        // folded into its day's total; only the turn on the 20th is still a turn.
        let folded = date(10, 1, 0, 15)
        XCTAssertLessThan(folded, now.addingTimeInterval(-31 * day))
        let log = TurnCostLog(turns: [Fixture.turnCost(at: date(10, 20, 12), chat: "chat-a", cost: 1_000)])
        let daily = [
            dayTotal(9, 30, cost: 500),      // last month
            dayTotal(10, 1, cost: 100),      // the folded turn
            dayTotal(10, 20, cost: 1_000),
        ]

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: [], dailySpend: daily))
        XCTAssertEqual(share.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(share.chats[0].points, 50, accuracy: 1e-9)
        let earlier = try XCTUnwrap(share.earlier, "this Mac's spend from before the horizon is one row, not split by chat")
        XCTAssertEqual(earlier.cost, 100, accuracy: 1e-9)
        XCTAssertEqual(earlier.points, 5, accuracy: 1e-9)
        XCTAssertEqual(
            share.outside, 7, accuracy: 1e-9,
            "$1,240 the server counted minus this Mac's $1,100 in October, of $2,000; the folded $100 is never Outside"
        )
        XCTAssertEqual(share.percent, 62, accuracy: 1e-9)
        XCTAssertEqual(
            share.bins.map(\.delta).reduce(0, +) + share.unbinnedOutside + earlier.points, share.percent,
            accuracy: 1e-9
        )
    }

    func testAMonthTheTurnsStillCoverHasNoEarlierRow() throws {
        let now = date(10, 20, 12)
        let request = try XCTUnwrap(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: vilnius)
        )
        let log = TurnCostLog(turns: [Fixture.turnCost(at: date(10, 10, 9), chat: "chat-a", cost: 1_000)])
        let daily = [dayTotal(9, 30, cost: 500), dayTotal(10, 10, cost: 1_000)]

        XCTAssertEqual(
            LimitShareRules.localSpend(days: daily, in: request.period), 1_000, accuracy: 1e-9,
            "last month's $500 is not this month's"
        )
        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: [], dailySpend: daily))
        XCTAssertNil(share.earlier, "every dollar of the month is still a turn")
        XCTAssertEqual(share.outside, 12, accuracy: 1e-9)
        XCTAssertEqual(share.percent, 62, accuracy: 1e-9)
    }
}
