import XCTest
@testable import Omelette

/// The release-review fix round, checked from the specs
/// (`docs/superpowers/specs/2026-10-16-limit-analytics.md`: § Design Window bounds and
/// Totals, § The tab items 1 and 5, § Published data, § Accounts without percent windows)
/// and not from the implementer's tests: the current window's readings, the turns a load
/// reads, the published-share gate and the period picker, at their edges.
final class ReleaseReviewFixesVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let minute: TimeInterval = 60
    private let drift = LimitShareRules.resetDrift

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    // MARK: - The current window leaves out the window before's late readings

    private func session(percent: Double, resetting reset: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: percent,
                           resetsAt: reset, kind: .session, windowLength: 5 * hour),
        ], at: now)
    }

    func testAReadingThatReportsAResetAtOrBeforeTheDriftBoundaryIsTheWindowBefores() {
        let start = now.addingTimeInterval(-hour)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: start.addingTimeInterval(30), percent: 4, resetsAt: start.addingTimeInterval(drift - 1)),
            (at: start.addingTimeInterval(60), percent: 5, resetsAt: start.addingTimeInterval(drift)),
            (at: start.addingTimeInterval(90), percent: 6, resetsAt: start.addingTimeInterval(drift + 1)),
            (at: start.addingTimeInterval(120), percent: 7, resetsAt: start.addingTimeInterval(5 * hour)),
        ])

        let series = LimitShareRules.series(records, bucketID: "five_hour", openSince: start)

        XCTAssertEqual(series.map(\.percent), [6, 7], "'at or before start + resetDrift' is the window before's")
    }

    func testAReadingOfAnotherBucketIsNotTheseOnesWindowBefores() {
        let start = now.addingTimeInterval(-hour)
        let weekly = Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, windowLength: 7 * day, points: [
            (at: start.addingTimeInterval(30), percent: 40, resetsAt: start),
        ])
        let sessionReadings = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
                (at: start.addingTimeInterval(60), percent: 2, resetsAt: start.addingTimeInterval(5 * hour)),
            ]
        )

        XCTAssertEqual(
            LimitShareRules.series(weekly + sessionReadings, bucketID: "five_hour", openSince: start).map(\.percent),
            [2]
        )
        XCTAssertEqual(
            LimitShareRules.series(weekly + sessionReadings, bucketID: "seven_day", openSince: start).map(\.percent),
            [], "this week's reading reports a reset at the start: the week before's"
        )
    }

    func testReadingsThatNameNoResetStayAndAreReadByTheirTimeAlongsideOnesThatDo() throws {
        let start = now.addingTimeInterval(-hour)
        let reset = now.addingTimeInterval(4 * hour)
        let records = Fixture.readings(bucketID: "five_hour", points: [
            (at: start.addingTimeInterval(-30 * minute), percent: 9),
            (at: start.addingTimeInterval(20 * minute), percent: 1),
        ]) + Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: start.addingTimeInterval(1), percent: 4, resetsAt: start),
            (at: start.addingTimeInterval(40 * minute), percent: 2, resetsAt: reset),
        ])
        XCTAssertEqual(
            LimitShareRules.series(records, bucketID: "five_hour", openSince: start).map(\.percent), [9, 1, 2]
        )

        let request = try XCTUnwrap(LimitShareRules.request(
            for: session(percent: 2, resetting: reset), kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let share = try XCTUnwrap(LimitShareRules.share(
            for: request,
            log: TurnCostLog(turns: [Fixture.turnCost(at: start.addingTimeInterval(10 * minute), chat: "a", cost: 1)]),
            readings: records
        ))
        XCTAssertEqual(share.percent, 2, accuracy: 1e-9, "the 9 % before the start is not in the window")
        XCTAssertEqual(share.chats.map(\.id), ["a"])
    }

    /// A weekly window, a limit restored in the middle of it (the percent falls, the reset
    /// stays), and the week before's late reading: the restore still scales, the late
    /// reading does not.
    func testAWeeklyRestoreIsStillScaledAndTheWeekBeforesLateReadingIsNot() throws {
        let weekReset = now.addingTimeInterval(3 * day)
        let start = weekReset.addingTimeInterval(-7 * day)
        let weekly = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 12,
                           resetsAt: weekReset, kind: .weekly, windowLength: 7 * day),
        ], at: now)
        let readings = Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, windowLength: 7 * day, points: [
            (at: start.addingTimeInterval(1), percent: 40, resetsAt: start),
            (at: start.addingTimeInterval(day), percent: 30, resetsAt: weekReset),
            (at: start.addingTimeInterval(2 * day), percent: 10, resetsAt: weekReset),
            (at: start.addingTimeInterval(3 * day), percent: 12, resetsAt: weekReset),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(day - 10 * minute), chat: "chat-a", cost: 3),
            Fixture.turnCost(at: start.addingTimeInterval(3 * day - 10 * minute), chat: "chat-b", cost: 3),
        ])
        let request = try XCTUnwrap(LimitShareRules.request(
            for: weekly, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        XCTAssertEqual(request.period.start, start)

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))

        XCTAssertEqual(share.percent, 12, accuracy: 1e-9)
        XCTAssertEqual(share.chats.first { $0.id == "chat-a" }?.points ?? -1, 10, accuracy: 1e-9, "30 % scaled to the 10 % it fell to")
        XCTAssertEqual(share.chats.first { $0.id == "chat-b" }?.points ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 0, accuracy: 1e-9)
    }

    /// Codex-style readings: a bucket id of the dynamic kind, no reset kept.
    func testReadingsWithNoResetOnAnotherBucketKeepTheHeldDropRule() throws {
        let start = now.addingTimeInterval(-2 * hour)
        let request = LimitShareRequest(
            mode: .subscription, period: LimitWindow(start: start, end: now), bucketID: "primary", livePercent: 2
        )
        let readings = Fixture.readings(bucketID: "primary", points: [
            (at: start.addingTimeInterval(1), percent: 40),
            (at: start.addingTimeInterval(30 * minute), percent: 2),
        ])
        let log = TurnCostLog(turns: [Fixture.turnCost(at: start.addingTimeInterval(20 * minute), chat: "a", cost: 1)])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))

        XCTAssertEqual(share.percent, 2, accuracy: 1e-9, "a drop of 38 points to 2 is the old window's tail, scaled to 2")
    }

    // MARK: - Every load reads the turns back to the horizon

    private var payAsYouGoRequest: LimitShareRequest {
        LimitShareRequest(
            mode: .payAsYouGo(weeklyBudget: 100),
            period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now), bucketID: nil, livePercent: nil
        )
    }

    private func clipped(_ log: TurnCostLog, to window: LimitWindow) -> TurnCostLog {
        var out = log
        out.turns = log.turns.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
        return out
    }

    func testAPayAsYouGoShareIgnoresTurnsOutsideItsPeriodThatAWiderLoadBrings() throws {
        let wide = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-20 * day), chat: "chat-old", cost: 40),
            Fixture.turnCost(at: now.addingTimeInterval(-3 * day), chat: "chat-a", cost: 10),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 15),
        ])
        let request = payAsYouGoRequest
        let span = LimitShareRules.turnSpan(request: request, now: now)
        XCTAssertEqual(span.start, now.addingTimeInterval(-31 * day))

        let load = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: clipped(wide, to: span), records: [], dailySpend: [], now: now
        )
        let narrow = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: clipped(wide, to: request.period), records: [], dailySpend: [], now: now
        )

        XCTAssertEqual(load.share, narrow.share, "dollars, shares, bins and models are the period's alone")
        XCTAssertEqual(load.share?.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(load.share?.cost ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(load.share?.percent ?? -1, 25, accuracy: 1e-9, "$25 of a $100 budget")
        XCTAssertEqual(Set(load.stretches.keys), ["chat-a"], "a chat with no turn in the period has no stretches")
        XCTAssertNil(load.change)
    }

    func testAnEarlierPayAsYouGoWeekIsCutFromTheSameWideLoad() throws {
        let period = LimitWindow(start: now.addingTimeInterval(-14 * day), end: now.addingTimeInterval(-7 * day))
        let request = LimitShareRequest(
            mode: .payAsYouGo(weeklyBudget: nil), period: period, bucketID: nil, livePercent: nil
        )
        let wide = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-20 * day), chat: "chat-old", cost: 40),
            Fixture.turnCost(at: now.addingTimeInterval(-10 * day), chat: "chat-b", cost: 8),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 15),
        ])
        let span = LimitShareRules.turnSpan(request: request, now: now)
        XCTAssertEqual(span, LimitWindow(start: now.addingTimeInterval(-31 * day), end: period.end))

        let load = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: false, bucket: nil, serviceID: "claude",
            log: clipped(wide, to: span), records: [], dailySpend: [], now: now
        )

        XCTAssertEqual(load.share?.chats.map(\.id), ["chat-b"])
        XCTAssertEqual(load.share?.cost ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(load.share?.percent ?? -1, 100, accuracy: 1e-9, "no budget: the period's own spend is the whole")
        XCTAssertEqual(Set(load.stretches.keys), ["chat-b"])
    }

    func testASpendLimitMonthWithTurnsFromTheMonthBeforeCountsOnlyItsOwnDollars() throws {
        let monthStart = now.addingTimeInterval(-5 * day)
        let request = LimitShareRequest(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 100),
            period: LimitWindow(start: monthStart, end: now), bucketID: nil, livePercent: nil
        )
        let wide = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-20 * day), chat: "chat-last-month", cost: 500),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-m", cost: 20),
        ])
        let daily = [
            CLIDailySummary(day: now.addingTimeInterval(-20 * day), totalCost: 500, totalTokens: 0,
                            tokens: TokenBreakdown(), turns: 1, byFamily: [:]),
            CLIDailySummary(day: now.addingTimeInterval(-day), totalCost: 20, totalTokens: 0,
                            tokens: TokenBreakdown(), turns: 1, byFamily: [:]),
        ]

        let load = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: clipped(wide, to: LimitShareRules.turnSpan(request: request, now: now)),
            records: [], dailySpend: daily, now: now
        )

        XCTAssertEqual(load.share?.cost ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(load.share?.chats.map(\.id), ["chat-m"])
        XCTAssertNil(load.share?.earlier, "last month's day total is not this month's earlier spend")
        XCTAssertEqual(load.share?.outside ?? -1, 4, accuracy: 1e-9, "$100 used less $20 here is $80 of $2,000")
    }

    func testASpendLimitMonthLongerThanTheHorizonReadsItsTurnsFromItsStart() throws {
        let monthStart = now.addingTimeInterval(-31 * day - 2 * hour)
        let request = LimitShareRequest(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 30),
            period: LimitWindow(start: monthStart, end: now), bucketID: nil, livePercent: nil
        )
        let wide = TurnCostLog(turns: [
            Fixture.turnCost(at: monthStart.addingTimeInterval(hour), chat: "chat-m", cost: 10),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-m", cost: 20),
        ])
        let daily = [
            CLIDailySummary(day: monthStart, totalCost: 10, totalTokens: 0,
                            tokens: TokenBreakdown(), turns: 1, byFamily: [:]),
            CLIDailySummary(day: now.addingTimeInterval(-day), totalCost: 20, totalTokens: 0,
                            tokens: TokenBreakdown(), turns: 1, byFamily: [:]),
        ]
        let span = LimitShareRules.turnSpan(request: request, now: now)
        XCTAssertEqual(span.start, monthStart)

        let load = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: nil, serviceID: "claude",
            log: clipped(wide, to: span), records: [], dailySpend: daily, now: now
        )

        XCTAssertEqual(load.share?.cost ?? -1, 30, accuracy: 1e-9)
        XCTAssertNil(load.share?.earlier, "the turns cover the month: nothing is left to the day totals")
        XCTAssertEqual(load.share?.outside ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: A chat resumed cold, in the Session view and in a past window

    private var sessionStart: Date { now.addingTimeInterval(-hour) }
    private var sessionReset: Date { now.addingTimeInterval(4 * hour) }

    private var resumedLog: TurnCostLog {
        var log = TurnCostLog(turns: [
            Fixture.promptTurn(at: now.addingTimeInterval(-4 * day), chat: "chat-a", input: 3, cacheWrite1h: 20_000, output: 300),
            Fixture.promptTurn(at: sessionStart.addingTimeInterval(10 * minute), chat: "chat-a", input: 3, cacheWrite1h: 60_000, output: 400),
            Fixture.promptTurn(at: sessionStart.addingTimeInterval(25 * minute), chat: "chat-a", input: 3, cacheRead: 60_000, output: 200),
        ])
        log.prompts["chat-a"] = [
            ChatPrompt(at: now.addingTimeInterval(-4 * day - 30), text: "build the thing"),
            ChatPrompt(at: sessionStart.addingTimeInterval(10 * minute - 20), text: "continue the thing"),
        ]
        return log
    }

    private var resumedReadings: [HistoryRecord] {
        Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(30 * minute), percent: 10, resetsAt: sessionReset),
        ])
    }

    private func sessionLoad() throws -> LimitLoadResult {
        let service = session(percent: 10, resetting: sessionReset)
        let request = try XCTUnwrap(LimitShareRules.request(
            for: service, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let span = LimitShareRules.turnSpan(request: request, now: now)
        return LimitShareRules.loadResult(
            request: request, kind: .session, isCurrent: true, bucket: service.buckets[0], serviceID: "claude",
            log: clipped(resumedLog, to: span), records: resumedReadings, dailySpend: [], now: now
        )
    }

    func testAResumedChatsStretchesStayInsideTheWindowAndSumToItsShare() throws {
        let load = try sessionLoad()
        let share = try XCTUnwrap(load.share)
        let stretches = try XCTUnwrap(load.stretches["chat-a"])

        XCTAssertTrue(stretches.allSatisfy { $0.firstAt >= sessionStart }, "the turn from four days ago is no stretch of this window")
        XCTAssertEqual(
            stretches.reduce(0) { $0 + $1.points },
            share.chats.first { $0.id == "chat-a" }?.points ?? -1, accuracy: 1e-9
        )
        XCTAssertEqual(share.cost, share.chats.reduce(0) { $0 + $1.cost } + 0, accuracy: 1e-9)
        XCTAssertEqual(share.window, LimitWindow(start: sessionStart, end: now))
    }

    func testTheResumedStretchIsNamedByThePromptTypedForIt() throws {
        let stretches = try XCTUnwrap(try sessionLoad().stretches["chat-a"])
        XCTAssertEqual(stretches.first?.prompt, "continue the thing", "not the one that opened the chat four days ago")
    }

    func testTheShareAndTimelineOfTheSessionAreTheSameWithAWideLogAsWithADeliveryOfItsOwnTurnsOnly() throws {
        let service = session(percent: 10, resetting: sessionReset)
        let request = try XCTUnwrap(LimitShareRules.request(
            for: service, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let wide = clipped(resumedLog, to: LimitShareRules.turnSpan(request: request, now: now))
        let narrow = clipped(resumedLog, to: request.period)

        XCTAssertEqual(wide.turns.count, 3)
        XCTAssertEqual(narrow.turns.count, 2)
        XCTAssertEqual(
            LimitShareRules.share(for: request, log: wide, readings: resumedReadings),
            LimitShareRules.share(for: request, log: narrow, readings: resumedReadings)
        )
    }

    /// A second, unrelated chat: only its own window's turns, and no stretch for a chat
    /// that ran before the window and not in it.
    func testAChatThatRanOnlyBeforeTheWindowHasNoRowAndNoStretchInIt() throws {
        var log = resumedLog
        log.turns.append(Fixture.promptTurn(
            at: now.addingTimeInterval(-2 * day), chat: "chat-early", input: 3, cacheWrite1h: 20_000, output: 300
        ))
        let service = session(percent: 10, resetting: sessionReset)
        let request = try XCTUnwrap(LimitShareRules.request(
            for: service, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))

        let load = LimitShareRules.loadResult(
            request: request, kind: .session, isCurrent: true, bucket: service.buckets[0], serviceID: "claude",
            log: clipped(log, to: LimitShareRules.turnSpan(request: request, now: now)),
            records: resumedReadings, dailySpend: [], now: now
        )

        XCTAssertEqual(load.share?.chats.map(\.id), ["chat-a"])
        XCTAssertNil(load.stretches["chat-early"])
    }

    // MARK: - The published-share gate

    private func weeklyAndSession(sessionReset: Date, weekReset: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: sessionReset, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: weekReset, kind: .weekly),
        ], at: now)
    }

    private func gate(_ shares: PublishedShares, for service: ServiceSnapshot, budget: Double = 0) -> [String: ChatShareFields] {
        PublishedShareRules.current(shares, for: service, weeklyBudgetUSD: budget, now: now, calendar: utc)
    }

    func testAShareSurvivesAResetDriftOfLessThanTheDriftAndNotOfExactlyIt() {
        let reset = now.addingTimeInterval(2 * hour)
        let cut = PublishedShares(
            windows: [PublishedShareWindow(field: .session, resetsAt: reset)],
            chats: ["c": ChatShareFields(sessionShare: 3)]
        )
        for (offset, kept) in [(-drift + 1, true), (drift - 1, true), (-drift, false), (drift, false)] {
            let service = Fixture.snapshot(id: "claude", buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                               resetsAt: reset.addingTimeInterval(offset), kind: .session),
            ], at: now)
            XCTAssertEqual(gate(cut, for: service)["c"]?.sessionShare, kept ? 3 : nil, "drift of \(offset) s")
        }
    }

    func testOnlyTheWindowThatMovedLosesItsShare() {
        let sessionReset = now.addingTimeInterval(2 * hour)
        let weekReset = now.addingTimeInterval(2 * day)
        let cut = PublishedShares(
            windows: [
                PublishedShareWindow(field: .session, resetsAt: sessionReset),
                PublishedShareWindow(field: .week, resetsAt: weekReset),
            ],
            chats: ["c": ChatShareFields(sessionShare: 3, weekShare: 8)]
        )
        let weekRolled = weeklyAndSession(sessionReset: sessionReset.addingTimeInterval(1), weekReset: weekReset.addingTimeInterval(7 * day))

        XCTAssertEqual(gate(cut, for: weekRolled)["c"], ChatShareFields(sessionShare: 3))
    }

    func testASpendLimitShareIsKeptOnlyWhileTheLimitIsTheOneItWasCutAgainst() {
        let october = Date(timeIntervalSince1970: 1_790_812_800)
        let cut = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: october, denominatorUSD: 2_000)],
            chats: ["c": ChatShareFields(budgetShare: 1.5)]
        )
        func team(limit: Double) -> ServiceSnapshot {
            Fixture.snapshot(
                id: "claude", plan: "Enterprise", buckets: [],
                extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: limit, usedCredits: 300, utilization: 15),
                at: now
            )
        }

        XCTAssertEqual(gate(cut, for: team(limit: 2_000))["c"]?.budgetShare, 1.5)
        XCTAssertNil(gate(cut, for: team(limit: 2_000.5))["c"]?.budgetShare)
        XCTAssertNil(gate(cut, for: team(limit: 1_000))["c"]?.budgetShare)
    }

    func testAPayAsYouGoShareCutWithNoBudgetIsNotKeptOnceABudgetIsSet() {
        let cut = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil, denominatorUSD: nil)],
            chats: ["c": ChatShareFields(budgetShare: 50)]
        )
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400, at: now)

        XCTAssertNil(gate(cut, for: api, budget: 200)["c"]?.budgetShare)
    }

    // MARK: - A picked past window stays picked

    private func past(from start: Date, to end: Date, reset: Date? = nil) -> LimitsPeriod {
        .past(LimitPastWindow(start: start, end: end, resets: (reset ?? end)...(reset ?? end)))
    }

    func testAWindowWhoseStartMovedByTheDriftButWhoseEndDidNotIsAnotherWindow() {
        let end = now.addingTimeInterval(-hour)
        let start = end.addingTimeInterval(-5 * hour)
        let picked = past(from: start, to: end)

        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: [.current, past(from: start.addingTimeInterval(drift - 1), to: end)]), picked)
        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: [.current, past(from: start.addingTimeInterval(drift), to: end)]), .current)
        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: [.current, past(from: start, to: end.addingTimeInterval(-drift))]), .current)
        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: [.current, past(from: start, to: end.addingTimeInterval(drift - 1))]), picked)
    }

    func testTwoDifferentPastWindowsStayDistinctWhenOnlyOneBoundIsWithinTheDrift() {
        let end = now.addingTimeInterval(-hour)
        let start = end.addingTimeInterval(-5 * hour)
        let one = past(from: start, to: end)
        let neighbour = past(from: start.addingTimeInterval(-5 * hour), to: start.addingTimeInterval(1))

        XCTAssertFalse(LimitsRules.isSamePeriod(one, neighbour), "this window's end is the neighbour's start: not one window")
        XCTAssertEqual(LimitsRules.pickerEntry(for: one, offered: [.current, neighbour, one]), one)
    }

    func testThePickerMarksTheNearestEntryNotTheFirstOneWithinTheDrift() {
        let end = now.addingTimeInterval(-hour)
        let start = end.addingTimeInterval(-5 * hour)
        let picked = past(from: start, to: end)
        let drifted = past(from: start.addingTimeInterval(2), to: end.addingTimeInterval(2))
        let offered: [LimitsPeriod] = [.current, drifted]

        XCTAssertEqual(LimitsRules.pickerEntry(for: picked, offered: offered), drifted)
        XCTAssertEqual(LimitsRules.pickerEntry(for: .current, offered: offered), .current)
        XCTAssertEqual(LimitsRules.pickerEntry(for: .weeksAgo(2), offered: offered), .weeksAgo(2))
    }

    func testAnEarlierWeekIsPickedByItsNumberAndPassedBetweenModesNever() {
        XCTAssertEqual(LimitsRules.selectedPeriod(.weeksAgo(1), offered: [.current, .weeksAgo(1), .weeksAgo(2)]), .weeksAgo(1))
        XCTAssertEqual(LimitsRules.selectedPeriod(.weeksAgo(3), offered: [.current, .weeksAgo(1)]), .current)
        XCTAssertEqual(LimitsRules.selectedPeriod(.past(LimitPastWindow(start: now, end: now, resets: nil)), offered: [.current]), .current)
    }

    func testThePickedWindowSurvivesTheNextWindowOpeningAndStaysTheSameQuery() throws {
        // The session before, found from its own readings, then a newer one opens: the
        // picked window is the second on offer now, with the very bounds it had.
        let start = sessionStart
        let older = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: start.addingTimeInterval(-3 * hour), percent: 20, resetsAt: start),
        ])
        func offered(currentStart: Date, extra: [HistoryRecord]) -> [LimitsPeriod] {
            LimitsRules.periods(mode: .subscription, pastWindows: LimitShareRules.pastWindows(
                records: older + extra, bucketID: "five_hour", windowLength: 5 * hour,
                before: currentStart, horizonStart: now.addingTimeInterval(-31 * day)
            ))
        }
        let picked = try XCTUnwrap(offered(currentStart: start, extra: []).last)

        let nextStart = start.addingTimeInterval(5 * hour)
        let newer = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: nextStart.addingTimeInterval(-hour), percent: 30, resetsAt: nextStart),
        ])
        let after = offered(currentStart: nextStart, extra: newer)

        XCTAssertEqual(after.count, 3, "current, the window that just ended, the picked one")
        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: after), picked)
        XCTAssertEqual(LimitsRules.pickerEntry(for: picked, offered: after), after.last)
    }
}
