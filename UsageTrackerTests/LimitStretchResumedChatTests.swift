import XCTest
@testable import Omelette

/// A chat resumed cold in a later window: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 5 (each stretch shows its cold-start cost, "the cache-write cost of the
/// turns that rebuilt the context in it"). Only the chat's first main-thread turn builds
/// its context, and the turns a load asks for reach back to the turn horizon for every
/// period, so the Session view and a past window find that turn where the Week view does,
/// and charge the same rebuild.
final class LimitStretchResumedChatTests: XCTestCase {
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

    /// The session open now began an hour ago; the week five days ago.
    private var sessionStart: Date { now.addingTimeInterval(-hour) }
    private var session: UsageBucket {
        Fixture.bucket(id: "five_hour", label: "Current session", percent: 10,
                       resetsAt: now.addingTimeInterval(4 * hour), kind: .session, windowLength: 5 * hour)
    }
    private var week: UsageBucket {
        Fixture.bucket(id: "seven_day", label: "All models", percent: 20,
                       resetsAt: now.addingTimeInterval(2 * day), kind: .weekly, windowLength: 7 * day)
    }
    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [session, week], at: now)
    }

    /// The chat's first turn, four days ago, built its context; it came back in this
    /// session after its cache had long expired.
    private var coldStart: TurnCost {
        Fixture.promptTurn(at: sessionStart.addingTimeInterval(10 * 60), chat: "chat-a", input: 3, cacheWrite1h: 60_000, output: 400)
    }

    /// Every turn the cost log holds.
    private var everything: TurnCostLog {
        TurnCostLog(turns: [
            Fixture.promptTurn(at: now.addingTimeInterval(-4 * day), chat: "chat-a", input: 3, cacheWrite1h: 20_000, output: 300),
            coldStart,
            Fixture.promptTurn(at: sessionStart.addingTimeInterval(20 * 60), chat: "chat-a", input: 3, cacheRead: 60_000, output: 200),
        ])
    }

    private var readings: [HistoryRecord] {
        Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(30 * 60), percent: 10, resetsAt: session.resetsAt),
        ]) + Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, windowLength: 7 * day, points: [
            (at: now.addingTimeInterval(-4 * day + 30 * 60), percent: 15, resetsAt: week.resetsAt),
            (at: sessionStart.addingTimeInterval(30 * 60), percent: 20, resetsAt: week.resetsAt),
        ])
    }

    /// What the cost log's actor hands a load for `span` (`turnCosts(from:to:)`).
    private func turns(in span: LimitWindow) -> TurnCostLog {
        TurnCostLog(turns: everything.turns.filter { $0.timestamp >= span.start && $0.timestamp <= span.end })
    }

    /// The stretches of `chat-a` a load of `kind`'s current window shows.
    private func stretches(kind: BucketKind, bucket: UsageBucket) throws -> [ChatStretch] {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claudeMax, kind: kind, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let span = LimitShareRules.turnSpan(request: request, now: now)
        let result = LimitShareRules.loadResult(
            request: request, kind: kind, isCurrent: true, bucket: bucket, serviceID: "claude",
            log: turns(in: span), records: readings, dailySpend: [], now: now
        )
        return try XCTUnwrap(result.stretches["chat-a"])
    }

    func testTheSessionViewChargesAResumedChatsColdStartAsTheWeekViewDoes() throws {
        let rebuild = LimitShareRules.rebuildCost(coldStart)
        XCTAssertGreaterThan(rebuild, 0)

        let inSession = try stretches(kind: .session, bucket: session)
        let inWeek = try stretches(kind: .weekly, bucket: week)

        XCTAssertEqual(inSession.count, 1)
        XCTAssertEqual(inSession.first?.coldStartCost ?? -1, rebuild, accuracy: 1e-9,
                       "the chat's context was built four days ago; this turn rebuilt it")
        let resumed = try XCTUnwrap(inWeek.first { $0.opening == .coldStart })
        XCTAssertEqual(resumed.coldStartCost, rebuild, accuracy: 1e-9)
        XCTAssertEqual(inWeek.first?.coldStartCost ?? -1, 0, accuracy: 1e-9, "the first turn built it")
    }

    /// A past session shows the rebuild as well: its load reaches back past its own start.
    func testAPastSessionChargesTheColdStartToo() throws {
        let past = LimitPastWindow(
            start: sessionStart.addingTimeInterval(-5 * hour), end: sessionStart, resets: sessionStart...sessionStart
        )
        let earlier = Fixture.promptTurn(
            at: past.start.addingTimeInterval(10 * 60), chat: "chat-b", input: 3, cacheWrite1h: 40_000, output: 100
        )
        let log = TurnCostLog(turns: [
            Fixture.promptTurn(at: now.addingTimeInterval(-2 * day), chat: "chat-b", input: 3, cacheWrite1h: 20_000),
            earlier,
        ])
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: past.start.addingTimeInterval(30 * 60), percent: 8, resetsAt: sessionStart),
        ])
        let request = LimitShareRules.request(for: past, bucketID: "five_hour")
        let span = LimitShareRules.turnSpan(request: request, now: now)

        let result = LimitShareRules.loadResult(
            request: request, kind: .session, isCurrent: false, bucket: session, serviceID: "claude",
            log: TurnCostLog(turns: log.turns.filter { $0.timestamp >= span.start && $0.timestamp <= span.end }),
            records: records, dailySpend: [], now: now
        )

        XCTAssertEqual(
            result.stretches["chat-b"]?.first?.coldStartCost ?? -1, LimitShareRules.rebuildCost(earlier), accuracy: 1e-9
        )
    }

    func testEveryLoadAsksForTheTurnsBackToTheHorizon() throws {
        let horizon = now.addingTimeInterval(-31 * day)
        let current = try XCTUnwrap(LimitShareRules.request(
            for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: current, now: now), LimitWindow(start: horizon, end: now),
            "the session open now"
        )

        let past = LimitPastWindow(
            start: now.addingTimeInterval(-3 * day), end: now.addingTimeInterval(-3 * day + 5 * hour), resets: nil
        )
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: LimitShareRules.request(for: past, bucketID: "five_hour"), now: now),
            LimitWindow(start: horizon, end: past.end),
            "a past session, up to its end"
        )

        let lastWeek = LimitShareRequest(
            mode: .payAsYouGo(weeklyBudget: 100),
            period: LimitWindow(start: now.addingTimeInterval(-14 * day), end: now.addingTimeInterval(-7 * day)),
            bucketID: nil, livePercent: nil
        )
        XCTAssertEqual(
            LimitShareRules.turnSpan(request: lastWeek, now: now),
            LimitWindow(start: horizon, end: now.addingTimeInterval(-7 * day))
        )

        // A calendar month of 31 days that began more than 31 days ago: from its start.
        let monthStart = now.addingTimeInterval(-31 * day - hour)
        let month = LimitShareRequest(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 0),
            period: LimitWindow(start: monthStart, end: now), bucketID: nil, livePercent: nil
        )
        XCTAssertEqual(LimitShareRules.turnSpan(request: month, now: now), LimitWindow(start: monthStart, end: now))
    }
}
