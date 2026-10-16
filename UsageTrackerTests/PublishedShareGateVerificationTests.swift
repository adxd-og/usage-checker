import XCTest
@testable import Omelette

/// The last gate, through the real `StatusFileWriter.build`: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data and
/// § Accounts without percent windows. A share is written only next to the window it was
/// cut for (the same key and the same reset, the reset still ahead). Also the order in
/// which a poll's gather may be applied.
final class PublishedShareGateVerificationTests: XCTestCase {
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

    /// 2026-10-01 00:00:00 UTC and 2026-11-01 00:00:00 UTC.
    private let octoberStart = Date(timeIntervalSince1970: 1_790_812_800)
    private let novemberStart = Date(timeIntervalSince1970: 1_793_491_200)

    private let chats: [SessionSummary] = [
        SessionFixture.simple(id: "s1", hoursAgo: 1, cost: 10),
        SessionFixture.simple(id: "s2", hoursAgo: 2, cost: 5),
    ]

    private func claudeMax(sessionReset: Date, weekReset: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: sessionReset, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: weekReset, kind: .weekly),
        ], at: now)
    }

    private func sessionWindow(_ reset: Date) -> PublishedShareWindow {
        PublishedShareWindow(field: .session, resetsAt: reset)
    }

    private func weekWindow(_ reset: Date) -> PublishedShareWindow {
        PublishedShareWindow(field: .week, resetsAt: reset)
    }

    private func build(
        services: [ServiceSnapshot],
        shares: [String: PublishedShares],
        at time: Date? = nil,
        budget: Double = 0,
        calendar: Calendar? = nil
    ) -> StatusSnapshot {
        StatusFileWriter.build(
            services: services,
            costs: [:],
            sessions: Dictionary(uniqueKeysWithValues: services.map { service in
                (service.id, chats.map { chat in
                    SessionFixture.simple(id: chat.id, hoursAgo: 1, cost: 1, providerID: service.id)
                })
            }),
            shares: shares,
            weeklyBudgetUSD: budget,
            agents: .none,
            now: time ?? now,
            calendar: calendar ?? SessionFixture.calendar,
            locale: SessionFixture.locale
        )
    }

    private func entry(_ id: String, of provider: String, in file: StatusSnapshot) -> StatusSnapshot.SessionEntry? {
        file.services.first { $0.id == provider }?.sessions?.first { $0.id == id }
    }

    // MARK: - A reset exactly now

    func testASessionWhoseResetIsExactlyNowPublishesNoShareButTheWeekStays() {
        let reset = now
        let week = now.addingTimeInterval(2 * day)
        let shares = PublishedShares(
            windows: [sessionWindow(reset), weekWindow(week)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(services: [claudeMax(sessionReset: reset, weekReset: week)], shares: ["claude": shares])

        XCTAssertNil(entry("s1", of: "claude", in: file)?.sessionShare)
        XCTAssertEqual(entry("s1", of: "claude", in: file)?.weekShare, 12.5)
    }

    func testAShareWrittenAtTheLastInstantBeforeTheResetStillCarriesIt() {
        let reset = now.addingTimeInterval(0.001)
        let week = now.addingTimeInterval(2 * day)
        let shares = PublishedShares(
            windows: [sessionWindow(reset), weekWindow(week)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(services: [claudeMax(sessionReset: reset, weekReset: week)], shares: ["claude": shares])

        XCTAssertEqual(entry("s1", of: "claude", in: file)?.sessionShare, 3.3)
    }

    func testBothWindowsPastDropEveryShareKeyFromTheFile() throws {
        let past = now.addingTimeInterval(-60)
        let shares = PublishedShares(
            windows: [sessionWindow(past), weekWindow(past)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(services: [claudeMax(sessionReset: past, weekReset: past)], shares: ["claude": shares])
        let text = String(decoding: try StatusFile.encoder.encode(file), as: UTF8.self)

        XCTAssertFalse(text.contains("Share"), text)
        XCTAssertEqual(file.services.first?.sessions?.map(\.id).sorted(), ["s1", "s2"], "the chats stay listed")
    }

    // MARK: - A spend limit across the month boundary

    private let spendLimit = ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62)

    private func team() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: "Enterprise", buckets: [], extraUsage: spendLimit, weekCost: 300, at: now)
    }

    private func septemberShares() -> PublishedShares {
        PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: octoberStart)],
            chats: ["s1": ChatShareFields(budgetShare: 1.3)]
        )
    }

    func testASeptemberShareIsWrittenUpToTheLastSecondOfSeptember() {
        let file = build(
            services: [team()], shares: ["claude": septemberShares()],
            at: octoberStart.addingTimeInterval(-1), calendar: utc
        )

        XCTAssertEqual(entry("s1", of: "claude", in: file)?.budgetShare, 1.3)
    }

    func testASeptemberShareIsGoneAtTheFirstInstantOfOctober() {
        let file = build(
            services: [team()], shares: ["claude": septemberShares()], at: octoberStart, calendar: utc
        )

        XCTAssertNil(entry("s1", of: "claude", in: file)?.budgetShare)
    }

    func testASeptemberShareIsGoneASecondIntoOctober() {
        let file = build(
            services: [team()], shares: ["claude": septemberShares()],
            at: octoberStart.addingTimeInterval(1), calendar: utc
        )

        XCTAssertNil(entry("s1", of: "claude", in: file)?.budgetShare, "that month's dollars are not October's")
    }

    func testAnOctoberShareIsWrittenOnceOctoberHasBegunAndNotBefore() {
        let october = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: novemberStart)],
            chats: ["s1": ChatShareFields(budgetShare: 0.4)]
        )

        let early = build(services: [team()], shares: ["claude": october], at: octoberStart.addingTimeInterval(-1), calendar: utc)
        let later = build(services: [team()], shares: ["claude": october], at: octoberStart.addingTimeInterval(1), calendar: utc)

        XCTAssertNil(entry("s1", of: "claude", in: early)?.budgetShare, "cut for a month that has not begun")
        XCTAssertEqual(entry("s1", of: "claude", in: later)?.budgetShare, 0.4)
    }

    // MARK: - The budget amount is not part of the window

    func testChangingTheBudgetAmountDoesNotDropAShareAndClearingItDoes() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400, at: now)
        let shares = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil)],
            chats: ["s1": ChatShareFields(budgetShare: 5)]
        )

        let raised = build(services: [api], shares: ["claude": shares], budget: 1_000)
        let cleared = build(services: [api], shares: ["claude": shares], budget: 0)

        XCTAssertEqual(entry("s1", of: "claude", in: raised)?.budgetShare, 5)
        XCTAssertNil(entry("s1", of: "claude", in: cleared)?.budgetShare)
    }

    func testCodexNeverPublishesABudgetShareEvenIfOneWasHandedToTheWriter() {
        let codexAPI = Fixture.snapshot(id: "codex", plan: nil, buckets: [], weekCost: 80, at: now)
        let shares = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil)],
            chats: ["s1": ChatShareFields(budgetShare: 5)]
        )

        let file = build(services: [codexAPI], shares: ["codex": shares], budget: 500)

        XCTAssertNil(entry("s1", of: "codex", in: file)?.budgetShare, "Codex has no budget setting")
    }

    // MARK: - One live window does not keep another key alive

    func testALiveSessionWindowDoesNotKeepAWeekShareOfAWindowThatIsGone() {
        // The session is current. The week share was cut for a week that resets
        // elsewhere than the week the snapshot reports now.
        let sessionReset = now.addingTimeInterval(hour)
        let shares = PublishedShares(
            windows: [sessionWindow(sessionReset), weekWindow(now.addingTimeInterval(day))],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(
            services: [claudeMax(sessionReset: sessionReset, weekReset: now.addingTimeInterval(2 * day))],
            shares: ["claude": shares]
        )

        XCTAssertEqual(entry("s1", of: "claude", in: file)?.sessionShare, 3.3)
        XCTAssertNil(entry("s1", of: "claude", in: file)?.weekShare)
    }

    func testALiveSessionWindowDoesNotKeepABudgetShareOnASubscription() {
        let sessionReset = now.addingTimeInterval(hour)
        let shares = PublishedShares(
            windows: [sessionWindow(sessionReset), PublishedShareWindow(field: .budget, resetsAt: nil)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, budgetShare: 5)]
        )

        let file = build(
            services: [claudeMax(sessionReset: sessionReset, weekReset: now.addingTimeInterval(2 * day))],
            shares: ["claude": shares], budget: 500
        )

        XCTAssertEqual(entry("s1", of: "claude", in: file)?.sessionShare, 3.3)
        XCTAssertNil(entry("s1", of: "claude", in: file)?.budgetShare, "a subscription has no budget share")
    }

    // MARK: - A mode change

    func testAccountThatGainsWindowsDropsItsBudgetShare() {
        let nowSubscribed = claudeMax(sessionReset: now.addingTimeInterval(hour), weekReset: now.addingTimeInterval(2 * day))
        let shares = PublishedShares(
            windows: [PublishedShareWindow(field: .budget, resetsAt: nil)],
            chats: ["s1": ChatShareFields(budgetShare: 5)]
        )

        let file = build(services: [nowSubscribed], shares: ["claude": shares], budget: 500)

        XCTAssertNil(entry("s1", of: "claude", in: file)?.budgetShare)
    }

    func testSubscriptionSharesAreDroppedWhenTheAccountBecomesASpendLimit() {
        let shares = PublishedShares(
            windows: [sessionWindow(now.addingTimeInterval(hour)), weekWindow(now.addingTimeInterval(2 * day))],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(services: [team()], shares: ["claude": shares], calendar: utc)

        let s1 = entry("s1", of: "claude", in: file)
        XCTAssertNil(s1?.sessionShare)
        XCTAssertNil(s1?.weekShare)
        XCTAssertNil(s1?.budgetShare)
    }

    func testAWeekShareIsKeptWhenOnlyTheSessionWindowIsGone() {
        // The account lost its session lane (a plan change) but keeps the week.
        let week = now.addingTimeInterval(2 * day)
        let weekOnly = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40, resetsAt: week, kind: .weekly),
        ], at: now)
        let shares = PublishedShares(
            windows: [sessionWindow(now.addingTimeInterval(hour)), weekWindow(week)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )

        let file = build(services: [weekOnly], shares: ["claude": shares])

        XCTAssertNil(entry("s1", of: "claude", in: file)?.sessionShare)
        XCTAssertEqual(entry("s1", of: "claude", in: file)?.weekShare, 12.5)
    }

    func testAShareIsKeptOnlyUnderTheKeyItWasCutForWhenTwoWindowsResetTogether() {
        // The session lane is gone and the week resets at the very instant the session
        // share was tagged with. The reset matches; the key does not.
        let reset = now.addingTimeInterval(2 * day)
        let weekOnly = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40, resetsAt: reset, kind: .weekly),
        ], at: now)
        let sessionOnlyShare = PublishedShares(
            windows: [sessionWindow(reset)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3)]
        )

        let file = build(services: [weekOnly], shares: ["claude": sessionOnlyShare])

        XCTAssertNil(entry("s1", of: "claude", in: file)?.sessionShare)
    }

    func testAWeekShareTaggedWithAMonthEndIsNotABudgetShareOfASpendLimitAccount() {
        // A spend limit's budget share is tagged with the month's end; a week share
        // tagged with the same instant belongs to another key.
        let weekShareAtMonthEnd = PublishedShares(
            windows: [weekWindow(octoberStart)],
            chats: ["s1": ChatShareFields(weekShare: 9)]
        )

        let file = build(
            services: [team()], shares: ["claude": weekShareAtMonthEnd],
            at: octoberStart.addingTimeInterval(-60), calendar: utc
        )

        XCTAssertNil(entry("s1", of: "claude", in: file)?.weekShare)
        XCTAssertNil(entry("s1", of: "claude", in: file)?.budgetShare)
    }

    // MARK: - Providers stay apart

    func testASharesWindowTagMatchesOnlyItsOwnProvider() {
        // Codex reports a week that resets at the very instant Claude's does. Claude's
        // shares are published for Claude's chats alone.
        let week = now.addingTimeInterval(2 * day)
        let codex = Fixture.snapshot(id: "codex", buckets: [
            Fixture.bucket(id: "codex_session", label: "Weekly", percent: 10, resetsAt: week,
                           kind: .weekly, windowLength: 10_080 * 60),
        ], at: now)
        let claudeShares = PublishedShares(
            windows: [sessionWindow(now.addingTimeInterval(hour)), weekWindow(week)],
            chats: ["s1": ChatShareFields(sessionShare: 3.3, weekShare: 12.5)]
        )
        let codexShares = PublishedShares(
            windows: [weekWindow(week)],
            chats: ["s1": ChatShareFields(weekShare: 7)]
        )

        let file = build(
            services: [claudeMax(sessionReset: now.addingTimeInterval(hour), weekReset: week), codex],
            shares: ["claude": claudeShares, "codex": codexShares]
        )

        XCTAssertEqual(entry("s1", of: "claude", in: file)?.weekShare, 12.5)
        XCTAssertEqual(entry("s1", of: "codex", in: file)?.weekShare, 7)
        XCTAssertNil(entry("s1", of: "codex", in: file)?.sessionShare)
    }

    func testAServiceWithNoSharesAtAllWritesTheFileItAlwaysDid() throws {
        let with = build(
            services: [claudeMax(sessionReset: now.addingTimeInterval(hour), weekReset: now.addingTimeInterval(2 * day))],
            shares: [:]
        )

        let text = String(decoding: try StatusFile.encoder.encode(with), as: UTF8.self)

        XCTAssertFalse(text.contains("Share"), text)
        XCTAssertEqual(with.version, 2)
    }

    // MARK: - Gather order

    func testOnlyTheNewestPollsGatherIsApplied() {
        XCTAssertTrue(AppState.appliesGather(started: 7, latest: 7))
        XCTAssertFalse(AppState.appliesGather(started: 6, latest: 7))
        XCTAssertFalse(AppState.appliesGather(started: 1, latest: 100))
        XCTAssertFalse(AppState.appliesGather(started: 0, latest: 1))
    }

    func testTheGatherCounterWrappingAroundStillAppliesTheNewestAndDropsTheOlder() {
        // `statusGatherGeneration &+= 1` wraps from Int.max to Int.min.
        XCTAssertTrue(AppState.appliesGather(started: Int.min, latest: Int.min))
        XCTAssertFalse(AppState.appliesGather(started: Int.max, latest: Int.min))
    }
}
