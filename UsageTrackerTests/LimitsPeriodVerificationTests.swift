import XCTest
@testable import Omelette

/// The period picker, the load and the timeline, checked against spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, items 1, 2 and 4, and
/// § Accounts without percent windows, Periods. A subscription offers its current window
/// plus past windows; pay as you go the current period plus 3 earlier 7-day blocks; a spend
/// limit no picker. The period is part of the query and the load, so a past period's load
/// never reads as the current one nor the reverse. The change signal uses the bucket's own
/// window length, never fires on a window longer than 8 days and counts its usual weeks.
final class LimitsPeriodVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let gb = Locale(identifier: "en_GB")

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    private var api: ServiceSnapshot { Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 412) }

    private func page(
        _ service: ServiceSnapshot?, kind: BucketKind = .weekly, period: LimitsPeriod,
        load: DashboardState.LimitShareLoad? = nil, answered: LimitsQuery? = nil, budget: Double = 0
    ) -> LimitsPage {
        LimitsRules.page(
            serviceID: "claude", kind: kind, period: period, service: service, weeklyBudgetUSD: budget,
            load: load, answered: answered, now: now, calendar: utc
        )
    }

    private func load(
        _ window: LimitWindow, mode: LimitMode = .subscription, period: LimitsPeriod
    ) -> DashboardState.LimitShareLoad {
        var loaded = Fixture.limitLoad(mode: mode, share: Fixture.limitShare(
            window: window,
            chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 1_200, lastAt: window.end)]
        ))
        loaded.period = period
        return loaded
    }

    // MARK: - A load answers the period it was made for

    func testTwoPastWindowsOnTheSameDaysAreNotEachOther() {
        let end = now.addingTimeInterval(-5 * day)
        let span = LimitWindow(start: end.addingTimeInterval(-7 * day), end: end)
        let one = LimitsPeriod.past(LimitPastWindow(start: span.start, end: span.end, resets: end...end))
        let other = LimitsPeriod.past(LimitPastWindow(start: span.start, end: span.end, resets: end.addingTimeInterval(-300)...end))
        XCTAssertEqual(page(claudeMax, period: one, load: load(span, period: one)), .ready(load(span, period: one)))
        XCTAssertEqual(page(claudeMax, period: other, load: load(span, period: one)), .loading,
                       "the readings that named another reset are another cut")
    }

    func testOneEarlierWeekOfPayAsYouGoIsNotAnother() {
        let mode = LimitMode.payAsYouGo(weeklyBudget: 500)
        func block(_ weeks: Int) -> LimitWindow {
            let end = now.addingTimeInterval(-Double(weeks) * 7 * day)
            return LimitWindow(start: end.addingTimeInterval(-7 * day), end: end)
        }
        let first = load(block(1), mode: mode, period: .weeksAgo(1))
        XCTAssertEqual(page(api, period: .weeksAgo(1), load: first, budget: 500), .ready(first))
        XCTAssertEqual(page(api, period: .weeksAgo(2), load: first, budget: 500), .loading)
        XCTAssertEqual(page(api, period: .current, load: first, budget: 500), .loading,
                       "an earlier block's share is never the last 7 days'")
        let current = load(LimitWindow(start: now.addingTimeInterval(-7 * day), end: now), mode: mode, period: .current)
        XCTAssertEqual(page(api, period: .weeksAgo(1), load: current, budget: 500), .loading,
                       "nor the last 7 days' an earlier block's")
    }

    func testThePastWindowsOfAnotherProviderOrWindowKindAreNotOffered() {
        let end = now.addingTimeInterval(-5 * day)
        let list = DashboardState.LimitPastWindows(
            serviceID: "claude", kind: .weekly,
            windows: [LimitPastWindow(start: end.addingTimeInterval(-7 * day), end: end, resets: end...end)]
        )
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "claude", kind: .weekly).count, 1)
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "claude", kind: .session), [], "the session switch")
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "codex", kind: .weekly), [], "the provider picker")
        XCTAssertEqual(LimitsRules.pastWindows(nil, serviceID: "claude", kind: .weekly), [])
    }

    func testTheCardIsBuiltAgainWhenOnlyThePeriodChangesUnderTheSameShare() {
        let end = now.addingTimeInterval(-5 * day)
        let span = LimitWindow(start: end.addingTimeInterval(-7 * day), end: end)
        let a = load(span, period: .current)
        let b = load(span, period: .past(LimitPastWindow(start: span.start, end: span.end, resets: end...end)))
        XCTAssertNotEqual(a.cardKey, b.cardKey)
        XCTAssertEqual(a.cardKey, load(span, period: .current).cardKey)
    }

    func testAnEarlierWeekIsAnExactSevenDaysAndTheFourthIsNotOffered() {
        let mode = LimitMode.payAsYouGo(weeklyBudget: nil)
        XCTAssertEqual(LimitsRules.periods(mode: mode, pastWindows: []).count, 4, "this block and three earlier")
        let offered = LimitsRules.periods(mode: mode, pastWindows: [])
        XCTAssertEqual(LimitsRules.selectedPeriod(.weeksAgo(3), offered: offered), .weeksAgo(3))
        XCTAssertEqual(LimitsRules.selectedPeriod(.weeksAgo(4), offered: offered), .current, "28–35 days ago reaches past the horizon")
        let request = LimitsRules.request(
            for: api, kind: .weekly, period: .weeksAgo(3), weeklyBudgetUSD: 0, now: now, calendar: utc
        )
        XCTAssertEqual(request?.period, LimitWindow(start: now.addingTimeInterval(-28 * day), end: now.addingTimeInterval(-21 * day)))
        XCTAssertNil(request?.bucketID)
    }

    func testASpendLimitHasNoPickerAndNoEarlierPeriodLoads() {
        let spend = Fixture.snapshot(
            id: "claude", plan: nil, buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62),
            weekCost: 0
        )
        let mode = LimitShareRules.mode(of: spend, weeklyBudgetUSD: 0)
        XCTAssertEqual(mode, .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240))
        XCTAssertFalse(LimitsRules.canPickPeriod(LimitsRules.periods(mode: mode, pastWindows: [])))
        XCTAssertNil(LimitsRules.request(for: spend, kind: .weekly, period: .weeksAgo(1), weeklyBudgetUSD: 0, now: now, calendar: utc))
    }

    // MARK: - The change signal's window

    func testAWindowOfExactlyEightDaysPricesTheChangeAndOneSecondMoreDoesNot() {
        func prices(_ length: TimeInterval) -> Bool {
            LimitShareRules.pricesChange(mode: .subscription, kind: .weekly, isCurrent: true, windowLength: length)
        }
        XCTAssertTrue(prices(8 * day))
        XCTAssertFalse(prices(8 * day + 1))
        XCTAssertFalse(LimitShareRules.pricesChange(mode: .subscription, kind: .weekly, isCurrent: true, windowLength: nil))
        XCTAssertFalse(LimitShareRules.pricesChange(mode: .subscription, kind: .session, isCurrent: true, windowLength: 5 * hour))
        XCTAssertFalse(LimitShareRules.pricesChange(mode: .subscription, kind: .weekly, isCurrent: false, windowLength: 7 * day))
        XCTAssertFalse(LimitShareRules.pricesChange(mode: .payAsYouGo(weeklyBudget: nil), kind: .weekly, isCurrent: true, windowLength: 7 * day))
    }

    func testTheChangeLineSaysHowManyWeeksAndNamesAModelChangeOnlyWhenThereIsOne() {
        func signal(weeks: Int, model: LimitChangeSignal.ModelChange? = nil) -> LimitChangeSignal {
            LimitChangeSignal(price: 40, usualPrice: 60, percentLess: 33, usualWeeks: weeks, modelChange: model)
        }
        XCTAssertEqual(LimitsCopy.changeLine(signal(weeks: 3)), "A percent buys about 33 % less than your last 3 weeks.")
        XCTAssertEqual(LimitsCopy.changeLine(signal(weeks: 1)), "A percent buys about 33 % less than the week before.")
        XCTAssertEqual(
            LimitsCopy.changeLine(signal(weeks: 2, model: .init(usual: "Opus 5.5", now: "Fable 5.1"))),
            "A percent buys about 33 % less than your last 2 weeks. Costliest model this week: Fable 5.1 (was Opus 5.5)."
        )
    }

    // MARK: - One load

    private var weekly: UsageBucket {
        Fixture.bucket(id: "seven_day", label: "All models", percent: 20,
                       resetsAt: now.addingTimeInterval(2 * day), kind: .weekly)
    }

    func testALogThatReachesBackToTheHorizonDoesNotLeakIntoTheWeekOpenNow() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: Fixture.snapshot(id: "claude", buckets: [weekly]), kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let records = Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, points: [
            (at: now.addingTimeInterval(-12 * day), percent: 30, resetsAt: now.addingTimeInterval(-5 * day)),
            (at: now.addingTimeInterval(-day), percent: 20, resetsAt: now.addingTimeInterval(2 * day)),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-12 * day), chat: "last-week", cost: 5_000),
            Fixture.turnCost(at: now.addingTimeInterval(-day - 600), chat: "this-week", cost: 800),
        ])
        let result = LimitShareRules.loadResult(
            request: request, kind: .weekly, isCurrent: true, bucket: weekly, serviceID: "claude",
            log: log, records: records, dailySpend: [], now: now
        )
        let share = try XCTUnwrap(result.share)
        XCTAssertEqual(share.chats.map(\.id), ["this-week"])
        XCTAssertEqual(share.cost, 800, accuracy: 1e-9)
        XCTAssertEqual(Set(result.stretches.keys), ["this-week"])
        XCTAssertEqual(result.pastWindows.map(\.window.end), [now.addingTimeInterval(-5 * day)])
    }

    func testAPastWeeksLoadHoldsOnlyItsOwnChatsAndStretches() throws {
        let records = Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, points: [
            (at: now.addingTimeInterval(-6 * day), percent: 30, resetsAt: now.addingTimeInterval(-5 * day)),
            (at: now.addingTimeInterval(-day), percent: 20, resetsAt: now.addingTimeInterval(2 * day)),
        ])
        let past = LimitPastWindow(
            start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day),
            resets: now.addingTimeInterval(-5 * day)...now.addingTimeInterval(-5 * day)
        )
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-6 * day - 900), chat: "last-week", cost: 1_200),
            Fixture.turnCost(at: now.addingTimeInterval(-day - 600), chat: "this-week", cost: 800),
        ])
        let result = LimitShareRules.loadResult(
            request: LimitShareRules.request(for: past, bucketID: "seven_day"),
            kind: .weekly, isCurrent: false, bucket: weekly, serviceID: "claude",
            log: log, records: records, dailySpend: [], now: now
        )
        XCTAssertEqual(result.share?.chats.map(\.id), ["last-week"])
        XCTAssertEqual(Set(result.stretches.keys), ["last-week"])
        XCTAssertEqual(result.share?.percent ?? -1, 30, accuracy: 1e-9)
        XCTAssertNil(result.change)
    }

    // MARK: - Period names

    func testThePickerNamesPeriodsAsTheSpecWritesThem() {
        XCTAssertEqual(LimitsCopy.periodName(.current, mode: .subscription, span: .week, now: now, calendar: utc, locale: gb), "This week")
        XCTAssertEqual(LimitsCopy.periodName(.current, mode: .subscription, span: .session, now: now, calendar: utc, locale: gb), "This session")
        XCTAssertEqual(LimitsCopy.periodName(.weeksAgo(1), mode: .payAsYouGo(weeklyBudget: nil), span: .week, now: now, calendar: utc, locale: gb), "7–14 days ago")
        let october = LimitPastWindow(
            start: Date(timeIntervalSince1970: 1_790_935_200), // 2026-10-02 10:00 UTC
            end: Date(timeIntervalSince1970: 1_791_540_000), resets: nil
        )
        XCTAssertEqual(
            LimitsCopy.periodName(.past(october), mode: .subscription, span: .week, now: now.addingTimeInterval(60 * day), calendar: utc, locale: gb),
            "Week of 2 Oct"
        )
        let sameDay = LimitPastWindow(
            start: Date(timeIntervalSince1970: 1_788_688_800 + 40 * 60), // 10:40 UTC
            end: Date(timeIntervalSince1970: 1_788_688_800 + 5 * hour + 40 * 60), resets: nil
        )
        XCTAssertEqual(
            LimitsCopy.periodName(.past(sameDay), mode: .subscription, span: .session, now: now, calendar: utc, locale: gb),
            "Today 10:40–15:40"
        )
    }

    // MARK: - The timeline

    func testTheTimelineOfARealShareAddsUpToTheBinsAndKeepsFiveProjectsAtMost() throws {
        let start = Date(timeIntervalSince1970: 1_788_688_800)
        let window = LimitWindow(start: start, end: start.addingTimeInterval(6 * hour))
        var turns: [TurnCost] = []
        for index in 0..<8 {
            turns.append(Fixture.turnCost(
                at: start.addingTimeInterval(Double(index) * 40 * 60 + 300), chat: "chat-\(index)",
                project: "-p\(index)", cost: Double(10 + index)
            ))
        }
        let readings = (1...11).map { LimitReading(time: start.addingTimeInterval(Double($0) * 30 * 60), percent: Double($0) * 1.5) }
        let share = LimitShareRules.share(window: window, series: readings, log: TurnCostLog(turns: turns))
        let timeline = LimitsRules.timeline(of: share, serviceID: "claude", projectName: { $1 })

        XCTAssertEqual(timeline.bars.map(\.total).reduce(0, +), share.bins.map(\.delta).reduce(0, +), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(timeline.series.count, 7)
        XCTAssertEqual(timeline.series.filter { $0.id != "other" && $0.id != "outside" }.count, 5)
        XCTAssertEqual(timeline.bars.map(\.start), timeline.bars.map(\.start).sorted(), "oldest first")
        for bar in timeline.bars {
            XCTAssertEqual(bar.parts.last?.top ?? 0, bar.parts.reduce(0) { $0 + $1.points }, accuracy: 1e-9)
            let ids = bar.parts.map(\.seriesID)
            let order = timeline.series.map(\.id)
            XCTAssertEqual(ids, order.filter(ids.contains), "stack order is the series order")
        }
        XCTAssertGreaterThanOrEqual(timeline.axis.last ?? 0, timeline.bars.map(\.total).max() ?? 0)
    }

    func testExactlyFiveProjectsLeaveNoOtherAndEveryAxisHasAtMostFourSteps() {
        let start = Date(timeIntervalSince1970: 1_788_688_800)
        let window = LimitWindow(start: start, end: start.addingTimeInterval(2 * hour))
        let chats = (0..<5).map { Fixture.chatShare(id: "c\($0)", project: "p\($0)", points: Double(5 - $0), cost: 10, lastAt: window.end) }
        let share = LimitShare(
            window: window, percent: 15, chats: chats, projects: LimitShareRules.projectShares(chats), outside: 0,
            bins: [LimitBinShare(start: start, delta: 15, chats: Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0.points) }), outside: 0)],
            cost: 50, tokens: 5_000, price: nil, costByModel: [:], unbinnedOutside: 0, earlier: nil
        )
        XCTAssertEqual(LimitsRules.timeline(of: share, serviceID: "claude", projectName: { $1 }).series.map(\.id), ["p0", "p1", "p2", "p3", "p4"])
        for top in stride(from: 0.0, through: 120.0, by: 0.37) {
            let axis = LimitsRules.timelineAxis(top: top)
            XCTAssertEqual(axis.first, 0)
            XCTAssertLessThanOrEqual(axis.count, 5, "top \(top)")
            XCTAssertGreaterThanOrEqual(axis.last ?? 0, top - LimitShareRules.pointSlack, "top \(top)")
            let steps = zip(axis, axis.dropFirst()).map { $1 - $0 }
            XCTAssertEqual(Set(steps).count, 1, "equal steps at top \(top)")
        }
    }
}
