import XCTest
@testable import Omelette

/// Independent verification of `TokenBreakdown`'s arithmetic contract — written without
/// reference to `TokenBreakdownTests`, attacking the corners the spec calls out that a
/// same-author test suite is prone to skip: cost-nil-with-only-one-side-unpriced,
/// zero-context `cacheHitShare`, `priced` against every entry of the static table
/// (fallback included), and the swapped-rate failure mode for `priced(with:)`.
final class TokenBreakdownVerificationTests: XCTestCase {

    // MARK: - `+` cost semantics

    func testCostIsNilWhenOneSideIsUnpricedButCarriesTokens() {
        // Spec: "cost adds only when both sides carry one" — a priced Claude turn plus
        // an unpriced Grok-shaped turn (tokens present, cost nil) must not invent a
        // partial dollar figure by silently treating the unpriced side as zero.
        let priced = TokenBreakdown(input: 1_000_000, output: 100_000).priced(model: "claude-sonnet-4-5")
        let unpricedButNonZero = TokenBreakdown(input: 500_000, output: 50_000) // cost stays nil
        XCTAssertNotEqual(unpricedButNonZero, .zero, "this case is specifically NOT the .zero identity")

        let sum = priced + unpricedButNonZero
        XCTAssertNil(sum.cost, "one side carries real tokens with no known price; the honest sum has no dollars")
        XCTAssertEqual(sum.input, 1_500_000, "the token buckets still add regardless of pricing")

        let reversed = unpricedButNonZero + priced
        XCTAssertNil(reversed.cost)
    }

    func testZeroWithNoCostIsStillTheIdentityAndDoesNotCollideWithAnUnpricedNonZeroSide() {
        // `.zero` (no tokens, no cost) is the identity even though its `cost` is nil,
        // same as an unpriced non-zero breakdown's `cost` — the discriminator has to be
        // "is this side .zero", not "is this side's cost nil".
        let priced = TokenBreakdown(input: 10, output: 10).priced(model: "claude-haiku-4-5")
        XCTAssertEqual((TokenBreakdown.zero + priced).cost, priced.cost)
        XCTAssertEqual((priced + TokenBreakdown.zero).cost, priced.cost)
    }

    func testAccumulatingSeveralUnpricedGrokShapedBreakdownsStaysNil() {
        var acc = TokenBreakdown.zero
        for _ in 0..<3 {
            acc += TokenBreakdown(input: 100, output: 20, cacheRead: 5)
        }
        XCTAssertNil(acc.cost, "repeated accumulation of tokens-with-no-price must never manufacture a cost")
        XCTAssertEqual(acc.input, 300)
    }

    // MARK: - `cacheHitShare` edge cases

    func testCacheHitShareWithOnlyCacheWrites() {
        // input=0, cacheRead=0, cacheWrite>0: context tokens are non-zero (all cache
        // write), but none of it is a cache *read*, so the share must be exactly 0, not nil.
        let b = TokenBreakdown(cacheWrite5m: 200, cacheWrite1h: 50)
        let share = try? XCTUnwrap(b.cacheHitShare)
        XCTAssertEqual(share, 0.0, "cache writes count as context but contribute no hits")
    }

    func testCacheHitShareIsNilForExactlyZeroContext() {
        XCTAssertNil(TokenBreakdown().cacheHitShare)
        XCTAssertNil(TokenBreakdown(thinking: 900).cacheHitShare, "thinking alone is not input-side context either")
    }

    func testCacheHitShareIsOneWhenEverythingWasAHit() {
        let b = TokenBreakdown(cacheRead: 1_000)
        XCTAssertEqual(try XCTUnwrap(b.cacheHitShare), 1.0, accuracy: 1e-12)
    }

    // MARK: - `priced(model:)` against the historical CLITurn.cost formula, every table entry

    /// Reimplements the pre-refactor `CLITurn.cost` formula directly (not by calling
    /// `TokenBreakdown.priced`, so this is a genuine independent check) and compares it,
    /// bucket-summed, to `priced(model:).cost?.total` for every model in the static
    /// pricing table plus the fallback rate.
    private func legacyCost(_ b: TokenBreakdown, model: String) -> Double {
        let p = ModelPricing.price(for: model)
        return (Double(b.input) * p.inputPerM
            + Double(b.output) * p.outputPerM
            + Double(b.cacheRead) * p.cacheReadPerM
            + Double(b.cacheWrite5m) * p.cacheCreate5mPerM
            + Double(b.cacheWrite1h) * p.cacheCreate1hPerM) / 1_000_000.0
    }

    func testPricedMatchesTheLegacyCostFormulaForEveryTableEntry() throws {
        let sample = TokenBreakdown(
            input: 777_777, output: 88_888, cacheRead: 999_999,
            cacheWrite5m: 12_345, cacheWrite1h: 6_789, thinking: 4_000
        )
        for model in ModelPricing.table.keys.sorted() {
            let expected = legacyCost(sample, model: model)
            let cost = try XCTUnwrap(sample.priced(model: model).cost, "model \(model)")
            XCTAssertEqual(cost.total, expected, accuracy: 1e-9, "mismatch for \(model)")
        }
    }

    func testPricedMatchesTheLegacyCostFormulaForTheFallbackRate() throws {
        // A model id present in nobody's table and matching none of the family
        // substrings ("fable"/"mythos"/"opus"/"haiku"/"sonnet") falls through to
        // `ModelPricing.fallback`.
        let unknownModel = "zzz-totally-unrecognized-9000"
        XCTAssertEqual(ModelPricing.price(for: unknownModel).inputPerM, ModelPricing.fallback.inputPerM)

        let sample = TokenBreakdown(input: 500_000, output: 40_000, cacheRead: 20_000, cacheWrite5m: 1_000, cacheWrite1h: 500)
        let expected = legacyCost(sample, model: unknownModel)
        let cost = try XCTUnwrap(sample.priced(model: unknownModel).cost)
        XCTAssertEqual(cost.total, expected, accuracy: 1e-9)
    }

