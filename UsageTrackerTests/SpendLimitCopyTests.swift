import XCTest
@testable import Omelette

/// Issue #1: a spend limit shown as a bare ring percent hides the two numbers the
/// account holder actually needs. `SpendLimitCopy.caption` is the one rule the
/// dashboard hero and the All-tab tile both draw from.
final class SpendLimitCopyTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func extra(
        enabled: Bool = true,
        limit: Double = 1500,
        used: Double = 431.26
    ) -> ExtraUsage {
        ExtraUsage(
            isEnabled: enabled,
            monthlyLimit: limit,
            usedCredits: used,
            utilization: limit > 0 ? used / limit * 100 : 0
        )
    }

    // MARK: - Nothing to say

    func testAnAccountWithoutExtraUsageHasNoCaption() {
        XCTAssertNil(SpendLimitCopy.caption(nil, compact: false, locale: us))
        XCTAssertNil(SpendLimitCopy.caption(nil, compact: true, locale: us))
    }

    func testExtraUsageSwitchedOffHasNoCaption() {
        XCTAssertNil(SpendLimitCopy.caption(extra(enabled: false), compact: false, locale: us))
    }

    func testAZeroLimitHasNothingToCompareAgainst() {
        XCTAssertNil(SpendLimitCopy.caption(extra(limit: 0, used: 0), compact: false, locale: us))
        XCTAssertNil(SpendLimitCopy.caption(extra(limit: -10, used: 0), compact: false, locale: us))
    }

    // MARK: - The two amounts

    func testTheCaptionSpellsTheUsedAmountWithCentsAndTheLimitWithout() {
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(), compact: false, locale: us),
            "$431.26 of $1,500"
        )
    }

    func testTheCompactCaptionDropsTheCentsForATenPointTile() {
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(), compact: true, locale: us),
            "$431 of $1,500"
        )
    }

    func testAFractionOfACentRoundsToTheNearestCent() {
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(used: 431.256), compact: false, locale: us),
            "$431.26 of $1,500"
        )
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(used: 431.256), compact: true, locale: us),
            "$431 of $1,500"
        )
    }

    func testALimitUnderAThousandCarriesNoGroupingSeparator() {
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(limit: 200, used: 120), compact: true, locale: us),
            "$120 of $200"
        )
        // Same pair the long way round: only the used amount gains its cents.
        XCTAssertEqual(
            SpendLimitCopy.caption(extra(limit: 200, used: 120), compact: false, locale: us),
            "$120.00 of $200"
        )
    }

    /// The separators are the locale's, not ours — only the two amounts and the
    /// English "of" are fixed.
    func testAGermanMachineFormatsBothAmountsItsOwnWay() {
        let caption = SpendLimitCopy.caption(extra(), compact: false, locale: Locale(identifier: "de_DE"))
        XCTAssertNotNil(caption)
        XCTAssertTrue(caption?.contains("431,26") == true, "used amount missing from \(caption ?? "nil")")
        XCTAssertTrue(caption?.contains("1.500") == true, "limit missing from \(caption ?? "nil")")
        XCTAssertTrue(caption?.contains(" of ") == true, "separator missing from \(caption ?? "nil")")
    }

    // MARK: - Which bucket the views key on

    /// The hero the dashboard draws for a spend-limit account is the synthetic
    /// bucket `WindowRanking` builds, and it is identified by id — the label
    /// changes with the plan ("Spend limit" vs "Extra usage credits").
    func testTheSpendLimitHeroIsIdentifiedByItsIdNotItsLabel() {
        let service = Fixture.snapshot(
            id: "claude",
            plan: "Enterprise",
            buckets: [],
            extraUsage: extra()
        )
        let hero = WindowRanking.detailHero(for: service)
        XCTAssertEqual(hero?.id, WindowRanking.extraUsageBucketID(for: service))
        XCTAssertEqual(hero?.id, "claude_extra_usage")
        XCTAssertEqual(hero?.label, "Spend limit")
    }

    func testAServiceWithoutExtraUsageNeverProducesThatBucket() {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 30, kind: .session)]
        )
        let hero = WindowRanking.detailHero(for: service)
        XCTAssertEqual(hero?.id, "five_hour")
        XCTAssertNil(SpendLimitCopy.caption(service.extraUsage, compact: false, locale: us))
    }
}
