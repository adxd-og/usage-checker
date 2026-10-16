import XCTest
@testable import Omelette

/// The three modes: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Accounts without percent windows, the mode table's When column.
/// - Subscription: a core `.session` or `.weekly` window, not the synthetic budget
///   bucket.
/// - Pay as you go: `CostCopy.isPayAsYouGo`, with the weekly budget when set (Claude
///   only).
/// - Spend limit: no core window, and `extraUsage` on with a monthly limit.
final class LimitModeTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var maxBuckets: [UsageBucket] {
        [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(3_600), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * 86_400), kind: .weekly),
        ]
    }

    private var budgetBucket: UsageBucket {
        Fixture.bucket(id: AppState.payAsYouGoBudgetBucketID, label: "Weekly budget", percent: 82.4, kind: .weekly)
    }

    private let spendLimit = ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62)

    func testAnAccountWithACoreWindowIsASubscription() {
        let claudeMax = Fixture.snapshot(id: "claude", buckets: maxBuckets)
        XCTAssertEqual(LimitShareRules.mode(of: claudeMax, weeklyBudgetUSD: 0), .subscription)
    }

    func testCodexProliteIsASubscriptionOnItsWeekAlone() {
        let weekly = Fixture.bucket(id: "codex_session", label: "Weekly", percent: 10,
                                    resetsAt: now.addingTimeInterval(86_400), kind: .weekly,
                                    windowLength: 10_080 * 60)
        let codex = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [weekly])
        XCTAssertEqual(LimitShareRules.mode(of: codex, weeklyBudgetUSD: 0), .subscription)
    }

    func testExtraUsageOnASubscriptionLeavesItASubscription() {
        let claudeMax = Fixture.snapshot(
            id: "claude", buckets: maxBuckets,
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25)
        )
        XCTAssertEqual(
            LimitShareRules.mode(of: claudeMax, weeklyBudgetUSD: 0), .subscription,
            "overage credits after a window fills are not split by chat"
        )
    }

    func testAClaudeAccountWithoutWindowsIsPayAsYouGoAgainstItsWeeklyBudget() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [budgetBucket], weekCost: 412)
        XCTAssertEqual(LimitShareRules.mode(of: api, weeklyBudgetUSD: 500), .payAsYouGo(weeklyBudget: 500))
    }

    func testWithNoBudgetSetPayAsYouGoHasNone() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 412)
        XCTAssertEqual(LimitShareRules.mode(of: api, weeklyBudgetUSD: 0), .payAsYouGo(weeklyBudget: nil))
    }

    func testCodexHasNoBudgetSetting() {
        let codex = Fixture.snapshot(id: "codex", plan: nil, buckets: [], weekCost: 80)
        XCTAssertEqual(
            LimitShareRules.mode(of: codex, weeklyBudgetUSD: 500), .payAsYouGo(weeklyBudget: nil),
            "the budget is Claude's setting"
        )
    }

    func testAnEnterpriseSpendLimitIsTheSpendLimitModeNotPayAsYouGo() {
        let team = Fixture.snapshot(id: "claude", plan: "Enterprise", buckets: [],
                                    extraUsage: spendLimit, weekCost: 300)
        XCTAssertEqual(
            LimitShareRules.mode(of: team, weeklyBudgetUSD: 0),
            .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240)
        )
        let teamWithBudget = Fixture.snapshot(id: "claude", plan: "Enterprise", buckets: [budgetBucket],
                                              extraUsage: spendLimit, weekCost: 300)
        XCTAssertEqual(
            LimitShareRules.mode(of: teamWithBudget, weeklyBudgetUSD: 500),
            .spendLimit(monthlyLimit: 2_000, usedCredits: 1_240),
            "a budget bucket is no core window, and the spend limit wins over pay as you go"
        )
    }

    func testASpendLimitThatIsSwitchedOffIsPayAsYouGo() {
        let off = ExtraUsage(isEnabled: false, monthlyLimit: 2_000, usedCredits: 0, utilization: 0)
        let team = Fixture.snapshot(id: "claude", plan: "Team", buckets: [], extraUsage: off, weekCost: 300)
        XCTAssertEqual(LimitShareRules.mode(of: team, weeklyBudgetUSD: 0), .payAsYouGo(weeklyBudget: nil))
    }

    func testASignedOutAccountWithNothingToShowHasNoMode() {
        let signedOut = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .notSignedIn)
        XCTAssertNil(LimitShareRules.mode(of: signedOut, weeklyBudgetUSD: 0))
    }
}
