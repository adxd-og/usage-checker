import XCTest
@testable import Omelette

/// What one load of the Limits tab computes: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, items 1 (the past
/// windows the picker lists), 2 (the change line on the current week), 3 (a worktree's
/// chats under its repository) and 5 (stretches), and § Design, Change signal ("previous
/// complete weeks still inside the 31-day turn horizon … each with at least 10 attributed
/// points"). `DashboardState` only fetches the turns, readings and links and publishes this.
final class LimitLoadResultTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Claude Max's week, 20 % full and resetting in two days: it began five days ago.
    private var weekly: UsageBucket {
        Fixture.bucket(id: "seven_day", label: "All models", percent: 20,
                       resetsAt: now.addingTimeInterval(2 * day), kind: .weekly)
    }

    /// When the `k`-th week before this one ended: 0 is the week that ended five days ago.
    private func weekEnd(_ k: Int) -> Date { now.addingTimeInterval(-5 * day - Double(k) * 7 * day) }

    /// One reading a day before each week ended, 20 %, naming that week's reset; this
    /// week's a day ago.
    private var records: [HistoryRecord] {
        var points: [(at: Date, percent: Double, resetsAt: Date)] = (0..<4).map { k in
            (at: weekEnd(k).addingTimeInterval(-day), percent: 20, resetsAt: weekEnd(k))
        }
        points.append((at: now.addingTimeInterval(-day), percent: 20, resetsAt: now.addingTimeInterval(2 * day)))
        return Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, points: points)
    }

    /// Each past week $1,200 for its 20 points ($60 a point); this week $800 ($40 a point).
    /// Each turn runs in the half hour its week's reading closes.
    private var log: TurnCostLog {
        var turns = (0..<4).map { k in
            Fixture.turnCost(at: weekEnd(k).addingTimeInterval(-day - 600), chat: "week-\(k)", cost: 1_200)
        }
        turns.append(Fixture.turnCost(at: now.addingTimeInterval(-day - 600), chat: "this-week", cost: 800))
        return TurnCostLog(turns: turns.sorted { $0.timestamp < $1.timestamp })
    }

    private func week(_ k: Int) -> LimitWindow {
        LimitWindow(start: weekEnd(k).addingTimeInterval(-7 * day), end: weekEnd(k))
    }

    func testTheCurrentWeekComesWithItsPastWeeksItsStretchesAndTheChangeSignal() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: Fixture.snapshot(id: "claude", buckets: [weekly]), kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let result = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: weekly, serviceID: "claude",
            log: log, records: records, dailySpend: [], now: now
        )
        XCTAssertEqual(
            result.pastWindows.map(\.window), [week(0), week(1), week(2)],
            "the fourth began 33 days ago, before the turns' horizon"
        )
        XCTAssertEqual(result.pastWindows.first?.resets, weekEnd(0)...weekEnd(0))
        XCTAssertEqual(result.share?.percent ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(result.stretches["this-week"]?.count, 1)
        let change = try XCTUnwrap(result.change)
        XCTAssertEqual(change.percentLess, 33, "$40 a point against $60")
        XCTAssertEqual(change.usualWeeks, 3)
    }

    func testAPastWeekLoadsWithoutTheChangeSignal() {
        let past = LimitPastWindow(start: week(0).start, end: week(0).end, resets: weekEnd(0)...weekEnd(0))
        let result = LimitShareRules.loadResult(
            request: LimitShareRules.request(for: past, bucketID: "seven_day"),
            kind: .weekly, isCurrent: false, bucket: weekly, serviceID: "claude",
            log: log, records: records, dailySpend: [], now: now
        )
        XCTAssertEqual(result.share?.percent ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(result.share?.price?.dollars ?? -1, 60, accuracy: 1e-9)
        XCTAssertNil(result.change, "the signal is about the week open now")
        XCTAssertEqual(result.pastWindows.count, 3)
    }

    func testWithNoSessionOpenThePastSessionsAreStillListed() {
        let idle = Fixture.bucket(id: "five_hour", label: "Current session", percent: 0, kind: .session)
        let sessions = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: now.addingTimeInterval(-3 * hour), percent: 12, resetsAt: now.addingTimeInterval(-hour)),
        ])
        let result = LimitShareRules.loadResult(
            request: nil, kind: .session, isCurrent: true, bucket: idle, serviceID: "claude",
            log: .empty, records: sessions, dailySpend: [], now: now
        )
        XCTAssertNil(result.share)
        XCTAssertEqual(
            result.pastWindows.map(\.window),
            [LimitWindow(start: now.addingTimeInterval(-6 * hour), end: now.addingTimeInterval(-hour))]
        )
    }

    func testOnlyTheCurrentWeekAsksForTurnsBackToTheHorizon() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: Fixture.snapshot(id: "claude", buckets: [weekly]), kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: request, kind: .weekly, isCurrent: true, windowLength: 7 * day, now: now),
            LimitWindow(start: now.addingTimeInterval(-31 * day), end: now),
            "the usual weeks the change signal prices"
        )
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: request, kind: .weekly, isCurrent: false, windowLength: 7 * day, now: now),
            request.period
        )
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: request, kind: .session, isCurrent: true, windowLength: 5 * hour, now: now),
            request.period
        )
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: request, kind: .weekly, isCurrent: true, windowLength: 30 * day, now: now),
            request.period, "a 30-day window has no change signal"
        )
        XCTAssertFalse(LimitShareRules.pricesChange(
            mode: .payAsYouGo(weeklyBudget: nil), kind: .weekly, isCurrent: true, windowLength: 7 * day
        ))
    }

    func testPayAsYouGoHasNoPastWindowsButItsChatsHaveStretches() {
        let period = LimitWindow(start: now.addingTimeInterval(-7 * day), end: now)
        let result = LimitShareRules.loadResult(
            request: LimitShareRequest(mode: .payAsYouGo(weeklyBudget: nil), period: period, bucketID: nil, livePercent: nil),
            kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 12)]),
            records: [], dailySpend: [], now: now
        )
        XCTAssertEqual(result.pastWindows, [])
        XCTAssertNil(result.change)
        XCTAssertEqual(result.share?.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(result.stretches["chat-a"]?.count, 1)
    }

    func testAWorktreesChatsCountUnderItsRepository() {
        let worktree = "-Users-tester-Desktop-usage-tracker-wt-tab"
        let main = "-Users-tester-Desktop-Usage-tracker"
        let period = LimitWindow(start: now.addingTimeInterval(-7 * day), end: now)
        let result = LimitShareRules.loadResult(
            request: LimitShareRequest(mode: .payAsYouGo(weeklyBudget: nil), period: period, bucketID: nil, livePercent: nil),
            kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-a", project: worktree, cost: 30),
                Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-b", project: main, cost: 10),
            ]),
            records: [], dailySpend: [], projectFolds: [worktree: main], now: now
        )
        XCTAssertEqual(result.share?.projects.map(\.id), [main])
        XCTAssertEqual(result.share?.chats.map(\.projectSlug), [main, main])
    }
}
