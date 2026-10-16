import XCTest
@testable import Omelette

/// Which page the Limits tab shows, at the edges: limit-analytics spec (2026-10-16) § The
/// tab (the empty state, the window switch) and § Accounts without percent windows (the
/// three modes). A share is shown only for the query asked now; "Nothing spent" only on
/// pay as you go, once the dashboard answered this very query with no share.
final class LimitsPageVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    /// 2026-09-01 00:00 UTC.
    private let september = Date(timeIntervalSince1970: 1_788_220_800)

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func payAsYouGoService(id: String = "claude") -> ServiceSnapshot {
        Fixture.snapshot(id: id, plan: nil, buckets: [], weekCost: 0)
    }

    private func spendLimitService(limit: Double = 2_000) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: limit, usedCredits: 1_240, utilization: 62),
            weekCost: 300
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

    private func page(
        _ service: ServiceSnapshot?,
        serviceID: String = "claude",
        kind: BucketKind = .weekly,
        budget: Double = 0,
        load: DashboardState.LimitShareLoad? = nil,
        answered: LimitsQuery? = nil,
        at time: Date? = nil
    ) -> LimitsPage {
        LimitsRules.page(
            serviceID: serviceID, kind: kind, service: service, weeklyBudgetUSD: budget,
            load: load, answered: answered, now: time ?? now, calendar: utc
        )
    }

    private func query(
        _ service: ServiceSnapshot?, serviceID: String = "claude", kind: BucketKind = .weekly,
        budget: Double = 0, at time: Date? = nil
    ) -> LimitsQuery {
        LimitsRules.query(
            serviceID: serviceID, service: service, kind: kind, weeklyBudgetUSD: budget,
            now: time ?? now, calendar: utc
        )
    }

    private func sevenDays(chats: [ChatShare] = []) -> LimitShare {
        Fixture.limitShare(window: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now), chats: chats)
    }

    // MARK: - A stale answer from another provider

    func testAShareLoadedForCodexIsNotClaudesWhenTheirPeriodsMatch() {
        let codexLoad = Fixture.limitLoad(serviceID: "codex", mode: .payAsYouGo(weeklyBudget: nil), share: sevenDays())
        XCTAssertEqual(page(payAsYouGoService(), load: codexLoad), .loading)
    }

    func testNothingSpentIsNotClaimedFromAnotherProvidersAnswer() {
        let codexAnswer = query(payAsYouGoService(id: "codex"), serviceID: "codex")
        XCTAssertEqual(page(payAsYouGoService(), answered: codexAnswer), .loading)
        XCTAssertEqual(page(payAsYouGoService(id: "codex"), serviceID: "codex", answered: codexAnswer), .noSpend)
    }

    // MARK: - A budget changing, or set to 0

    func testRemovingTheBudgetDropsTheShareMeasuredAgainstIt() {
        let against500 = Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: 500), share: sevenDays(
            chats: [Fixture.chatShare(id: "chat-a", points: 82.4, cost: 412, lastAt: now)]
        ))
        XCTAssertEqual(page(payAsYouGoService(), budget: 500, load: against500), .ready(against500))
        XCTAssertEqual(page(payAsYouGoService(), budget: 0, load: against500), .loading)
    }

    func testNothingSpentOutranksAShareLeftOverFromTheBudgetSetBefore() {
        let against500 = Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: 500), share: sevenDays())
        let answeredWithoutBudget = query(payAsYouGoService(), budget: 0)
        XCTAssertEqual(page(payAsYouGoService(), budget: 0, load: against500, answered: answeredWithoutBudget), .noSpend)
    }

    func testSettingABudgetTurnsNothingSpentBackIntoLoading() {
        let answeredWithoutBudget = query(payAsYouGoService(), budget: 0)
        XCTAssertEqual(page(payAsYouGoService(), budget: 0, answered: answeredWithoutBudget), .noSpend)
        XCTAssertEqual(page(payAsYouGoService(), budget: 500, answered: answeredWithoutBudget), .loading)
    }

    func testAShareThatAnsweredTheQueryBeatsAnAnswerOfNothingSpent() {
        let load = Fixture.limitLoad(mode: .payAsYouGo(weeklyBudget: nil), share: sevenDays(
            chats: [Fixture.chatShare(id: "chat-a", points: 100, cost: 12, lastAt: now)]
        ))
        XCTAssertEqual(
            page(payAsYouGoService(), load: load, answered: query(payAsYouGoService())), .ready(load)
        )
    }

    func testACodexBudgetIsNeverLookedAtSoItsPageDoesNotWaitOnOne() {
        let codex = payAsYouGoService(id: "codex")
        let answered = query(codex, serviceID: "codex", budget: 0)
        XCTAssertEqual(page(codex, serviceID: "codex", budget: 500, answered: answered), .noSpend)
    }

    // MARK: - Where "Nothing spent" is never said

    func testASpendLimitWithNoShareYetIsLoadingNeverNothingSpent() {
        let team = spendLimitService()
        XCTAssertEqual(page(team, answered: query(team)), .loading)
    }

    func testASubscriptionWithNoShareYetIsLoadingNeverNothingSpent() {
        XCTAssertEqual(page(claudeMax, answered: query(claudeMax)), .loading)
        XCTAssertEqual(page(claudeMax, kind: .session, answered: query(claudeMax, kind: .session)), .loading)
    }

    // MARK: - A spend limit's month

    func testLastMonthsShareIsNotThisMonths() {
        let team = spendLimitService()
        let august = Fixture.limitLoad(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_900),
            share: Fixture.limitShare(window: LimitWindow(
                start: september.addingTimeInterval(-31 * day), end: september.addingTimeInterval(-1)
            ))
        )
        XCTAssertEqual(page(team, load: august), .loading)
    }

    func testThisMonthsShareIsShownWhateverTheCreditsHaveReachedSince() {
        let team = spendLimitService()
        let load = Fixture.limitLoad(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_000),
            share: Fixture.limitShare(window: LimitWindow(start: september, end: now.addingTimeInterval(-3_600)))
        )
        XCTAssertEqual(page(team, load: load), .ready(load), "the snapshot says $1,240 now; the same month")
    }

    func testAShareAgainstAnotherLimitIsLoadingAgain() {
        let load = Fixture.limitLoad(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_000),
            share: Fixture.limitShare(window: LimitWindow(start: september, end: now))
        )
        XCTAssertEqual(page(spendLimitService(limit: 3_000), load: load), .loading)
    }

    func testTheSecondAMonthTurnsTheShareOnScreenIsLoadingNotLastMonths() {
        let team = spendLimitService()
        let september = Fixture.limitLoad(
            mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_900),
            share: Fixture.limitShare(window: LimitWindow(start: self.september, end: now))
        )
        let october = Date(timeIntervalSince1970: 1_790_812_800)
        XCTAssertEqual(page(team, load: september, at: october.addingTimeInterval(-1)), .ready(september))
        XCTAssertEqual(page(team, load: september, at: october.addingTimeInterval(1)), .loading)
    }

    // MARK: - Codex Free's month

    func testCodexFreesMonthHasItsOwnWordWhenNoWindowIsOpen() {
        let monthly = Fixture.bucket(id: "codex_session", label: "Monthly", percent: 4, kind: .weekly,
                                     windowLength: 30 * day)
        let codexFree = Fixture.snapshot(id: "codex", plan: "Free", buckets: [monthly])
        XCTAssertEqual(page(codexFree, serviceID: "codex"), .noOpenWindow(.month))
    }

    func testAWeeklyKindWindowIsAMonthOnlyPastEightDays() {
        func span(_ length: TimeInterval) -> LimitsSpan {
            let bucket = Fixture.bucket(id: "codex_session", percent: 4, resetsAt: now.addingTimeInterval(day),
                                        kind: .weekly, windowLength: length)
            return LimitsRules.span(of: .weekly, in: Fixture.snapshot(id: "codex", plan: "Plus", buckets: [bucket]))
        }
        XCTAssertEqual(span(7 * day), .week)
        XCTAssertEqual(span(8 * day), .week, "a day of slack over seven")
        XCTAssertEqual(span(8 * day + 1), .month)
        XCTAssertEqual(span(30 * day), .month)
    }

    func testASessionIsASessionWhateverItsLength() {
        let bucket = Fixture.bucket(id: "codex_primary", percent: 4, resetsAt: now.addingTimeInterval(day),
                                    kind: .session, windowLength: 30 * day)
        XCTAssertEqual(
            LimitsRules.span(of: .session, in: Fixture.snapshot(id: "codex", plan: "Plus", buckets: [bucket])), .session
        )
    }

    // MARK: - Order of the checks

    func testAProviderWithoutAChatLogIsUnsupportedBeforeAnythingElseIsAsked() {
        XCTAssertEqual(page(claudeMax, serviceID: "grok"), .unsupported)
        XCTAssertEqual(page(claudeMax, serviceID: "antigravity"), .unsupported)
        XCTAssertEqual(page(nil, serviceID: "cursor"), .unsupported)
    }

    func testASessionWindowThatIsOpenButHasNoLoadIsLoadingAndAWeekNotYetOpenIsNot() {
        let weekNotOpen = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", percent: 9, resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", percent: 0, kind: .weekly),
        ])
        XCTAssertEqual(page(weekNotOpen, kind: .session), .loading)
        XCTAssertEqual(page(weekNotOpen, kind: .weekly), .noOpenWindow(.week))
    }
}
