import XCTest
@testable import Omelette

/// Rounding and field assembly of the published chat shares: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data ("percent
/// points of the current windows, one decimal") and § Accounts without percent windows
/// (`budgetShare`, "percent of the budget or limit, one decimal"). Also the request
/// rules for Codex against Claude and for a spend limit's calendar month.
final class PublishedShareRulesVerificationTests: XCTestCase {
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

    // MARK: - One decimal

    func testTheHalfPointRoundsUpAndJustBelowItRoundsDown() {
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.05), 0.1)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.04999), 0)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.0499999999), 0)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.15), 0.2)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.25), 0.3)
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.35), 0.4)
    }

    func testRoundingKeepsWholeAndNearWholeValuesExact() {
        XCTAssertEqual(PublishedShareRules.oneDecimal(0), 0)
        XCTAssertEqual(PublishedShareRules.oneDecimal(5), 5)
        XCTAssertEqual(PublishedShareRules.oneDecimal(12.34), 12.3)
        XCTAssertEqual(PublishedShareRules.oneDecimal(99.95), 100)
        XCTAssertEqual(PublishedShareRules.oneDecimal(100), 100)
        // Floating-point noise from a sum must not leak into the file.
        XCTAssertEqual(PublishedShareRules.oneDecimal(0.1 + 0.2), 0.3)
        XCTAssertEqual(PublishedShareRules.oneDecimal(4.999999999999), 5)
    }

    func testARoundedShareEncodesWithOneDecimalAtMost() throws {
        // 0.1 + 0.2 is 0.30000000000000004 as a Double: the file must carry 0.3.
        let entry = StatusSnapshot.SessionEntry(
            id: "s1", title: "t", project: "p", lastAt: now, turns: 1, tokens: 1, cost: nil,
            agents: 0, origin: nil,
            sessionShare: PublishedShareRules.oneDecimal(0.1 + 0.2),
            weekShare: PublishedShareRules.oneDecimal(5.65),
            budgetShare: nil
        )
        let text = String(decoding: try StatusFile.encoder.encode(entry), as: UTF8.self)

        XCTAssertTrue(text.contains("\"sessionShare\" : 0.3"), text)
        XCTAssertFalse(text.contains("0.30000"), text)
    }

    // MARK: - A chat that ran and moved almost nothing

    func testAChatBelowHalfATenthStillCarriesAZeroNotAnAbsentKey() {
        // $0.25 of a $500 budget is 0.05 %, $0.2499 is 0.04998 %: both ran.
        let share = LimitShareRules.spendShare(
            period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now),
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "at-the-half", cost: 0.25),
                Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "just-below", cost: 0.2499),
            ]),
            denominator: .budget(500)
        )

        let fields = PublishedShareRules.fields([.budget: share])

        XCTAssertEqual(fields["at-the-half"], ChatShareFields(budgetShare: 0.1))
        XCTAssertEqual(fields["just-below"], ChatShareFields(budgetShare: 0))
        XCTAssertNotNil(fields["just-below"]?.budgetShare, "0.0 means it ran; absent means it did not")
    }

    // MARK: - Several chats in one bin

    func testFiveChatsSplitABinByDollarsAndEachIsRoundedOnItsOwn() {
        let window = LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now)
        let at = window.start.addingTimeInterval(10 * minute)
        let log = TurnCostLog(turns: (1...5).map { k in
            Fixture.turnCost(at: at.addingTimeInterval(Double(k)), chat: "chat-\(k)", cost: Double(k))
        })
        // The first half hour of the window climbs to 7 points: 1 : 2 : 3 : 4 : 5.
        let share = LimitShareRules.share(window: window, series: [
            LimitReading(time: window.start.addingTimeInterval(25 * minute), percent: 7),
            LimitReading(time: now, percent: 7),
        ], log: log)

        let fields = PublishedShareRules.fields([.session: share])

        XCTAssertEqual(fields["chat-1"]?.sessionShare, 0.5)
        XCTAssertEqual(fields["chat-2"]?.sessionShare, 0.9)
        XCTAssertEqual(fields["chat-3"]?.sessionShare, 1.4)
        XCTAssertEqual(fields["chat-4"]?.sessionShare, 1.9)
        XCTAssertEqual(fields["chat-5"]?.sessionShare, 2.3)
        XCTAssertEqual(fields.count, 5)
    }

    func testAChatInBothWindowsKeepsItsTwoSharesApartAndASessionZeroIsKept() {
        // chat-x ran in both windows. In the session window nothing rose while it ran.
        let sessionWindow = LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now)
        let weekWindow = LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-3 * day), chat: "chat-x", cost: 1),
            Fixture.turnCost(at: now.addingTimeInterval(-10 * minute), chat: "chat-x", cost: 1),
        ])
        let session = LimitShareRules.share(window: sessionWindow, series: [
            LimitReading(time: now, percent: 0),
        ], log: log)
        let week = LimitShareRules.share(window: weekWindow, series: [
            LimitReading(time: now.addingTimeInterval(-3 * day + 10 * minute), percent: 6),
            LimitReading(time: now, percent: 6),
        ], log: log)

        let fields = PublishedShareRules.fields([.session: session, .week: week])

        XCTAssertEqual(fields["chat-x"], ChatShareFields(sessionShare: 0, weekShare: 6))
    }

    func testNoSharesGiveNoChats() {
        XCTAssertEqual(PublishedShareRules.fields([:]), [:])
    }

    // MARK: - Codex against Claude

    func testCodexPlusPublishesSessionAndWeekJustLikeClaude() {
        let plus = Fixture.snapshot(id: "codex", plan: "Plus", buckets: [
            Fixture.bucket(id: "codex_session", label: "5h", percent: 12,
                           resetsAt: now.addingTimeInterval(hour), kind: .session,
                           windowLength: 5 * 3_600),
            Fixture.bucket(id: "codex_weekly", label: "Weekly", percent: 30,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly,
                           windowLength: 10_080 * 60),
        ])

        let fields = PublishedShareRules.requests(for: plus, weeklyBudgetUSD: 0, now: now, calendar: utc)
            .map(\.window.field)

        XCTAssertEqual(fields, [.session, .week])
    }

    func testCodexOnPayAsYouGoPublishesNothingEvenWithAClaudeBudgetSet() {
        let codexAPI = Fixture.snapshot(id: "codex", plan: nil, buckets: [], weekCost: 80)

        XCTAssertEqual(
            PublishedShareRules.requests(for: codexAPI, weeklyBudgetUSD: 500, now: now, calendar: utc), []
        )
    }

    func testClaudeOnPayAsYouGoWithABudgetPublishesTheSameServiceNothingWithout() {
        let claudeAPI = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 80)

        XCTAssertEqual(
            PublishedShareRules.requests(for: claudeAPI, weeklyBudgetUSD: 500, now: now, calendar: utc)
                .map(\.window.field),
            [.budget]
        )
        XCTAssertEqual(
            PublishedShareRules.requests(for: claudeAPI, weeklyBudgetUSD: 0, now: now, calendar: utc), []
        )
    }

    func testTheSyntheticWeeklyBudgetBucketIsNotAWeekShare() {
        let claudeAPI = Fixture.snapshot(id: "claude", plan: nil, buckets: [
            Fixture.bucket(id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget",
                           percent: 80, kind: .weekly),
        ], weekCost: 400)

        let fields = PublishedShareRules.requests(for: claudeAPI, weeklyBudgetUSD: 500, now: now, calendar: utc)
            .map(\.window.field)

        XCTAssertEqual(fields, [.budget], "the budget bucket makes a budget share, never a weekShare")
    }

    func testAModelSpecificWindowAloneIsNotASubscriptionToPublishFor() {
        let opusOnly = Fixture.snapshot(id: "claude", plan: "Max 5x", buckets: [
            Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 70,
                           resetsAt: now.addingTimeInterval(day), kind: .modelSpecific),
        ])

        XCTAssertEqual(
            PublishedShareRules.requests(for: opusOnly, weeklyBudgetUSD: 0, now: now, calendar: utc)
                .map(\.window.field).filter { $0 != .budget },
            []
        )
    }

    // MARK: - A spend limit across a month boundary

    private func team(_ extra: ExtraUsage? = ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62)) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: "Enterprise", buckets: [], extraUsage: extra, weekCost: 300)
    }

    /// 2026-09-30 23:59:59 UTC.
    private let lastSecondOfSeptember = Date(timeIntervalSince1970: 1_790_812_799)
    /// 2026-10-01 00:00:00 UTC.
    private let firstSecondOfOctober = Date(timeIntervalSince1970: 1_790_812_800)
    /// 2026-11-01 00:00:00 UTC.
    private let firstSecondOfNovember = Date(timeIntervalSince1970: 1_793_491_200)

    func testASpendLimitsShareIsTaggedWithTheNextMonthsFirstInstant() {
        let septemberEnd = PublishedShareRules.requests(
            for: team(), weeklyBudgetUSD: 0, now: lastSecondOfSeptember, calendar: utc
        )
        let octoberMid = PublishedShareRules.requests(
            for: team(), weeklyBudgetUSD: 0, now: firstSecondOfOctober.addingTimeInterval(86_400), calendar: utc
        )

        XCTAssertEqual(septemberEnd.map(\.window.resetsAt), [firstSecondOfOctober])
        XCTAssertEqual(octoberMid.map(\.window.resetsAt), [firstSecondOfNovember])
        XCTAssertEqual(septemberEnd.first?.request.period.start, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(septemberEnd.first?.request.period.end, lastSecondOfSeptember)
    }

    func testTheFirstInstantOfAMonthHasNoSpendLimitShareYet() {
        // The month so far is empty at 00:00:00: the Limits rule has no period to cut.
        XCTAssertEqual(
            PublishedShareRules.requests(for: team(), weeklyBudgetUSD: 0, now: firstSecondOfOctober, calendar: utc),
            []
        )
    }

    func testTheMonthIsTheCalendarsMonthNotUTCs() throws {
        var pacific = utc
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-10-01 00:00 PDT is 07:00 UTC.
        let octoberInPacific = Date(timeIntervalSince1970: 1_790_812_800 + 7 * 3_600)

        let requests = PublishedShareRules.requests(
            for: team(), weeklyBudgetUSD: 0, now: lastSecondOfSeptember, calendar: pacific
        )

        XCTAssertEqual(requests.map(\.window.resetsAt), [octoberInPacific])
    }

    func testDecemberRollsIntoJanuary() {
        // 2026-12-31 23:59:59 UTC and 2027-01-01 00:00:00 UTC.
        let lastOfDecember = Date(timeIntervalSince1970: 1_798_761_599)
        let firstOfJanuary = Date(timeIntervalSince1970: 1_798_761_600)

        XCTAssertEqual(
            PublishedShareRules.requests(for: team(), weeklyBudgetUSD: 0, now: lastOfDecember, calendar: utc)
                .map(\.window.resetsAt),
            [firstOfJanuary]
        )
    }

    func testASpendLimitThatIsSwitchedOffOrHasNoLimitPublishesNothing() {
        let off = ExtraUsage(isEnabled: false, monthlyLimit: 2_000, usedCredits: 0, utilization: 0)
        let unlimited = ExtraUsage(isEnabled: true, monthlyLimit: 0, usedCredits: 5, utilization: 0)

        XCTAssertEqual(PublishedShareRules.requests(for: team(off), weeklyBudgetUSD: 0, now: now, calendar: utc), [])
        XCTAssertEqual(PublishedShareRules.requests(for: team(unlimited), weeklyBudgetUSD: 0, now: now, calendar: utc), [])
    }

    func testASpendLimitShareIsTheChatsDollarsOverTheMonthlyLimit() async {
        // 2026-09-30 12:00 UTC: three days into nothing special, a chat spent $25 on the 3rd.
        let late = Date(timeIntervalSince1970: 1_790_812_799 - 12 * 3_600)
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: Date(timeIntervalSince1970: 1_788_220_800 + 2 * 86_400), chat: "chat-d", cost: 25),
            Fixture.turnCost(at: late.addingTimeInterval(-3_600), chat: "chat-e", cost: 12.34),
            // Before the month started: not this month's.
            Fixture.turnCost(at: Date(timeIntervalSince1970: 1_788_220_800 - 3_600), chat: "chat-old", cost: 900),
        ])
        let sources = PublishedShareRules.Sources(turns: { _, _ in log }, readings: { _ in [] })

        let shares = await PublishedShareRules.shares(
            for: team(), weeklyBudgetUSD: 0, now: late, calendar: utc, sources: sources
        )

        XCTAssertEqual(
            shares.windows, [PublishedShareWindow(field: .budget, resetsAt: firstSecondOfOctober, denominatorUSD: 2_000)]
        )
        XCTAssertEqual(shares.chats["chat-d"], ChatShareFields(budgetShare: 1.3), "$25 of $2,000 is 1.25 %")
        XCTAssertEqual(shares.chats["chat-e"], ChatShareFields(budgetShare: 0.6), "$12.34 of $2,000 is 0.617 %")
        XCTAssertNil(shares.chats["chat-old"])
    }
}
