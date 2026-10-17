import XCTest
@testable import Omelette

/// The shares the app works out for `status.json` from a provider's turns and readings:
/// spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data. The
/// sources are closures here. The app hands in its cost log's actor and `HistoryStore`'s
/// (`StatusCosts.shareSources`).
final class PublishedSharesTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let minute: TimeInterval = 60

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// What the sources were asked for.
    private actor Calls {
        private(set) var turnRanges: [LimitWindow] = []
        private(set) var readingStarts: [Date] = []

        func record(turnsFrom start: Date, to end: Date) {
            turnRanges.append(LimitWindow(start: start, end: end))
        }

        func record(readingsSince start: Date) {
            readingStarts.append(start)
        }
    }

    private func sources(
        log: TurnCostLog, readings: [HistoryRecord], calls: Calls
    ) -> PublishedShareRules.Sources {
        PublishedShareRules.Sources(
            turns: { start, end in
                await calls.record(turnsFrom: start, to: end)
                return log
            },
            readings: { since in
                await calls.record(readingsSince: since)
                return readings
            }
        )
    }

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    /// What the history holds:
    /// - the session's first half hour at 5 %;
    /// - the week at 30 % after its first hour, and at 35 % two days ago.
    ///
    /// The live 9 % and 40 % close both windows. These are the readings of
    /// `PublishedShareFieldsTests`, reached through the account's own windows.
    private var readings: [HistoryRecord] {
        Fixture.readings(bucketID: "five_hour", points: [
            (at: now.addingTimeInterval(-4 * hour + 20 * minute), percent: 5),
        ]) + Fixture.readings(bucketID: "seven_day", points: [
            (at: now.addingTimeInterval(-5 * day + 60 * minute), percent: 30),
            (at: now.addingTimeInterval(-2 * day + 20 * minute), percent: 35),
        ])
    }

    private var turnLog: TurnCostLog {
        TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-c", cost: 3),
            Fixture.turnCost(at: now.addingTimeInterval(-235 * minute), chat: "chat-a", cost: 2),
            Fixture.turnCost(at: now.addingTimeInterval(-230 * minute), chat: "chat-b", cost: 1),
            Fixture.turnCost(at: now.addingTimeInterval(-10 * minute), chat: "chat-b", cost: 1),
        ])
    }

    func testASubscriptionsChatsGetTheirSessionAndWeekSharesTaggedWithTheirWindows() async {
        let shares = await PublishedShareRules.shares(
            for: claudeMax, weeklyBudgetUSD: 0, now: now, calendar: utc,
            sources: sources(log: turnLog, readings: readings, calls: Calls())
        )

        XCTAssertEqual(shares, PublishedShares(
            windows: [
                PublishedShareWindow(field: .session, resetsAt: now.addingTimeInterval(hour)),
                PublishedShareWindow(field: .week, resetsAt: now.addingTimeInterval(2 * day)),
            ],
            chats: [
                "chat-a": ChatShareFields(sessionShare: 3.3, weekShare: 0),
                "chat-b": ChatShareFields(sessionShare: 5.7, weekShare: 5),
                "chat-c": ChatShareFields(weekShare: 5),
            ]
        ))
    }

    func testTheTurnsAndReadingsAreAskedForOnceOverTheWidestWindow() async {
        let calls = Calls()

        _ = await PublishedShareRules.shares(
            for: claudeMax, weeklyBudgetUSD: 0, now: now, calendar: utc,
            sources: sources(log: turnLog, readings: readings, calls: calls)
        )

        let turnRanges = await calls.turnRanges
        let readingStarts = await calls.readingStarts
        XCTAssertEqual(turnRanges, [LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)])
        XCTAssertEqual(readingStarts, [now.addingTimeInterval(-5 * day)])
    }

    func testPayAsYouGoAsksForNoReadings() async {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400)
        let calls = Calls()
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-8 * day), chat: "chat-f", cost: 100),
            Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-d", cost: 25),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-e", cost: 12.34),
        ])

        let shares = await PublishedShareRules.shares(
            for: api, weeklyBudgetUSD: 500, now: now, calendar: utc,
            sources: sources(log: log, readings: readings, calls: calls)
        )

        XCTAssertEqual(shares, PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil, denominatorUSD: 500)],
            chats: [
                "chat-d": ChatShareFields(budgetShare: 5),
                "chat-e": ChatShareFields(budgetShare: 2.5),
            ]
        ), "a chat from before the seven days has no share of them")
        let turnRanges = await calls.turnRanges
        let readingStarts = await calls.readingStarts
        XCTAssertEqual(turnRanges, [LimitWindow(start: now.addingTimeInterval(-7 * day), end: now)])
        XCTAssertEqual(readingStarts, [])
    }

    func testAProviderWithoutSourcesGetsNoShares() async {
        let grok = Fixture.snapshot(id: "grok", plan: nil, buckets: [
            Fixture.bucket(id: "grok_weekly", label: "Weekly", percent: 20,
                           resetsAt: now.addingTimeInterval(day), kind: .weekly),
        ])

        let shares = await PublishedShareRules.shares(
            services: [claudeMax, grok], weeklyBudgetUSD: 0, now: now, calendar: utc,
            sources: ["claude": sources(log: turnLog, readings: readings, calls: Calls())]
        )

        XCTAssertEqual(Set(shares.keys), ["claude"])
        XCTAssertEqual(shares["claude"]?.chats["chat-b"], ChatShareFields(sessionShare: 5.7, weekShare: 5))
    }

    func testAProviderWithNothingToPublishIsLeftOutAndItsLogIsNotRead() async {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400)
        let calls = Calls()

        let shares = await PublishedShareRules.shares(
            services: [api], weeklyBudgetUSD: 0, now: now, calendar: utc,
            sources: ["claude": sources(log: turnLog, readings: readings, calls: calls)]
        )

        XCTAssertTrue(shares.isEmpty)
        let turnRanges = await calls.turnRanges
        XCTAssertEqual(turnRanges, [])
    }
}
