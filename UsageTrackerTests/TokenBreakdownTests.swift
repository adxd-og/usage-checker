import XCTest
@testable import Omelette

/// The vocabulary every provider's aggregator and every token view speaks. The
/// arithmetic here is the whole contract: five disjoint buckets, thinking as a subset
/// of output, and dollars that only add up when both sides actually carry them.
final class TokenBreakdownTests: XCTestCase {
    private let sample = TokenBreakdown(
        input: 1_000_000, output: 100_000, cacheRead: 2_000_000,
        cacheWrite5m: 300_000, cacheWrite1h: 40_000, thinking: 25_000
    )

    func testTotalSumsTheFiveBucketsAndExcludesThinking() {
        XCTAssertEqual(sample.total, 3_440_000)
        XCTAssertEqual(sample.thinking, 25_000, "thinking rides along; it is never added in")
    }

    func testCacheWriteIsTheTwoTTLsTogether() {
        XCTAssertEqual(sample.cacheWrite, 340_000)
    }

    func testCacheHitShareIsCacheReadOverAllInputSideTokens() throws {
        // 2_000_000 of (1_000_000 + 2_000_000 + 340_000) input-side tokens.
        let share = try XCTUnwrap(sample.cacheHitShare)
        XCTAssertEqual(share, 2_000_000.0 / 3_340_000.0, accuracy: 1e-12)
    }

    func testCacheHitShareIsNilWithoutAnyInputSideTokens() {
        XCTAssertNil(TokenBreakdown.zero.cacheHitShare)
        XCTAssertNil(TokenBreakdown(output: 5_000).cacheHitShare, "output alone is not context")
    }

    func testAdditionIsBucketWise() {
        let sum = sample + sample
        XCTAssertEqual(sum.input, 2_000_000)
        XCTAssertEqual(sum.output, 200_000)
        XCTAssertEqual(sum.cacheRead, 4_000_000)
        XCTAssertEqual(sum.cacheWrite5m, 600_000)
        XCTAssertEqual(sum.cacheWrite1h, 80_000)
        XCTAssertEqual(sum.thinking, 50_000)
        XCTAssertEqual(sum.total, 6_880_000)
    }

    func testPlusEqualsMatchesPlus() {
        var acc = TokenBreakdown.zero
        acc += sample
        acc += sample
        XCTAssertEqual(acc, sample + sample)
    }

    func testCostAddsOnlyWhenBothSidesCarryOne() throws {
        let priced = sample.priced(model: "claude-sonnet-4-5")
        let unpriced = sample // Grok's shape: tokens, no per-category dollars
        XCTAssertNil(unpriced.cost)
        XCTAssertNil((priced + unpriced).cost, "a split we don't know must not be invented")
        XCTAssertNil((unpriced + priced).cost)
        let both = try XCTUnwrap((priced + priced).cost)
        XCTAssertEqual(both.total, (priced.cost?.total ?? 0) * 2, accuracy: 1e-9)
    }

    func testZeroIsTheIdentityIncludingForCost() {
        // Accumulators start at `.zero`; if an empty summand erased the dollars, every
        // aggregated breakdown in the app would come out unpriced.
        let priced = sample.priced(model: "claude-opus-4-5")
        XCTAssertEqual(TokenBreakdown.zero + priced, priced)
        XCTAssertEqual(priced + TokenBreakdown.zero, priced)
        var acc = TokenBreakdown.zero
        acc += priced
        XCTAssertEqual(acc.cost?.total ?? 0, priced.cost?.total ?? -1, accuracy: 1e-12)
    }

