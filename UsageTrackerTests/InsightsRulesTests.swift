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

    private var logRoot: URL!

    override func setUpWithError() throws {
        logRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: logRoot)
    }

    /// One assistant turn as Claude Code writes it to `~/.claude/projects/<slug>/<uuid>.jsonl`,
    /// `minutesAgo` before the wall clock: the aggregator keeps a month of turns counted
    /// from the real now.
    private func claudeLogLine(id: String, model: String, input: Int, minutesAgo: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(-minutesAgo * 60))
        return """
        {"type":"assistant","timestamp":"\(timestamp)","message":{"id":"\(id)","model":"\(model)",\
        "usage":{"input_tokens":\(input),"output_tokens":0,"cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
        """
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

    // MARK: - Most-used model today

    func testTheMostUsedModelTodayIsTheDearest() {
        XCTAssertEqual(
            InsightsRules.mostUsedModelToday([model("Sonnet 5", 15.37), model("Opus 5", 308.95), model("Fable 5.1", 89.79)]),
            InsightsModelCost(model: "Opus 5", cost: 308.95)
        )
    }

    /// Equal costs leave a dictionary in any order; the card must not flicker between polls.
    func testATieGoesToTheNameFirstInTheAlphabet() {
        XCTAssertEqual(InsightsRules.mostUsedModelToday([model("Sonnet 5", 10), model("Opus 5", 10)])?.model, "Opus 5")
    }

    func testNoModelTodayMeansNoMostUsedModel() {
        XCTAssertNil(InsightsRules.mostUsedModelToday([]))
    }

    // MARK: - This week vs last

    func testThisWeekIsTodayAndTheSixDaysBeforeIt() {
        let week = InsightsRules.weekOverWeek(
            dailies: [
                daily(day(0), cost: 10), daily(day(-6), cost: 5), daily(day(-7), cost: 20),
                daily(day(-13), cost: 1), daily(day(-14), cost: 100)
            ],
            now: now, calendar: utc
        )

        XCTAssertEqual(week.thisWeek, 15, accuracy: 1e-9)
        XCTAssertEqual(week.lastWeek, 21, accuracy: 1e-9)
        XCTAssertEqual(week.deltaPercent ?? 0, (15.0 - 21.0) / 21.0 * 100, accuracy: 1e-9)
    }

    /// 7 × 86 400 s back from 00:30 on 1 April lands at 23:30 on 24 March, so a cut by
    /// seconds counts 25 March, the eighth day, as this week.
    func testAWeekAcrossTheSpringClockChangeIsStillSevenDays() {
        let week = InsightsRules.weekOverWeek(
            dailies: [daily(berlinDay(-7), cost: 99), daily(berlinDay(-6), cost: 1), daily(berlinDay(0), cost: 2)],
            now: berlinNow, calendar: berlin
        )

        XCTAssertEqual(week.thisWeek, 3, accuracy: 1e-9)
        XCTAssertEqual(week.lastWeek, 99, accuracy: 1e-9)
    }

    // MARK: - Daily average, 30 days

    func testTheDailyAverageCountsOnlyDaysWithSpend() {
        let average = InsightsRules.dailyAverage(
            dailies: [
                daily(day(0), cost: 30), daily(day(-1), cost: 0),
                daily(day(-29), cost: 10), daily(day(-30), cost: 1_000)
            ],
            now: now, calendar: utc
        )

        XCTAssertEqual(average, InsightsDailyAverage(average: 20, activeDays: 2))
    }

    /// 30 × 86 400 s back from 00:30 on 1 April lands at 23:30 on 1 March, which would
    /// count 2 March, the thirty-first day.
    func testTheThirtyDaysAreCalendarDaysAcrossTheClockChange() {
        let average = InsightsRules.dailyAverage(
            dailies: [daily(berlinDay(-30), cost: 1_000), daily(berlinDay(0), cost: 10)],
            now: berlinNow, calendar: berlin
        )

        XCTAssertEqual(average, InsightsDailyAverage(average: 10, activeDays: 1))
    }

    // MARK: - Session window: by project

    func testProjectBarsAreMeasuredAgainstTheDearestProject() {
        let rows = InsightsRules.projectRows([
            project("scratchpad", cost: 53.45, turns: 101),
            project("subagents", cost: 164.31, turns: 1_523),
            project("test / blender test", cost: 0.98, turns: 6),
            project("Usage tracker", cost: 34.24, turns: 112)
        ])

        XCTAssertEqual(rows.map(\.name), ["subagents", "scratchpad", "Usage tracker", "test / blender test"])
        guard rows.count == 4 else { return XCTFail("four rows expected") }
        // Dashboard-Insights.dc.html: 100 %, 32.5 %, 20.8 %, and 1.0 % for 98 cents.
        XCTAssertEqual(rows[0].fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(rows[1].fraction, 0.325, accuracy: 0.0005)
        XCTAssertEqual(rows[2].fraction, 0.208, accuracy: 0.0005)
        XCTAssertEqual(rows[3].fraction, 0.01, accuracy: 1e-9)
        XCTAssertEqual(rows[0].turns, 1_523)
        XCTAssertEqual(rows[0].id, "slug-subagents")
    }

    func testTheListStopsAtFiveProjects() {
        let rows = InsightsRules.projectRows([
            project("a", cost: 6), project("b", cost: 5), project("c", cost: 4),
            project("d", cost: 3), project("e", cost: 2), project("f", cost: 1)
        ])

        XCTAssertEqual(InsightsRules.projectRowLimit, 5)
        XCTAssertEqual(rows.map(\.name), ["a", "b", "c", "d", "e"])
    }

    func testWithoutSpendNoBarIsDrawn() {
        let rows = InsightsRules.projectRows([project("a", cost: 0), project("b", cost: 0)])

        XCTAssertEqual(rows.map(\.fraction), [0, 0])
    }

    // MARK: - Session window: split by model

    func testTwoModelsSplitTheBarBetweenThem() {
        let split = InsightsRules.modelSplit([model("Sonnet 5", 25), model("Opus 5", 75)])

        XCTAssertEqual(split, [
            InsightsModelShare(model: "Opus 5", cost: 75, fraction: 0.75, isOther: false),
            InsightsModelShare(model: "Sonnet 5", cost: 25, fraction: 0.25, isOther: false)
        ])
    }

    /// Three models with dollars keep a slice each: the mockup's split.
    func testTheMockupsThreeModelsKeepTheirOwnSlices() {
        let split = InsightsRules.modelSplit([model("Sonnet 5", 15.37), model("Opus 5", 145.70), model("Fable 5.1", 89.79)])

        XCTAssertEqual(split.map(\.model), ["Opus 5", "Fable 5.1", "Sonnet 5"])
        XCTAssertFalse(split.contains(where: \.isOther))
        guard split.count == 3 else { return XCTFail("three shares expected") }
        // Dashboard-Insights.dc.html: 58.1 %, 35.8 %, 6.1 %.
        XCTAssertEqual(split[0].fraction, 0.581, accuracy: 0.0005)
        XCTAssertEqual(split[1].fraction, 0.358, accuracy: 0.0005)
        XCTAssertEqual(split[2].fraction, 0.061, accuracy: 0.0005)
        XCTAssertEqual(split.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(split[0].cost, 145.70, accuracy: 1e-9)
    }

    /// Five models with dollars: the two dearest keep their slices and the other three
    /// are summed into "Other", so the bar and the legend add up to the headline.
    /// A model with no dollars has nothing to draw.
    func testPastThreeModelsTheThirdSliceIsOther() {
        let split = InsightsRules.modelSplit([
            model("C", 2), model("A", 4), model("Free", 0), model("D", 1), model("B", 3), model("E", 0.5)
        ])

        XCTAssertEqual(InsightsRules.modelSplitLimit, 3)
        XCTAssertEqual(split.map(\.model), ["A", "B", "Other"])
        XCTAssertEqual(split.map(\.isOther), [false, false, true])
        guard split.count == 3 else { return XCTFail("three slices expected") }
        XCTAssertEqual(split[2].cost, 3.5, accuracy: 1e-9)
        XCTAssertEqual(split.map(\.cost).reduce(0, +), 10.5, accuracy: 1e-9)
        XCTAssertEqual(split[0].fraction, 4.0 / 10.5, accuracy: 1e-9)
        XCTAssertEqual(split.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertTrue(InsightsRules.modelSplit([model("Free", 0)]).isEmpty)
    }

    /// Review F3: the complete split holds the window's whole cost, the headline, before
    /// any display rounding. The window comes from the real aggregator over Claude Code
    /// log lines: five priced models (the dearest two plus "Other"), a response logged
    /// twice under one `message.id`, and a `<synthetic>` turn the aggregator drops.
    ///
    /// The one exception to the fixed-clock rule, by session ruling: the log lines and the
    /// window's end are minutes before the wall clock. `JSONLAggregator` folds turns older
    /// than its recent window by the real clock (`ingest` at JSONLAggregator.swift:1234,
    /// `pruneAndFold` at :1428), so a fixed 2026 epoch would fold every fixture turn out of
    /// `usage(from:to:)`; `JSONLAggregatorTests` writes its fixtures the same way. Nothing
    /// asserted depends on the wall-clock day: the split and the sum are the same at any
    /// time. The calendar is pinned anyway: the aggregator is built with `utc`.
    func testTheCompleteSplitAddsUpToTheWindowsCost() async throws {
        let end = Date()
        let lines = [
            claudeLogLine(id: "msg_1", model: "claude-opus-4-5", input: 1_000_000, minutesAgo: 50),
            claudeLogLine(id: "msg_1", model: "claude-opus-4-5", input: 1_000_000, minutesAgo: 50),
            claudeLogLine(id: "msg_2", model: "claude-sonnet-4-5", input: 1_000_000, minutesAgo: 40),
            claudeLogLine(id: "msg_3", model: "claude-haiku-4-5", input: 1_000_000, minutesAgo: 30),
            claudeLogLine(id: "msg_4", model: "claude-fable-5-1", input: 100_000, minutesAgo: 20),
            claudeLogLine(id: "msg_5", model: "claude-opus-4-1", input: 100_000, minutesAgo: 10),
            claudeLogLine(id: "msg_6", model: "<synthetic>", input: 0, minutesAgo: 5)
        ]
        let project = logRoot.appendingPathComponent("slug-alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        let aggregator = JSONLAggregator(rootURL: logRoot, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let usage = await aggregator.usage(from: end.addingTimeInterval(-2 * 3600), to: end)

        let split = InsightsRules.modelSplit(usage.models)

        // $5 + $3 + $1 + $1 + $1.50 at the static table's input rates.
        XCTAssertEqual(usage.cost, 11.5, accuracy: 1e-9)
        XCTAssertEqual(usage.models.count, 5)
        XCTAssertEqual(split.map(\.isOther), [false, false, true])
        XCTAssertEqual(split.map(\.cost).reduce(0, +), usage.cost, accuracy: 1e-9)
    }

    // MARK: - Page

    /// Dashboard-Insights.dc.html, in order: the session window, This week vs last and
    /// Days at limit, then the strip.
    func testACostProviderGetsTheMockupsPage() {
        XCTAssertEqual(
            InsightsRules.page(hasCostLog: true, hasSessionWindow: true),
            InsightsPage(
                showsSessionWindow: true,
                cards: [.weekOverWeek, .daysAtLimit],
                strip: [.dailyAverage, .biggestDay, .mostUsedModelToday]
            )
        )
    }

    /// Grok reports no session window; the rest of its page stays.
    func testACostProviderWithoutASessionWindowKeepsItsFigures() {
        XCTAssertEqual(
            InsightsRules.page(hasCostLog: true, hasSessionWindow: false),
            InsightsPage(
                showsSessionWindow: false,
                cards: [.weekOverWeek, .daysAtLimit],
                strip: [.dailyAverage, .biggestDay, .mostUsedModelToday]
            )
        )
    }

    /// No dollars to show: the quota figures take the same places, Days at limit first.
    func testAQuotaOnlyProviderShowsItsQuotaFiguresInTheSamePlaces() {
        XCTAssertEqual(
            InsightsRules.page(hasCostLog: false, hasSessionWindow: false),
            InsightsPage(
                showsSessionWindow: false,
                cards: [.daysAtLimit, .averageDailyPeak],
                strip: [.quotaPerDay, .busiestQuotaDay, .busiestHour]
            )
        )
    }

    // MARK: - Footnote

    func testTheFootnoteSaysOnceThatTheDollarsAreAPIEquivalent() {
        let claude = DashboardState.costSource(for: "claude")
        let subscription = Fixture.snapshot(buckets: [Fixture.bucket(id: "five_hour", kind: .session)])
        let payAsYouGo = Fixture.snapshot(buckets: [])

        XCTAssertEqual(InsightsRules.footnote(costSource: claude, service: subscription), CostCopy.apiEquivalent)
        XCTAssertEqual(InsightsRules.footnote(costSource: claude, service: nil), CostCopy.apiEquivalent)
        // Pay-as-you-go: the dollars are the bill.
        XCTAssertNil(InsightsRules.footnote(costSource: claude, service: payAsYouGo))
    }

    func testAProviderWithoutACostLogIsToldWhy() {
        let antigravity = DashboardState.costSource(for: "antigravity")

        XCTAssertNotNil(antigravity.reason)
        XCTAssertEqual(InsightsRules.footnote(costSource: antigravity, service: nil), antigravity.reason)
    }
}
