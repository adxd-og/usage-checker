import XCTest
@testable import Omelette

/// The Activity page's dollars: the 30/90/365-day cost cards and each day's tooltip
/// carry the API-equivalent caption on a subscription. Spec 2.7.0 § Design, "Agents,
/// CLI, scripts" ("the Activity tooltip gets one caption reusing
/// apiEquivalentCaption"), widened to the cost cards by the session's ruling.
final class ActivityCostCaptionTests: XCTestCase {
    private let costDay = "Sep 6, 2026: $4.20"

    // MARK: - The cost cards

    func testTheCostCardsCarryTheCaptionOnASubscription() {
        XCTAssertEqual(ActivityGridView.statsCaption(isQuota: false, caption: CostCopy.apiEquivalent), CostCopy.apiEquivalent)
    }

    func testQuotaCardsAndPayAsYouGoCardsHaveNoCaption() {
        XCTAssertNil(ActivityGridView.statsCaption(isQuota: true, caption: CostCopy.apiEquivalent), "the quota cards are percentages")
        XCTAssertNil(ActivityGridView.statsCaption(isQuota: false, caption: nil), "pay-as-you-go dollars are the bill")
    }

    // MARK: - The day tooltip

    func testADayWithDollarsOnASubscriptionCarriesTheCaption() {
        XCTAssertEqual(
            ActivityGridView.cellTooltip(costDay, hasReading: true, isQuota: false, caption: CostCopy.apiEquivalent),
            "Sep 6, 2026: $4.20\nAPI-equivalent cost of your CLI usage — not what your subscription bills."
        )
    }

    func testPayAsYouGoKeepsTheTooltipAsBuilt() {
        XCTAssertEqual(ActivityGridView.cellTooltip(costDay, hasReading: true, isQuota: false, caption: nil), costDay)
    }

    func testSquaresWithoutDollarsHaveNothingToQualify() {
        XCTAssertEqual(
            ActivityGridView.cellTooltip("Sep 6, 2026: peak 42% (Session)", hasReading: true, isQuota: true, caption: CostCopy.apiEquivalent),
            "Sep 6, 2026: peak 42% (Session)",
            "a quota square is a percentage"
        )
        XCTAssertEqual(
            ActivityGridView.cellTooltip("Sep 6, 2026: no usage", hasReading: false, isQuota: false, caption: CostCopy.apiEquivalent),
            "Sep 6, 2026: no usage",
            "a day with nothing spent"
        )
        XCTAssertEqual(
            ActivityGridView.cellTooltip("", hasReading: false, isQuota: false, caption: CostCopy.apiEquivalent),
            "",
            "a future square has no tooltip at all"
        )
    }
}
