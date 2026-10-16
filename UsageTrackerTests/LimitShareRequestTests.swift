import XCTest
@testable import Omelette

/// What the dashboard loads for the Limits tab, and how it is cut: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Packages 1 ("DashboardState
/// loads one window's result off the main actor") and § Accounts without percent
/// windows, Periods.
/// - Subscription: the current window of the asked kind, ending on the live bucket's
///   percent. Per § Design, Totals, "the live bucket's percent is the
///   final reading when it is newer or higher than the last recorded one".
/// - Subscription, Totals: "Chat shares plus Outside equal the window's percent now",
///   so a held drop inside the current window restarts its readings there.
/// - Pay as you go: the last 7 days.
/// - Spend limit: the calendar month so far.
///
/// `DashboardState.refreshLimitShare(kind:)` is glue around these rules.
final class LimitShareRequestTests: XCTestCase {
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

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    private var team: ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62),
            weekCost: 300
        )
    }

    func testASubscriptionLoadsTheCurrentWindowOfTheAskedKind() {
        XCTAssertEqual(
            LimitShareRules.request(for: claudeMax, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc),
            LimitShareRequest(
                mode: .subscription,
                period: LimitWindow(start: now.addingTimeInterval(-5 * day), end: now),
                bucketID: "seven_day",
                livePercent: 40
            )
        )
        XCTAssertEqual(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc),
            LimitShareRequest(
                mode: .subscription,
                period: LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now),
                bucketID: "five_hour",
                livePercent: 9
            )
        )
    }

    func testAWindowTheAccountDoesNotHaveLoadsNothing() {
        let weekly = Fixture.bucket(id: "codex_session", label: "Weekly", percent: 10,
                                    resetsAt: now.addingTimeInterval(day), kind: .weekly,
                                    windowLength: 10_080 * 60)
        let prolite = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [weekly])
        XCTAssertNil(LimitShareRules.request(for: prolite, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc))
    }

    func testPayAsYouGoLoadsTheLastSevenDays() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400)
        XCTAssertEqual(
            LimitShareRules.request(for: api, kind: .weekly, weeklyBudgetUSD: 500, now: now, calendar: utc),
            LimitShareRequest(
                mode: .payAsYouGo(weeklyBudget: 500),
                period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now),
                bucketID: nil,
                livePercent: nil
            )
        )
    }

    func testASpendLimitLoadsTheCalendarMonthSoFar() {
        XCTAssertEqual(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc),
            LimitShareRequest(
                mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240),
                // 2026-09-01 00:00 UTC.
                period: LimitWindow(start: Date(timeIntervalSince1970: 1_788_220_800), end: now),
                bucketID: nil,
                livePercent: nil
            )
        )
    }

    func testASubscriptionShareIsCutFromTheWindowsReadingsEndingOnTheLivePercent() throws {
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: request.period.start.addingTimeInterval(20 * 60), percent: 4),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: request.period.start.addingTimeInterval(5 * 60), chat: "chat-a", cost: 2),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(
            share,
            LimitShareRules.share(
                window: request.period,
                series: LimitShareRules.endingOnLive(
                    LimitShareRules.series(readings, bucketID: "five_hour"), percent: 9, at: now
                ),
                log: log
            )
        )
        XCTAssertEqual(share.chats.first?.points ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 5, "the live 9 % moved the last half hour, where no local turn ran")
        XCTAssertEqual(share.percent, 9)
    }

    func testTheLivePercentIsTheTotalWhenHistoryLagsBehindIt() throws {
        // History is written at most every 30 seconds per service and only for a healthy
        // poll, so it can trail the live bucket: here it reads 7 % and the bucket 9 %.
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: now.addingTimeInterval(-10 * 60), percent: 7),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-20 * 60), chat: "chat-a", cost: 2),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        let live = try XCTUnwrap(request.livePercent)
        XCTAssertEqual(live, 9)
        XCTAssertEqual(share.percent, live, "the window's percent now is the live bucket's 9 %")
        XCTAssertEqual(share.chats.first?.points ?? -1, 9, accuracy: 1e-9)
        XCTAssertEqual(share.chats.reduce(0) { $0 + $1.points } + share.outside, 9, accuracy: 1e-9)
    }

    func testWithNoHistoryTheLivePercentIsTheWholeWindow() throws {
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )

        let unexplained = try XCTUnwrap(LimitShareRules.share(for: request, log: TurnCostLog(), readings: []))
        XCTAssertEqual(unexplained.percent, 9)
        XCTAssertEqual(unexplained.outside, 9, "no reading and no turn on this Mac: all of it is Outside")

        let local = try XCTUnwrap(LimitShareRules.share(
            for: request,
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: now.addingTimeInterval(-20 * 60), chat: "chat-a", cost: 2),
            ]),
            readings: []
        ))
        XCTAssertEqual(local.percent, 9)
        XCTAssertEqual(local.chats.first?.points ?? -1, 9, accuracy: 1e-9)
    }

    func testTheLiveReadingIsAppendedWhenNewerOrHigherThanTheLastRecorded() {
        let earlier = LimitReading(time: now.addingTimeInterval(-600), percent: 7)
        let live = LimitReading(time: now, percent: 9)

        XCTAssertEqual(LimitShareRules.endingOnLive([earlier], percent: 9, at: now), [earlier, live])
        XCTAssertEqual(LimitShareRules.endingOnLive([], percent: 9, at: now), [live])
        XCTAssertEqual(LimitShareRules.endingOnLive([earlier], percent: nil, at: now), [earlier], "no live bucket, nothing to add")

        let recordedNowHigher = LimitReading(time: now, percent: 10)
        XCTAssertEqual(
            LimitShareRules.endingOnLive([recordedNowHigher], percent: 9, at: now), [recordedNowHigher],
            "neither newer nor higher"
        )
        XCTAssertEqual(
            LimitShareRules.endingOnLive([LimitReading(time: now, percent: 7)], percent: 104, at: now),
            [LimitReading(time: now, percent: 7), LimitReading(time: now, percent: 100)],
            "higher at the same instant; clamped like every reading"
        )
    }

    // MARK: - A held drop inside the current window

    func testAnOldWindowsReadingStampedAfterTheWindowsStartIsLeftToTheOldWindow() throws {
        // `resetsAt` is rounded to the second and the poll's clock differs: the old
        // session's last 43 % is stamped a second after the computed start, and the
        // drop to 0 is seen a minute later.
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let start = request.period.start
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: start.addingTimeInterval(1), percent: 43),
            (at: start.addingTimeInterval(64), percent: 0),
            (at: start.addingTimeInterval(20 * 60), percent: 3),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(5 * 60), chat: "chat-a", cost: 2),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 9, "the live bucket's 9 %, not the old window's 43")
        XCTAssertEqual(share.chats.first?.points ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 6, accuracy: 1e-9, "the live 9 % moved the last half hour, where no local turn ran")
    }

    func testALimitRestoredMidWeekRestartsTheWindowsReadingsAtTheRestore() throws {
        // The weekly percent falls from 94 to 36 with `resetsAt` unchanged, and stays
        // down: the readings before the restore are no longer the window's.
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let start = request.period.start
        let readings = Fixture.readings(bucketID: "seven_day", points: [
            (at: start.addingTimeInterval(1 * day), percent: 30),
            (at: start.addingTimeInterval(2 * day), percent: 94),
            (at: start.addingTimeInterval(3 * day), percent: 36),
            (at: start.addingTimeInterval(4 * day), percent: 38),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(2 * day - 10 * 60), chat: "chat-before", cost: 5),
            Fixture.turnCost(at: start.addingTimeInterval(4 * day - 10 * 60), chat: "chat-after", cost: 5),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 40, "the live bucket's 40 %, not the 94 held before the restore")
        XCTAssertEqual(share.chats.reduce(0) { $0 + $1.points } + share.outside, 40, accuracy: 1e-9)
        XCTAssertEqual(
            share.chats.first { $0.id == "chat-before" }?.points ?? -1, 0, accuracy: 1e-9,
            "its percent rose before the restore, in readings the window no longer counts"
        )
        XCTAssertEqual(share.chats.first { $0.id == "chat-after" }?.points ?? -1, 2, accuracy: 1e-9)
    }

    func testAnOldWindowsReadingExactlyOnTheWindowsStartIsLeftToTheOldWindow() throws {
        // The old session's 43 % is stamped on the computed start itself, and the drop
        // holds from the next reading on.
        let request = try XCTUnwrap(
            LimitShareRules.request(for: claudeMax, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let start = request.period.start
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: start, percent: 43),
            (at: start.addingTimeInterval(64), percent: 0),
            (at: start.addingTimeInterval(20 * 60), percent: 3),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(5 * 60), chat: "chat-a", cost: 2),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 9)
        XCTAssertEqual(share.chats.first?.points ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 6, accuracy: 1e-9)
    }

    func testAPayAsYouGoShareIsEachChatsPartOfTheWeeksSpend() throws {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400)
        let request = try XCTUnwrap(
            LimitShareRules.request(for: api, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-2 * day), chat: "chat-a", cost: 100),
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-b", cost: 300),
            Fixture.turnCost(at: now.addingTimeInterval(-8 * day), chat: "chat-old", cost: 1_000),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(share.chats.map(\.id), ["chat-b", "chat-a"], "the chat from 8 days ago is outside the period")
        XCTAssertEqual(share.chats.map(\.points), [75, 25])
        XCTAssertEqual(share.outside, 0)
        XCTAssertNil(share.price)
    }

    func testASpendLimitShareCountsTheServersOtherSpendAsOutside() throws {
        let request = try XCTUnwrap(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc)
        )
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 1_000),
            // 31 August: last month.
            Fixture.turnCost(at: now.addingTimeInterval(-6 * day), chat: "chat-august", cost: 500),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(share.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(share.chats.first?.points ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 12, accuracy: 1e-9, "$1,240 the server counted minus this Mac's $1,000, of $2,000")
        XCTAssertEqual(share.percent, 62, accuracy: 1e-9)
    }
}
