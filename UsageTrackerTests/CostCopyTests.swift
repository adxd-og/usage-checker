import XCTest
@testable import Omelette

/// The one sentence that keeps Omelette's dollars honest, and the rule that decides
/// who needs to read it. A pay-as-you-go account is billed per token, so its dollars
/// are the bill and the caption would be a lie; a subscription's are not.
final class CostCopyTests: XCTestCase {
    func testASubscriptionGetsTheCaption() {
        XCTAssertEqual(
            CostCopy.apiEquivalentCaption(isPayAsYouGo: false),
            "API-equivalent cost of your CLI usage — not what your subscription bills."
        )
    }

    func testPayAsYouGoGetsNoCaption() {
        XCTAssertNil(CostCopy.apiEquivalentCaption(isPayAsYouGo: true))
    }

    func testTheSuffixIsTheShortFormForANotificationBody() {
        XCTAssertEqual(CostCopy.apiEquivalentSuffix, "(API-equivalent)")
    }

    func testAProviderReportedWindowMeansASubscription() {
        let claude = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ],
            weekCost: 31.7
        )
        XCTAssertFalse(CostCopy.isPayAsYouGo(claude))
    }

    func testNoWindowsAtAllIsPayAsYouGo() {
        // AppState.applyPayAsYouGo reaches this shape: a claude that reported no
        // rate-limit window, with local CLI spend as its only figure.
        let payg = Fixture.snapshot(id: "claude", buckets: [], weekCost: 12.4)
        XCTAssertTrue(CostCopy.isPayAsYouGo(payg))
    }

    func testABudgetWindowOmeletteInventedDoesNotCountAsASubscription() {
        // `claude_weekly_budget` is a window the *user* typed into Settings, not one
        // Anthropic reported — a pay-as-you-go account with a budget is still PAYG.
        let payg = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "claude_weekly_budget", label: "Weekly budget", percent: 62, kind: .weekly)],
            weekCost: 62
        )
        XCTAssertTrue(CostCopy.isPayAsYouGo(payg))
        XCTAssertEqual(CostCopy.syntheticBucketIDs, ["claude_weekly_budget"])
    }

    func testAMixOfSyntheticAndRealWindowsIsASubscription() {
        let mixed = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "claude_weekly_budget", percent: 10, kind: .weekly),
                Fixture.bucket(id: "five_hour", percent: 10, kind: .session),
            ]
        )
        XCTAssertFalse(CostCopy.isPayAsYouGo(mixed))
    }

    /// A dashboard page is about one provider, which may be missing from the snapshot
    /// (disabled, or not polled yet). Overview's rule, shared: an unknown account is
    /// not known to be pay-as-you-go, so it gets the caption.
    func testADashboardPageCaptionsASubscriptionAndAnUnknownProvider() {
        let subscription = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)],
            weekCost: 31.7
        )
        let payg = Fixture.snapshot(id: "claude", buckets: [], weekCost: 12.4)

        XCTAssertEqual(CostCopy.apiEquivalentCaption(for: subscription), CostCopy.apiEquivalent)
        XCTAssertNil(CostCopy.apiEquivalentCaption(for: payg))
        XCTAssertEqual(CostCopy.apiEquivalentCaption(for: nil), CostCopy.apiEquivalent)
    }
}
