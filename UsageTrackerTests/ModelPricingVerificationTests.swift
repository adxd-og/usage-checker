import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Pricing:
/// "a pricing-table generation number; when it changes, `recentTurns` … are re-priced".
/// This file pins the generation counter's own contract — it moves only on a real
/// change to the live table, and `lookup(for:)` correctly marks a guess versus an
/// exact row — independently of `ModelPricingGenerationTests`/`ModelPricingTableTests`
/// written by the executor.
final class ModelPricingVerificationTests: XCTestCase {
    override func setUpWithError() throws {
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        ModelPricing.updateDynamic([:])
    }

    private let rateA = ModelPrice(
        inputPerM: 1, outputPerM: 2, cacheReadPerM: 0.1, cacheCreate5mPerM: 0.2, cacheCreate1hPerM: 0.3
    )
    private let rateB = ModelPrice(
        inputPerM: 4, outputPerM: 5, cacheReadPerM: 0.4, cacheCreate5mPerM: 0.5, cacheCreate1hPerM: 0.6
    )

    func testTheSameTableSentTwiceLeavesTheGenerationExactlyWhereItWas() {
        ModelPricing.updateDynamic(["m-verify-1": rateA])
        let after1 = ModelPricing.generation

        // A distinct dictionary value, but equal content and different key order —
        // exactly what a second identical fetch would hand back.
        let sameAgain: [String: ModelPrice] = ["m-verify-1": rateA]
        ModelPricing.updateDynamic(sameAgain)

        XCTAssertEqual(ModelPricing.generation, after1, "the same rates again are not a new table")
    }

    func testChangingOneRateAmongManyIsStillACountedChange() {
        ModelPricing.updateDynamic(["m-verify-a": rateA, "m-verify-b": rateA])
        let baseline = ModelPricing.generation

        ModelPricing.updateDynamic(["m-verify-a": rateA, "m-verify-b": rateB])

        XCTAssertEqual(ModelPricing.generation, baseline + 1, "one row moved: a real change")
    }

    func testGoingBackToAnEarlierTableIsACountedChangeToo() {
        ModelPricing.updateDynamic(["m-verify-c": rateA])
        let g1 = ModelPricing.generation
        ModelPricing.updateDynamic(["m-verify-c": rateB])
        let g2 = ModelPricing.generation
        XCTAssertEqual(g2, g1 + 1)

        // Back to the first table's exact content — still a change from what is live now.
        ModelPricing.updateDynamic(["m-verify-c": rateA])
        XCTAssertEqual(ModelPricing.generation, g2 + 1, "the guard compares against the CURRENT table, not history")
    }

    func testEmptyingAPopulatedTableMovesTheGeneration() {
        ModelPricing.updateDynamic(["m-verify-d": rateA])
        let g1 = ModelPricing.generation
        ModelPricing.updateDynamic([:])
        XCTAssertEqual(ModelPricing.generation, g1 + 1)
    }

    func testAnExactOfflineTableRowIsNeverReportedAsAGuess() {
        let lookup = ModelPricing.lookup(for: "claude-sonnet-5")
        XCTAssertFalse(lookup.isFallback, "the offline table names this model exactly")
        XCTAssertEqual(lookup.price.inputPerM, ModelPricing.table["claude-sonnet-5"]!.inputPerM)
    }

    func testAModelNoRowNamesIsAGuessPricedByItsFamily() {
        let lookup = ModelPricing.lookup(for: "claude-haiku-99-preview")
        XCTAssertTrue(lookup.isFallback)
        XCTAssertEqual(lookup.price.inputPerM, ModelPricing.table["claude-haiku-4-5"]!.inputPerM)
    }

    func testALiveTableRowIsNeverAGuessEvenForAModelTheOfflineTableAlsoNames() {
        // "claude-sonnet-5" has an offline row; a live rate for it still must win and
        // still must not be marked a guess — a live answer is never a fallback.
        ModelPricing.updateDynamic(["claude-sonnet-5": rateB])
        let lookup = ModelPricing.lookup(for: "claude-sonnet-5")
        XCTAssertFalse(lookup.isFallback)
        XCTAssertEqual(lookup.price.inputPerM, rateB.inputPerM)
    }

    func testAModelNoFamilyWordMatchesFallsToTheGenericFallbackAndIsStillMarkedAGuess() {
        let lookup = ModelPricing.lookup(for: "some-brand-new-model-9000")
        XCTAssertTrue(lookup.isFallback)
        XCTAssertEqual(lookup.price.inputPerM, ModelPricing.fallback.inputPerM)
    }
}