    // MARK: - `priced(with:)` bucket-to-rate mapping (a swapped rate must fail)

    func testPricedWithMapsEachBucketToItsOwnDistinctRateNotASwappedOne() throws {
        // Every rate is a distinct prime-ish value so a bug that swaps, say, output and
        // cacheRead rates produces a detectably wrong number rather than accidentally
        // matching by coincidence.
        let price = ModelPrice(
            inputPerM: 11, outputPerM: 23, cacheReadPerM: 37,
            cacheCreate5mPerM: 53, cacheCreate1hPerM: 71
        )
        let b = TokenBreakdown(
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
            cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000
        )
        let cost = try XCTUnwrap(b.priced(with: price).cost)
        XCTAssertEqual(cost.input, 11, accuracy: 1e-9)
        XCTAssertEqual(cost.output, 23, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheRead, 37, accuracy: 1e-9)
        XCTAssertEqual(cost.cacheWrite, 53 + 71, accuracy: 1e-9, "5m and 1h priced apart, reported together")
        XCTAssertEqual(cost.total, 11 + 23 + 37 + 53 + 71, accuracy: 1e-9)

        // A hand-rolled "swapped" formula (input priced at the output rate, etc.) must
        // NOT match what priced(with:) produced for a breakdown whose buckets carry
        // different magnitudes — with every bucket equal at 1_000_000 above, a swap of
        // two rates leaves the *total* unchanged (same five numbers, added in a
        // different order), so the real regression guard needs unequal quantities.
        let uneven = TokenBreakdown(input: 10, output: 1_000_000, cacheRead: 3, cacheWrite5m: 4, cacheWrite1h: 5)
        let unevenCost = try XCTUnwrap(uneven.priced(with: price).cost)
        let swappedTotal = (Double(uneven.input) * price.outputPerM
            + Double(uneven.output) * price.inputPerM
            + Double(uneven.cacheRead) * price.cacheReadPerM
            + Double(uneven.cacheWrite5m) * price.cacheCreate5mPerM
            + Double(uneven.cacheWrite1h) * price.cacheCreate1hPerM) / 1_000_000.0
        XCTAssertNotEqual(unevenCost.total, swappedTotal, accuracy: 1e-9)
    }

    func testPricedWithASingleNonZeroBucketOnlyAffectsThatDollarColumn() throws {
        let price = ModelPrice(
            inputPerM: 2, outputPerM: 4, cacheReadPerM: 6, cacheCreate5mPerM: 8, cacheCreate1hPerM: 10
        )
        let onlyCacheWrite1h = TokenBreakdown(cacheWrite1h: 1_000_000)
        let cost = try XCTUnwrap(onlyCacheWrite1h.priced(with: price).cost)
        XCTAssertEqual(cost.input, 0)
        XCTAssertEqual(cost.output, 0)
        XCTAssertEqual(cost.cacheRead, 0)
        XCTAssertEqual(cost.cacheWrite, 10, accuracy: 1e-9)
    }

    // MARK: - `total` / `thinking` / `cacheWrite` sanity beyond the primary suite

    func testThinkingOnlyOutputStillCountsTowardTotalViaOutputBucketNotViaThinkingItself() {
        // Spec: thinking is a *subset* of output. A turn that is "thinking-only" in the
        // sense that all its output tokens happen to be thinking must still report those
        // tokens through `output`, and `total` must include them exactly once (via
        // output), not twice (output + thinking).
        let b = TokenBreakdown(output: 50_000, thinking: 50_000)
        XCTAssertEqual(b.total, 50_000, "thinking must not be double-counted into total")
        XCTAssertEqual(b.thinking, 50_000)
    }

    func testCacheWriteCombinesBothTTLsIndependentlyOfEachOther() {
        XCTAssertEqual(TokenBreakdown(cacheWrite5m: 7).cacheWrite, 7)
        XCTAssertEqual(TokenBreakdown(cacheWrite1h: 9).cacheWrite, 9)
        XCTAssertEqual(TokenBreakdown(cacheWrite5m: 7, cacheWrite1h: 9).cacheWrite, 16)
    }

    // MARK: - TokenCategory over an unpriced breakdown

    func testCategoryCostIsNilForEveryCaseWhenTheBreakdownIsUnpriced() {
        let unpriced = TokenBreakdown(input: 1, output: 1, cacheRead: 1, cacheWrite5m: 1, cacheWrite1h: 1)
        for category in TokenCategory.allCases {
            XCTAssertNil(category.cost(in: unpriced))
        }
    }

    // MARK: - TokenFormat boundary values (spec explicitly calls these out)

    func testFormatTokensBoundaries() {
        XCTAssertEqual(TokenFormat.formatTokens(999), "999")
        XCTAssertEqual(TokenFormat.formatTokens(1_000), "1.0k")
        XCTAssertEqual(TokenFormat.formatTokens(999_999), "1000.0k", "999_999 / 1000 rounds to 1000.0, not 1.0M")
        XCTAssertEqual(TokenFormat.formatTokens(1_000_000), "1.0M")
        XCTAssertEqual(TokenFormat.formatTokens(1_549_999), "1.5M")
    }

    func testFormatTokensNegativeInput() {
        // Not really a token count the app should ever produce, but the function must
        // not crash or format nonsensically for it — negative falls through to the
        // plain-integer branch since it is < 1_000.
        XCTAssertEqual(TokenFormat.formatTokens(-5), "-5")
    }
}
