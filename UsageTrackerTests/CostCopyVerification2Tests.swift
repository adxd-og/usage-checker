import XCTest
@testable import Omelette

/// Independent verification of `CostCopy.apiEquivalentCaption(for:)`, derived from
/// `docs/superpowers/specs/2026-09-24-2.7.0-hardening.md` § Design "Agents, CLI,
/// scripts (report C)" and the plan's Self-Review row "`CostCopy.apiEquivalentCaption
/// (for: ServiceSnapshot?)` ... nil for pay-as-you-go, non-nil for a provider missing
/// from the snapshot". Not from `CostCopyTests`. Focus: the `nil`-service branch is
/// exercised on its own (a disabled or not-yet-polled provider), and that the two
/// `apiEquivalentCaption` overloads (`isPayAsYouGo:` and `for:`) agree for every
/// pay-as-you-go service passed through either one.
final class CostCopyVerification2Tests: XCTestCase {
    private func subscription() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "codex_5h", label: "Session", percent: 5, kind: .session)],
            weekCost: 6.5
        )
    }

    private func payAsYouGo() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [], weekCost: 200)
    }

    /// A provider absent from the current snapshot — disabled, or the app has not
    /// polled it yet — is not *known* to be pay-as-you-go, so the caption still shows:
    /// saying "API-equivalent" of what turns out to be a real bill is the smaller
    /// error.
    func testANilServiceGetsTheCaption() {
        XCTAssertEqual(CostCopy.apiEquivalentCaption(for: nil), CostCopy.apiEquivalent)
    }

    func testASubscriptionServiceGetsTheCaption() {
        XCTAssertEqual(CostCopy.apiEquivalentCaption(for: subscription()), CostCopy.apiEquivalent)
    }

    func testAPayAsYouGoServiceGetsNoCaption() {
        XCTAssertNil(CostCopy.apiEquivalentCaption(for: payAsYouGo()))
    }

    /// The two overloads must agree: `for:` is documented as wrapping
    /// `isPayAsYouGo:`, not a second, independently-drifting rule.
    func testTheForOverloadAgreesWithTheIsPayAsYouGoOverload() {
        let payg = payAsYouGo()
        XCTAssertEqual(
            CostCopy.apiEquivalentCaption(for: payg),
            CostCopy.apiEquivalentCaption(isPayAsYouGo: CostCopy.isPayAsYouGo(payg))
        )
        let sub = subscription()
        XCTAssertEqual(
            CostCopy.apiEquivalentCaption(for: sub),
            CostCopy.apiEquivalentCaption(isPayAsYouGo: CostCopy.isPayAsYouGo(sub))
        )
    }

    /// A synthetic budget bucket (the only kind a pay-as-you-go account can carry, per
    /// `AppState.applyPayAsYouGo`) must still read as pay-as-you-go, not as a
    /// subscription with one window.
    func testASyntheticBudgetBucketAloneStillReadsAsPayAsYouGo() {
        let synthetic = Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "claude_weekly_budget", label: "Budget", percent: 40)]
        )
        XCTAssertTrue(CostCopy.isPayAsYouGo(synthetic))
        XCTAssertNil(CostCopy.apiEquivalentCaption(for: synthetic))
    }
}
