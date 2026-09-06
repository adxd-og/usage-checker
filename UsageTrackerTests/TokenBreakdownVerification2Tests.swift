import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `TokenBreakdown`'s saturating arithmetic (item 10 of the batch brief).
///
/// The executor's own `TokenBreakdownTests.swift` only exercises `+`/`cacheWrite`/
/// `total` on a `TokenBreakdown` whose every field is *already* `Int.max` (produced
/// by summing two breakdowns that were each field-wise saturated first) — every
/// addition `saturating` sees there is `.max + .max`, which trivially clamps. These
/// tests instead construct breakdowns with `.max` directly in a subset of fields
/// (exercising `total`'s five-value `reduce` chain on a value nothing has summed
/// yet) and drive `+=` in a loop the way the real aggregators
/// (`GrokUsageAggregator`, `JSONLAggregator`) actually call it.
final class TokenBreakdownVerification2Tests: XCTestCase {
    func testTotalClampsWhenConstructedDirectlyWithFiveMaxBuckets() {
        // `total` folds [output, cacheRead, cacheWrite5m, cacheWrite1h] into `input`
        // via `reduce`. Built directly (no `+` involved), this exercises that fold
        // itself rather than a value some other saturating add already clamped.
        let breakdown = TokenBreakdown(
            input: .max, output: .max, cacheRead: .max, cacheWrite5m: .max, cacheWrite1h: .max, thinking: 0
        )
        XCTAssertEqual(breakdown.total, .max)
    }

    func testTotalClampsWithOnlyOneOfTheFiveBucketsAtMax() {
        // The other four are small, ordinary numbers — the overflow has to come from
        // the single `.max` value meeting *any* one of them partway through the fold,
        // not from every operand already being saturated.
        let breakdown = TokenBreakdown(input: .max, output: 100, cacheRead: 100, cacheWrite5m: 100, cacheWrite1h: 100)
        XCTAssertEqual(breakdown.total, .max)
    }

    func testCacheWriteClampsWhenConstructedDirectly() {
        let breakdown = TokenBreakdown(cacheWrite5m: .max, cacheWrite1h: 1)
        XCTAssertEqual(breakdown.cacheWrite, .max)
    }

    func testRepeatedPlusEqualsInALoopClampsRatherThanWrappingNegative() {
        // The real call sites (`GrokUsageAggregator.swift:123`, `JSONLAggregator.swift:284`)
        // accumulate turn by turn with `+=` inside a loop, never via one big `+`. A
        // wraparound bug that only shows up after *several* additions past the
        // boundary — rather than in the single addition that first crosses it — would
        // not be caught by a test that only ever adds two values together once.
        var running = TokenBreakdown(input: Int.max - 5)
        for _ in 0..<10 {
            running += TokenBreakdown(input: 3)
        }
        XCTAssertEqual(running.input, .max, "must clamp at the ceiling, never wrap around to a negative total")
        XCTAssertGreaterThanOrEqual(running.total, 0, "a wrapped-negative total reads as impossible usage on screen")
    }

    func testSaturatingWithANegativeRHSStillClampsDownwardNotUp() {
        // `saturating` isn't only reachable with positive operands — a corrupt log
        // line could carry a negative counter. Overflowing downward must clamp to
        // `.min`, not silently flip back toward `.max`.
        XCTAssertEqual(TokenBreakdown.saturating(.min, -1), .min)
    }

    func testSaturatingExactlyAtTheBoundaryDoesNotClampWhenItDoesNotHaveTo() {
        // One below the ceiling plus one lands exactly on `.max` without overflow —
        // this must be the honest sum, not a clamp masking an off-by-one in the
        // overflow check itself.
        XCTAssertEqual(TokenBreakdown.saturating(Int.max - 1, 1), .max)
        XCTAssertEqual(TokenBreakdown.saturating(Int.max - 2, 1), Int.max - 1, "no overflow here at all; must not over-clamp")
    }
}
