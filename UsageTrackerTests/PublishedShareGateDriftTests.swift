import XCTest
@testable import Omelette

/// The last gate on the published shares: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Published data and § Accounts without percent windows. A share is written only next
/// to the window it was cut for. Claude reports a window's reset a second either side of
/// the whole minute from poll to poll (09:59:59 next to 10:00:00 in the history), so a
/// reset within `LimitShareRules.resetDrift` is the same window. A budget share is cut
/// against the weekly budget or the monthly spend limit: once that changes, the share is
/// not the file's until it is cut again.
final class PublishedShareGateDriftTests: XCTestCase {
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

    private var sessionReset: Date { now.addingTimeInterval(hour) }
    private var weekReset: Date { now.addingTimeInterval(2 * day) }

    private func claudeMax(sessionReset: Date, weekReset: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: sessionReset, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: weekReset, kind: .weekly),
        ], at: now)
    }

    private func payAsYouGo() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400, at: now)
    }

    private func spendLimit(monthlyLimit: Double, usedCredits: Double) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(
                isEnabled: true, monthlyLimit: monthlyLimit, usedCredits: usedCredits,
                utilization: usedCredits * 100 / monthlyLimit
            ),
            at: now
        )
    }

    private func sources(_ log: TurnCostLog, readings: [HistoryRecord] = []) -> PublishedShareRules.Sources {
        PublishedShareRules.Sources(turns: { _, _ in log }, readings: { _ in readings })
    }

    /// The shares a poll cut for `service`, as `StatusCosts` gathers them.
    private func gathered(
        for service: ServiceSnapshot, budget: Double = 0, log: TurnCostLog, readings: [HistoryRecord] = []
    ) async -> PublishedShares {
        await PublishedShareRules.shares(
            for: service, weeklyBudgetUSD: budget, now: now, calendar: utc, sources: sources(log, readings: readings)
        )
    }

    private func current(_ shares: PublishedShares, for service: ServiceSnapshot, budget: Double = 0) -> [String: ChatShareFields] {
        PublishedShareRules.current(shares, for: service, weeklyBudgetUSD: budget, now: now, calendar: utc)
    }

    // MARK: - A reset that drifts

    private var subscriptionShares: PublishedShares {
        get async {
            await gathered(
                for: claudeMax(sessionReset: sessionReset, weekReset: weekReset),
                log: TurnCostLog(turns: [
                    Fixture.turnCost(at: now.addingTimeInterval(-235 * minute), chat: "chat-a", cost: 2),
                ]),
                readings: Fixture.readings(bucketID: "five_hour", points: [
                    (at: now.addingTimeInterval(-4 * hour + 20 * minute), percent: 5),
                ]) + Fixture.readings(bucketID: "seven_day", points: [
                    (at: now.addingTimeInterval(-4 * hour + 20 * minute), percent: 35),
                ])
            )
        }
    }

    func testTheSharesSurviveAResetReportedASecondEarlier() async throws {
        let shares = await subscriptionShares
        let asCut = current(shares, for: claudeMax(sessionReset: sessionReset, weekReset: weekReset))
        let chat = try XCTUnwrap(asCut["chat-a"])
        XCTAssertNotNil(chat.sessionShare)
        XCTAssertNotNil(chat.weekShare)

        let drifted = claudeMax(sessionReset: sessionReset.addingTimeInterval(-1), weekReset: weekReset.addingTimeInterval(-1))

        XCTAssertEqual(current(shares, for: drifted), asCut, "09:59:59 next to 10:00:00 is one window")
        let later = claudeMax(sessionReset: sessionReset.addingTimeInterval(1), weekReset: weekReset.addingTimeInterval(2))
        XCTAssertEqual(current(shares, for: later), asCut)
    }

    func testAShareOfAWindowThatGaveWayToTheNextIsDropped() async throws {
        let shares = await subscriptionShares
        let nextSession = claudeMax(sessionReset: sessionReset.addingTimeInterval(5 * hour), weekReset: weekReset)

        let chat = try XCTUnwrap(current(shares, for: nextSession)["chat-a"])

        XCTAssertNil(chat.sessionShare, "another session's reset is another window")
        XCTAssertNotNil(chat.weekShare)
    }

    // MARK: - The budget a share was cut against

    func testABudgetShareIsDroppedOnceTheWeeklyBudgetChanges() async throws {
        let shares = await gathered(
            for: payAsYouGo(), budget: 100,
            log: TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-d", cost: 50)])
        )
        XCTAssertEqual(current(shares, for: payAsYouGo(), budget: 100)["chat-d"]?.budgetShare, 50)

        XCTAssertNil(
            current(shares, for: payAsYouGo(), budget: 200)["chat-d"]?.budgetShare,
            "50 % of $100 is not the chat's share of $200"
        )
    }

    func testASpendLimitShareIsDroppedOnceTheLimitChangesButNotAsCreditsAreUsed() async throws {
        let shares = await gathered(
            for: spendLimit(monthlyLimit: 2_000, usedCredits: 500),
            log: TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-e", cost: 100)])
        )
        XCTAssertEqual(
            current(shares, for: spendLimit(monthlyLimit: 2_000, usedCredits: 650))["chat-e"]?.budgetShare, 5,
            "used credits move with every poll"
        )

        XCTAssertNil(current(shares, for: spendLimit(monthlyLimit: 4_000, usedCredits: 650))["chat-e"]?.budgetShare)
    }
}
