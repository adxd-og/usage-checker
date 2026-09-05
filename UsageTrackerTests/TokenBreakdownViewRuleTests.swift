import XCTest
import SwiftUI
@testable import Omelette

/// The stacked bar's only decision: which segments exist and how wide each is.
/// A zero bucket must not become a hairline of colour with no row under it.
final class TokenShareBarSegmentTests: XCTestCase {
    func testNoTokensDrawNoSegments() {
        XCTAssertTrue(TokenShareBar.segments(.zero).isEmpty)
    }

    func testEmptyBucketsAreOmittedAndTheRestAreInDisplayOrder() {
        let b = TokenBreakdown(input: 300, output: 100, cacheRead: 600)
        let segments = TokenShareBar.segments(b)
        XCTAssertEqual(segments.map { $0.0 }, [.input, .output, .cacheRead])
        XCTAssertEqual(segments.map { $0.1 }, [0.3, 0.1, 0.6])
    }

    func testCacheWriteIsOneSegmentOverBothLifetimes() {
        // 5m and 1h are separate counters and one bar segment: the user is being
        // told what the tokens were, not how long they were kept.
        let b = TokenBreakdown(input: 200, cacheWrite5m: 600, cacheWrite1h: 200)
        let segments = TokenShareBar.segments(b)
        XCTAssertEqual(segments.map { $0.0 }, [.input, .cacheWrite])
        XCTAssertEqual(segments.map { $0.1 }, [0.2, 0.8])
    }

    func testThinkingDoesNotWidenTheBar() {
        // Thinking is a subset of output; counting it again would push the shares
        // past 1 and shrink every other segment.
        let b = TokenBreakdown(input: 500, output: 500, thinking: 400)
        XCTAssertEqual(TokenShareBar.segments(b).map { $0.1 }, [0.5, 0.5])
    }

    func testTheSharesSumToOne() {
        let b = TokenBreakdown(input: 17, output: 3, cacheRead: 991, cacheWrite5m: 41)
        let sum = TokenShareBar.segments(b).reduce(0.0) { $0 + $1.1 }
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9)
    }
}

/// The palette is a contract with the chart's legend: the History tab pins each
/// category's colour by label, so a colour changing in one place and not the
/// other would silently recolour half the screen.
final class TokenCategoryColorTests: XCTestCase {
    func testEachCategoryHasItsSpecifiedSystemColour() {
        XCTAssertEqual(TokenCategory.input.color, Color.accentColor)
        XCTAssertEqual(TokenCategory.output.color, Color.orange)
        XCTAssertEqual(TokenCategory.cacheRead.color, Color.teal)
        XCTAssertEqual(TokenCategory.cacheWrite.color, Color.purple)
    }

    func testTheFourColoursAreDistinct() {
        let colors = TokenCategory.allCases.map(\.color)
        XCTAssertEqual(Set(colors).count, TokenCategory.allCases.count)
    }
}

/// The card's footer is the one sentence on Overview that interprets rather than
/// reports, so its arithmetic is pinned: the share is of the *context* — input,
/// cache read and cache write — and output must never dilute it.
final class TokensTodayCardCaptionTests: XCTestCase {
    func testNothingOnTheInputSideMeansNoSentence() {
        XCTAssertNil(TokensTodayCard.cacheShareCaption(.zero))
        XCTAssertNil(TokensTodayCard.cacheShareCaption(TokenBreakdown(output: 4_000)))
    }

    func testOutputDoesNotDiluteTheShare() {
        // 600 of the 1_000 context tokens were a cache read. The 9_000 output
        // tokens are not context.
        let b = TokenBreakdown(input: 300, output: 9_000, cacheRead: 600, cacheWrite5m: 100)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "60% of context came from cache")
    }

    func testTheShareIsRoundedNotTruncated() {
        let b = TokenBreakdown(input: 334, cacheRead: 666)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(b), "67% of context came from cache")
    }

    func testAColdCacheStillGetsItsSentence() {
        // "0%" is information — a session that is re-sending its whole context.
        XCTAssertEqual(
            TokensTodayCard.cacheShareCaption(TokenBreakdown(input: 1_000)),
            "0% of context came from cache"
        )
    }
}

/// The mode is persisted under a raw String, so its cases are a storage contract:
/// renaming one silently resets every user's tab to Cost.
final class HistoryChartModeTests: XCTestCase {
    func testTheStoredValuesAreStable() {
        XCTAssertEqual(HistoryChartMode.cost.rawValue, "cost")
        XCTAssertEqual(HistoryChartMode.tokens.rawValue, "tokens")
    }

    func testBothModesAreOfferedInOrderWithCostFirst() {
        // Cost is the default and the question the tab has always answered.
        XCTAssertEqual(HistoryChartMode.allCases, [.cost, .tokens])
    }

    func testTheSegmentsAreLabelledForPeopleNotForStorage() {
        XCTAssertEqual(HistoryChartMode.cost.displayName, "Cost")
        XCTAssertEqual(HistoryChartMode.tokens.displayName, "Tokens")
    }

    func testAnUnknownStoredValueIsNotADecodableMode() {
        // @AppStorage falls back to the default when the raw value no longer
        // parses; this is the assumption that makes that safe.
        XCTAssertNil(HistoryChartMode(rawValue: "spend"))
    }
}
