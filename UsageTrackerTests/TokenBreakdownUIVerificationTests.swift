import XCTest
import SwiftUI
@testable import Omelette

/// Independent verification of Package 3 (UI) against
/// docs/superpowers/specs/2026-09-05-token-breakdown-design.md § "UI". These
/// cases target spec sentences the executor's own tests did not pin down:
/// a single non-zero bucket producing exactly one full-width segment, and the
/// caption's rounding behaviour at the 0.5% / 99.6% / 100% boundaries.
final class TokenShareBarSingleCategoryVerificationTests: XCTestCase {
    func testASingleNonZeroCategoryGivesOneSegmentOfOne() {
        let cases: [(TokenBreakdown, TokenCategory)] = [
            (TokenBreakdown(input: 500), .input),
            (TokenBreakdown(output: 500), .output),
            (TokenBreakdown(cacheRead: 500), .cacheRead),
            (TokenBreakdown(cacheWrite5m: 500), .cacheWrite),
            (TokenBreakdown(cacheWrite1h: 500), .cacheWrite),
        ]
        for (b, expectedCategory) in cases {
            let segments = TokenShareBar.segments(b)
            XCTAssertEqual(segments.count, 1, "expected exactly one segment for \(b)")
            XCTAssertEqual(segments.first?.0, expectedCategory)
            XCTAssertEqual(segments.first?.1 ?? -1, 1.0, accuracy: 1e-9)
        }
    }

    func testAllZeroFieldsExplicitlyGivesNoSegments() {
        // Distinct from `.zero` itself: constructed with every bucket spelled
        // out as 0 rather than relying on the default memberwise init.
        let b = TokenBreakdown(input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, thinking: 0)
        XCTAssertTrue(TokenShareBar.segments(b).isEmpty)
    }
}

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