    func testPricedMatchesTheTurnCostFormula() throws {
        // The same arithmetic `CLITurn.cost` runs, bucket by bucket instead of in one
        // sum. If these ever disagree the dashboard's dollars stop adding up.
        let model = "claude-sonnet-4-5"
        let p = ModelPricing.price(for: model)
        let expected = (Double(sample.input) * p.inputPerM
            + Double(sample.output) * p.outputPerM
            + Double(sample.cacheRead) * p.cacheReadPerM
            + Double(sample.cacheWrite5m) * p.cacheCreate5mPerM
            + Double(sample.cacheWrite1h) * p.cacheCreate1hPerM) / 1_000_000.0

        let cost = try XCTUnwrap(sample.priced(model: model).cost)
        XCTAssertEqual(cost.total, expected, accuracy: 1e-9)
        XCTAssertEqual(cost.input, Double(sample.input) * p.inputPerM / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.output, Double(sample.output) * p.outputPerM / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, Double(sample.cacheRead) * p.cacheReadPerM / 1_000_000, accuracy: 1e-9)
        // One "cache write" column: the two TTLs are priced apart and shown together.
        XCTAssertEqual(
            cost.cacheWrite,
            (Double(sample.cacheWrite5m) * p.cacheCreate5mPerM
                + Double(sample.cacheWrite1h) * p.cacheCreate1hPerM) / 1_000_000,
            accuracy: 1e-9
        )
    }

    func testPricedWithAnExplicitPriceMatchesPricedByModel() throws {
        // Package 2's path: Codex looks its own rates up (models.dev can answer nil)
        // and hands them in, so the two spellings must produce the same dollars.
        let model = "claude-sonnet-4-5"
        let byModel = try XCTUnwrap(sample.priced(model: model).cost)
        let byPrice = try XCTUnwrap(sample.priced(with: ModelPricing.price(for: model)).cost)
        XCTAssertEqual(byModel, byPrice)
    }

    func testPricingLeavesTheTokensAlone() {
        let priced = sample.priced(model: "claude-sonnet-4-5")
        XCTAssertEqual(priced.total, sample.total)
        XCTAssertEqual(priced.thinking, sample.thinking)
    }

    func testCategoriesAreInDisplayOrderAndReadTheirOwnBucket() {
        XCTAssertEqual(TokenCategory.allCases, [.input, .output, .cacheRead, .cacheWrite])
        XCTAssertEqual(TokenCategory.allCases.map(\.label), ["Input", "Output", "Cache read", "Cache write"])
        XCTAssertEqual(TokenCategory.allCases.map(\.id), ["input", "output", "cacheRead", "cacheWrite"])
        XCTAssertEqual(TokenCategory.input.tokens(in: sample), 1_000_000)
        XCTAssertEqual(TokenCategory.output.tokens(in: sample), 100_000)
        XCTAssertEqual(TokenCategory.cacheRead.tokens(in: sample), 2_000_000)
        XCTAssertEqual(TokenCategory.cacheWrite.tokens(in: sample), 340_000)
    }

    func testCategoryDollarsAreNilWithoutASplitAndSumToTheTotalWithOne() {
        for category in TokenCategory.allCases {
            XCTAssertNil(category.cost(in: sample), "no split, no dollars")
        }
        let priced = sample.priced(model: "claude-sonnet-4-5")
        let parts = TokenCategory.allCases.compactMap { $0.cost(in: priced) }
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts.reduce(0, +), priced.cost?.total ?? 0, accuracy: 1e-9)
    }

    func testFormatTokens() {
        XCTAssertEqual(TokenFormat.formatTokens(0), "0")
        XCTAssertEqual(TokenFormat.formatTokens(999), "999")
        XCTAssertEqual(TokenFormat.formatTokens(1_000), "1.0k")
        XCTAssertEqual(TokenFormat.formatTokens(12_345), "12.3k")
        XCTAssertEqual(TokenFormat.formatTokens(1_500_000), "1.5M")
    }

    func testABreakdownSurvivesACodableRoundTrip() {
        // It is stored per turn and per folded day in the cost cache.
        let priced = sample.priced(model: "claude-opus-4-5")
        let data = try? JSONEncoder().encode(priced)
        let back = data.flatMap { try? JSONDecoder().decode(TokenBreakdown.self, from: $0) }
        XCTAssertEqual(back, priced)
    }
}
