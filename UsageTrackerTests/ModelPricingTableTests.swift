import XCTest
@testable import Omelette

/// The static table is what prices a turn whenever models.dev is not there: a first
/// launch offline, a failed fetch, a machine whose cache never landed. Every rate here
/// is checked against the models.dev figures cached on this machine
/// (`~/Library/Application Support/UsageTracker/models-dev-pricing-v3.json`, read
/// 2026-09-06), because an offline answer that differs from the online one is not a
/// fallback, it is a second set of books.
final class ModelPricingTableTests: XCTestCase {
    override func setUpWithError() throws {
        // `price(for:)` prefers the dynamic table; these assertions are about the
        // hardcoded one, so make sure no other test's rates are still loaded.
        ModelPricing.updateDynamic([:])
    }

    /// Fable 5.1 reads cache at $0.25/M, a quarter of Fable 5's $1.00. Cache reads are
    /// the largest bucket of a Claude Code session by an order of magnitude, so falling
    /// through to the Fable 5 row overstated an offline day's spend fourfold on the one
    /// model most of those days are run on.
    func testFableAndMythos51PriceCacheReadsAtAQuarter() {
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1").cacheReadPerM, 0.25)
        XCTAssertEqual(ModelPricing.price(for: "claude-mythos-5-1").cacheReadPerM, 0.25)
    }

    func testFable51CarriesTheWholeRow() {
        let p = ModelPricing.price(for: "claude-fable-5-1")
        XCTAssertEqual(p.inputPerM, 10)
        XCTAssertEqual(p.outputPerM, 50)
        XCTAssertEqual(p.cacheCreate5mPerM, 12.5)
        XCTAssertEqual(p.cacheCreate1hPerM, 20)
    }

    func testFable5IsUnchangedByTheAdditionOfFable51() {
        // The two are separate rows, not one rate that moved: a turn logged under the
        // older id still prices at the older rate.
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5").cacheReadPerM, 1)
    }

    func testSonnet5IsCheaperThanSonnet46AcrossEveryBucket() {
        let p = ModelPricing.price(for: "claude-sonnet-5")
        XCTAssertEqual(p.inputPerM, 2)
        XCTAssertEqual(p.outputPerM, 10)
        XCTAssertEqual(p.cacheReadPerM, 0.2)
        XCTAssertEqual(p.cacheCreate5mPerM, 2.5)
        XCTAssertEqual(p.cacheCreate1hPerM, 4)
    }

    func testOpus5KeepsTheOpus45Rates() {
        let p = ModelPricing.price(for: "claude-opus-5")
        XCTAssertEqual(p.inputPerM, 5)
        XCTAssertEqual(p.outputPerM, 25)
        XCTAssertEqual(p.cacheReadPerM, 0.5)
        XCTAssertEqual(p.cacheCreate5mPerM, 6.25)
        XCTAssertEqual(p.cacheCreate1hPerM, 10)
    }

    func testHaiku45StillMatchesThePublishedRates() {
        let p = ModelPricing.price(for: "claude-haiku-4-5")
        XCTAssertEqual(p.inputPerM, 1)
        XCTAssertEqual(p.outputPerM, 5)
        XCTAssertEqual(p.cacheReadPerM, 0.1)
        XCTAssertEqual(p.cacheCreate5mPerM, 1.25)
        XCTAssertEqual(p.cacheCreate1hPerM, 2)
    }

    /// The ids the logs actually carry: a date stamp, or the long-context tag, on top
    /// of the name. Both normalize away before the lookup, so they must land on the new
    /// rows rather than falling through to the family fallback.
    func testDatedAndLongContextIDsLandOnTheSameRow() {
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1-20260901").cacheReadPerM, 0.25)
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1[1m]").cacheReadPerM, 0.25)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5-20260901").inputPerM, 2)
    }

    func testALiveRateStillWinsOverTheTable() {
        // The table is the fallback, never the override: models.dev remains the answer
        // whenever it has one.
        ModelPricing.updateDynamic([
            "claude-fable-5-1": ModelPrice(
                inputPerM: 99, outputPerM: 99, cacheReadPerM: 99,
                cacheCreate5mPerM: 99, cacheCreate1hPerM: 99
            )
        ])
        XCTAssertEqual(ModelPricing.price(for: "claude-fable-5-1").cacheReadPerM, 99)
        ModelPricing.updateDynamic([:])
    }
}
