import XCTest
@testable import Omelette

/// Which limit shares `status.json` publishes for a provider's chats: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data
/// (`sessionShare` and `weekShare` of the current windows, in Subscription mode) and
/// § Accounts without percent windows ("in Pay as you go and Spend limit modes the
/// session entries carry `budgetShare` … with no budget nothing is added").
final class PublishedShareRequestTests: XCTestCase {
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

    private func requests(_ service: ServiceSnapshot, budget: Double = 0) -> [PublishedShareRequest] {
        PublishedShareRules.requests(for: service, weeklyBudgetUSD: budget, now: now, calendar: utc)
    }

    func testASubscriptionPublishesItsSessionAndWeekShares() {
        let claudeMax = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
            Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 70,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .modelSpecific),
        ])

        XCTAssertEqual(requests(claudeMax), [
            PublishedShareRequest(
                window: PublishedShareWindow(field: .session, resetsAt: now.addingTimeInterval(hour)),
                request: LimitShareRequest(
                    mode: .subscription,
                    period: LimitWindow(start: now.addingTimeInterval(-4 * hour), end: now),
                    bucketID: "five_hour", livePercent: 9
                )
            ),
            PublishedShareRequest(
                window: PublishedShareWindow(field: .week, resetsAt: now.addingTimeInterval(2 * day)),
                request: LimitShareRequest(
                    mode: .subscription,
                    period: LimitWindow(start: now.addingTimeInterval(-5 * day), end: now),
                    bucketID: "seven_day", livePercent: 40
                )
            ),
        ])
    }

    func testCodexProlitePublishesAWeekShareAlone() {
        let prolite = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [
            Fixture.bucket(id: "codex_session", label: "Weekly", percent: 10,
                           resetsAt: now.addingTimeInterval(day), kind: .weekly,
                           windowLength: 10_080 * 60),
        ])

        XCTAssertEqual(requests(prolite), [
            PublishedShareRequest(
                window: PublishedShareWindow(field: .week, resetsAt: now.addingTimeInterval(day)),
                request: LimitShareRequest(
                    mode: .subscription,
                    period: LimitWindow(start: now.addingTimeInterval(-6 * day), end: now),
                    bucketID: "codex_session", livePercent: 10
                )
            ),
        ])
    }

    func testAWindowWhoseResetHasPassedPublishesNoShareOfIt() {
        // Signed out, and the kept session window reset an hour ago: it is over, and
        // its share would describe a window that is no longer the current one.
        let retained = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 60,
                           resetsAt: now.addingTimeInterval(-hour), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ], state: .notSignedIn)

        XCTAssertEqual(requests(retained).map(\.window.field), [.week])
    }

    func testPayAsYouGoWithABudgetPublishesABudgetShareOfTheLastSevenDays() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [
            Fixture.bucket(id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget",
                           percent: 80, kind: .weekly),
        ], weekCost: 400)

        XCTAssertEqual(requests(api, budget: 500), [
            PublishedShareRequest(
                // The seven days roll: no reset to tag the share with.
                window: PublishedShareWindow(field: .budget, resetsAt: nil, denominatorUSD: 500),
                request: LimitShareRequest(
                    mode: .payAsYouGo(weeklyBudget: 500),
                    period: LimitWindow(start: now.addingTimeInterval(-7 * day), end: now),
                    bucketID: nil, livePercent: nil
                )
            ),
        ])
    }

    func testPayAsYouGoWithoutABudgetPublishesNothing() {
        let claudeAPI = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 400)
        let codexAPI = Fixture.snapshot(id: "codex", plan: nil, buckets: [], weekCost: 50)

        XCTAssertEqual(requests(claudeAPI, budget: 0), [], "a share of the period's own spend is not a budget")
        XCTAssertEqual(requests(codexAPI, budget: 500), [], "Codex has no budget setting")
    }

    func testASpendLimitPublishesABudgetShareOfTheMonthSoFar() {
        let team = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62),
            weekCost: 300
        )

        XCTAssertEqual(requests(team), [
            PublishedShareRequest(
                // The limit starts over on 2026-10-01 00:00 UTC.
                window: PublishedShareWindow(
                    field: .budget, resetsAt: Date(timeIntervalSince1970: 1_790_812_800), denominatorUSD: 2_000
                ),
                request: LimitShareRequest(
                    mode: .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240),
                    // 2026-09-01 00:00 UTC.
                    period: LimitWindow(start: Date(timeIntervalSince1970: 1_788_220_800), end: now),
                    bucketID: nil, livePercent: nil
                )
            ),
        ])
    }

    func testAnAccountWithNothingToMeasurePublishesNothing() {
        let signedOut = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn)

        XCTAssertEqual(requests(signedOut), [])
    }
}
