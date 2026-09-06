import XCTest
@testable import Omelette

/// Independent verification of `CostCopy` against the 2.4.1 Package 2 spec: "Never
/// [the caption] for a pay-as-you-go account, where the dollars *are* the bill." and
/// `isPayAsYouGo` = "the provider reported no rate-limit window of its own." These
/// cases are not in the executor's `CostCopyTests`.
final class CostCopyVerificationTests: XCTestCase {
    // MARK: - isPayAsYouGo edge cases beyond CostCopyTests

    func testAnUnknownBucketIDAloneReadsAsARealWindowNotPayAsYouGo() {
        // Only "claude_weekly_budget" is a recognised synthetic id (AppState.applyPayAsYouGo).
        // A bucket id that looks like it could be a budget window for some other
        // provider but is not in `syntheticBucketIDs` is treated as a real, provider-
        // reported window — pinning the current, narrow rule rather than a guess.
        let service = Fixture.snapshot(
            id: "grok",
            buckets: [Fixture.bucket(id: "grok_weekly_budget", label: "Weekly budget", percent: 40, kind: .weekly)]
        )
        XCTAssertFalse(CostCopy.isPayAsYouGo(service))
    }

    func testASingleRealWindowAmongManySyntheticStillMeansSubscription() {
        // Order independence: the real window is last, not first (CostCopyTests only
        // exercises synthetic-first).
        let mixed = Fixture.snapshot(
            id: "claude",
            buckets: [
                Fixture.bucket(id: "claude_weekly_budget", percent: 10, kind: .weekly),
                Fixture.bucket(id: "claude_weekly_budget", percent: 20, kind: .weekly),
                Fixture.bucket(id: "five_hour", percent: 5, kind: .session),
            ]
        )
        XCTAssertFalse(CostCopy.isPayAsYouGo(mixed))
    }

    func testOnlyPromotionalOrModelSpecificSyntheticLikeIDsStillFollowTheSameRule() {
        // isPayAsYouGo only inspects bucket ids, never `kind` or `isPromotional` —
        // a synthetic id tagged with an unrelated kind is still synthetic.
        let payg = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "claude_weekly_budget", label: "Weekly budget", percent: 12, kind: .modelSpecific)]
        )
        XCTAssertTrue(CostCopy.isPayAsYouGo(payg))
    }

    func testWeekCostAloneWithNoBucketsIsStillPayAsYouGo() {
        // isPayAsYouGo must key off buckets only — weekCost being present (as it would
        // be for a real Enterprise API account) must not flip the verdict.
        let payg = Fixture.snapshot(id: "claude", buckets: [], weekCost: 128.4)
        XCTAssertTrue(CostCopy.isPayAsYouGo(payg))
        XCTAssertNil(CostCopy.apiEquivalentCaption(isPayAsYouGo: CostCopy.isPayAsYouGo(payg)))
    }

    // MARK: - The caption's exact string, defended against accidental edits

    func testTheCaptionSentenceHasNoTrailingOrLeadingWhitespace() {
        let caption = try! XCTUnwrap(CostCopy.apiEquivalentCaption(isPayAsYouGo: false))
        XCTAssertEqual(caption, caption.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(caption.hasSuffix("."), "the sentence must read as a complete sentence: \(caption)")
    }

    func testTheSuffixIsParenthesizedExactlyOnce() {
        XCTAssertEqual(CostCopy.apiEquivalentSuffix.filter { $0 == "(" }.count, 1)
        XCTAssertEqual(CostCopy.apiEquivalentSuffix.filter { $0 == ")" }.count, 1)
    }
}
