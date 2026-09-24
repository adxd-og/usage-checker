import XCTest
@testable import Omelette

/// The price table's generation: the number the three cost aggregators compare to
/// decide whether their last 31 days need pricing again. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Pricing.
/// The live table is process-global, so every test starts and ends with it empty.
final class ModelPricingGenerationTests: XCTestCase {
    private let rate = ModelPrice(
        inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
        cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
    )

    override func setUpWithError() throws {
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        ModelPricing.updateDynamic([:])
    }

    func testANewLiveTableMovesTheGeneration() {
        let before = ModelPricing.generation
        ModelPricing.updateDynamic(["gpt-5.6": rate])
        XCTAssertEqual(ModelPricing.generation, before + 1)
    }

    func testTheSameTableAgainLeavesTheGenerationAlone() {
        ModelPricing.updateDynamic(["gpt-5.6": rate])
        let loaded = ModelPricing.generation
        ModelPricing.updateDynamic(["gpt-5.6": rate])
        XCTAssertEqual(
            ModelPricing.generation, loaded,
            "a daily refetch that brings the same rates must not re-price a month of turns"
        )
    }

    func testAMovedRateIsANewGeneration() {
        ModelPricing.updateDynamic(["gpt-5.6": rate])
        let loaded = ModelPricing.generation
        ModelPricing.updateDynamic(["gpt-5.6": ModelPrice(
            inputPerM: 2.5, outputPerM: 10, cacheReadPerM: 0.125,
            cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
        )])
        XCTAssertEqual(ModelPricing.generation, loaded + 1)
    }

    func testEmptyingTheTableIsAChangeToo() {
        ModelPricing.updateDynamic(["gpt-5.6": rate])
        let loaded = ModelPricing.generation
        ModelPricing.updateDynamic([:])
        XCTAssertEqual(ModelPricing.generation, loaded + 1)
    }
}
