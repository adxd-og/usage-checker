import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview" ("Tokens today: tokens vs cost bars, 'Tokens by
/// day ›'") and § Tokens (token colours), from `Dashboard-Overview(-Light).dc.html`: two
/// stacked bars, one by count and one by dollars, in the token colours with 2 pt gaps and
/// 3 pt slivers, over a legend of each kind's count, dollars and output's thinking.
final class TokensTodayCardTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    /// The mockup's day.
    private let day = TokenBreakdown(
        input: 21_100, output: 2_100_000, cacheRead: 802_100_000,
        cacheWrite5m: 20_000_000, cacheWrite1h: 0, thinking: 716_600,
        cost: TokenCostBreakdown(input: 0.16, output: 63.40, cacheRead: 304.77, cacheWrite: 174.53)
    )

    func testTheTokensBarSplitsTheCountAndTheCostBarTheDollars() {
        XCTAssertEqual(TokensTodayCard.tokenShares(day), [
            OverviewTokenShare(category: .input, value: 21_100),
            OverviewTokenShare(category: .output, value: 2_100_000),
            OverviewTokenShare(category: .cacheRead, value: 802_100_000),
            OverviewTokenShare(category: .cacheWrite, value: 20_000_000),
        ])
        XCTAssertEqual(TokensTodayCard.costShares(day), [
            OverviewTokenShare(category: .input, value: 0.16),
            OverviewTokenShare(category: .output, value: 63.40),
            OverviewTokenShare(category: .cacheRead, value: 304.77),
            OverviewTokenShare(category: .cacheWrite, value: 174.53),
        ])
    }

    func testAProviderThatPricesATurnWholeHasNoCostBar() {
        XCTAssertNil(TokensTodayCard.costShares(TokenBreakdown(input: 100, output: 50)))
        XCTAssertNil(TokensTodayCard.costShares(TokenBreakdown(input: 100, cost: TokenCostBreakdown())))
    }

    func testAnEmptyKindIsNotDrawn() {
        XCTAssertEqual(TokensTodayCard.tokenShares(TokenBreakdown(output: 10, cacheRead: 30)).map(\.category),
                       [.output, .cacheRead])
    }

    func testSegmentsFillTheBarBetweenTwoPointGaps() {
        let shares = [OverviewTokenShare(category: .input, value: 1), OverviewTokenShare(category: .output, value: 1)]
        XCTAssertEqual(TokensTodayCard.segments(shares, in: 102), [
            OverviewTokenSegment(category: .input, width: 50),
            OverviewTokenSegment(category: .output, width: 50),
        ])
    }

    func testASliverStaysThreePointsWideAndTheRowNeverOverflows() {
        let segments = TokensTodayCard.segments(TokensTodayCard.tokenShares(day), in: 600)
        XCTAssertEqual(segments.map(\.category), [.input, .output, .cacheRead, .cacheWrite])
        XCTAssertTrue(segments.allSatisfy { $0.width >= 3 })
        XCTAssertEqual(segments.reduce(0) { $0 + $1.width } + 3 * TokensTodayCard.segmentGap, 600, accuracy: 0.001)
    }

    func testABarTooNarrowForItsMinimumsShrinksThem() {
        let segments = TokensTodayCard.segments(TokensTodayCard.tokenShares(day), in: 10)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.width }, 4, accuracy: 0.001)
        XCTAssertTrue(segments.allSatisfy { $0.width >= 0.999 })
    }

    func testNoRoomAtAllDrawsNothing() {
        XCTAssertTrue(TokensTodayCard.segments(TokensTodayCard.tokenShares(day), in: 6).allSatisfy { $0.width == 0 })
    }

    func testTheLegendHasEachKindsCountAndDollarsAndOutputsThinking() {
        XCTAssertEqual(TokensTodayCard.legend(day, locale: us), [
            OverviewTokenLegendItem(category: .input, tokens: "21.1k", cost: "$0.16", note: nil),
            OverviewTokenLegendItem(category: .output, tokens: "2.1M", cost: "$63.40", note: "incl. 716.6k thinking"),
            OverviewTokenLegendItem(category: .cacheRead, tokens: "802.1M", cost: "$304.77", note: nil),
            OverviewTokenLegendItem(category: .cacheWrite, tokens: "20.0M", cost: "$174.53", note: nil),
        ])
    }

    func testWithoutPerKindPricesTheLegendIsCountsAlone() {
        let grok = TokenBreakdown(input: 1_000, output: 500)
        XCTAssertEqual(TokensTodayCard.legend(grok, locale: us).map(\.cost), [nil, nil])
    }

    func testThinkingIsNotedOnlyWhenTheLogHasIt() {
        XCTAssertEqual(TokensTodayCard.thinkingNote(day), "incl. 716.6k thinking")
        XCTAssertNil(TokensTodayCard.thinkingNote(TokenBreakdown(output: 10)))
    }

    func testTheCardsWords() {
        XCTAssertEqual(TokensTodayCard.title, "Tokens today")
        XCTAssertEqual(TokensTodayCard.tokensRowLabel, "Tokens")
        XCTAssertEqual(TokensTodayCard.costRowLabel, "Cost")
    }
}
