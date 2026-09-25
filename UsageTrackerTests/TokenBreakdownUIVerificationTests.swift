import XCTest
import SwiftUI
@testable import Omelette

/// Independent verification of Package 3 (UI) against
/// docs/superpowers/specs/2026-09-05-token-breakdown-design.md § "UI". These
/// cases target spec sentences the executor's own tests did not pin down: the
/// caption's rounding behaviour at the 0.5% / 99.6% / 100% boundaries.
final class TokensTodayCardCaptionRoundingVerificationTests: XCTestCase {
    func testHalfAPercentRoundsAwayFromZeroToOnePercent() {
        // 5 of 1000 context tokens from cache = 0.5% exactly; Double.rounded()
        // is toNearestOrAwayFromZero, so this must read "1%", not "0%".
        let b = TokenBreakdown(input: 995, cacheRead: 5)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "1% of context came from cache")
    }

    func testNinetyNinePointSixPercentRoundsUpToOneHundred() {
        let b = TokenBreakdown(input: 4, cacheRead: 996)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "100% of context came from cache")
    }

    func testAllContextFromCacheReadsExactlyOneHundredPercent() {
        let b = TokenBreakdown(cacheRead: 500)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "100% of context came from cache")
    }

    func testCacheWriteAloneCountsAsContextForTheCaption() {
        // cacheHitShare's denominator is input + cacheRead + cacheWrite; a turn
        // that only wrote cache (no read, no fresh input) still has a context
        // size, and the cache-read share of it is legitimately 0%.
        let b = TokenBreakdown(cacheWrite5m: 500)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "0% of context came from cache")
    }
}
