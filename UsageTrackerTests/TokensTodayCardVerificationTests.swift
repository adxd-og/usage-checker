import XCTest
@testable import Omelette

/// Independent verification of `TokensTodayCard`'s rules against liquid-glass spec
/// § Screens, "Overview" and `Dashboard-Overview(-Light).dc.html`: two stacked bars with
/// 2 pt gaps and a 3 pt minimum segment, the spec's four token colours, "incl. … thinking"
/// under Output, and the cache-share caption. Written without reading
/// `TokensTodayCardTests.swift`; different share shapes (extreme skew, a too-narrow bar,
/// duplicate/zero-value shares) than its worked examples.
final class TokensTodayCardVerificationTests: XCTestCase {
    // MARK: - Metrics

    func testTheGapBetweenSegmentsIsTwoPoints() {
        XCTAssertEqual(TokensTodayCard.segmentGap, 2)
    }

    func testTheMinimumSegmentIsThreePoints() {
        XCTAssertEqual(TokensTodayCard.minimumSegment, 3)
    }

    // MARK: - segments(): minimum guaranteed, no overflow

    func testAnExtremelySkewedShareStillMeetsTheThreePointMinimum() {
        let shares = [
            OverviewTokenShare(category: .input, value: 1),
            OverviewTokenShare(category: .output, value: 999_999),
        ]
        let segments = TokensTodayCard.segments(shares, in: 200)
        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.width, TokensTodayCard.minimumSegment - 0.01,
                                         "\(segment.category) fell under the minimum: \(segment.width)")
        }
    }

    func testSegmentsNeverOverflowTheAvailableWidth() {
        let shares = [
            OverviewTokenShare(category: .input, value: 5),
            OverviewTokenShare(category: .output, value: 50),
            OverviewTokenShare(category: .cacheRead, value: 900),
            OverviewTokenShare(category: .cacheWrite, value: 45),
        ]
        let width: CGFloat = 300
        let segments = TokensTodayCard.segments(shares, in: width)
        let gaps = TokensTodayCard.segmentGap * CGFloat(segments.count - 1)
        let total = segments.reduce(0) { $0 + $1.width } + gaps
        XCTAssertEqual(total, width, accuracy: 0.01, "the segments and their gaps must exactly fill the bar")
    }

    /// "a bar too narrow for the minimums shrinks them": three equal shares in a bar that
    /// cannot give each its full 3 pt minimum.
    func testTheMinimumShrinksWhenTheBarIsTooNarrowForAll() {
        let shares = [
            OverviewTokenShare(category: .input, value: 1),
            OverviewTokenShare(category: .output, value: 1),
            OverviewTokenShare(category: .cacheRead, value: 1),
        ]
        // available = 10 - 2*2 = 6; three equal shares get exactly 2 pt each.
        let segments = TokensTodayCard.segments(shares, in: 10)
        XCTAssertEqual(segments.map(\.width), [2, 2, 2])
    }

    func testOneShareTakesTheWholeBar() {
        let shares = [OverviewTokenShare(category: .input, value: 42)]
        let segments = TokensTodayCard.segments(shares, in: 150)
        XCTAssertEqual(segments.first?.width, 150)
    }

    func testZeroValueSharesAreDroppedEntirelyNotDrawnAtZeroWidth() {
        let shares = [
            OverviewTokenShare(category: .input, value: 0),
            OverviewTokenShare(category: .output, value: 10),
        ]
        let segments = TokensTodayCard.segments(shares, in: 100)
        XCTAssertEqual(segments.map(\.category), [.output])
    }

    func testSegmentsAreEmptyWhenTheBarHasNoRoomAtAll() {
        let shares = [
            OverviewTokenShare(category: .input, value: 1),
            OverviewTokenShare(category: .output, value: 1),
        ]
        let segments = TokensTodayCard.segments(shares, in: 1) // available = 1 - 2 = -1
        XCTAssertTrue(segments.allSatisfy { $0.width == 0 })
    }

    // MARK: - Colour tokens match the spec's four token colours

    func testColorTokenMapsEachCategoryToItsSpecToken() {
        XCTAssertEqual(TokensTodayCard.colorToken(.input), .tokenInput)
        XCTAssertEqual(TokensTodayCard.colorToken(.output), .tokenOutput)
        XCTAssertEqual(TokensTodayCard.colorToken(.cacheRead), .tokenCacheRead)
        XCTAssertEqual(TokensTodayCard.colorToken(.cacheWrite), .tokenCacheWrite)
    }

    func testTheFourTokenColoursMatchTheSpecsHexValues() {
        // liquid-glass spec § Tokens, "tokens": input #7AA2FF/#4C7EF3, output
        // #F59E6B/#EE7B3A, cache read #5CC8C8/#26A8A8, cache write #C79BFF/#9A66EE.
        XCTAssertEqual(OMPalette.rgba(.tokenInput, scheme: .dark), OMRGBA(hex: 0x7AA2FF))
        XCTAssertEqual(OMPalette.rgba(.tokenInput, scheme: .light), OMRGBA(hex: 0x4C7EF3))
        XCTAssertEqual(OMPalette.rgba(.tokenOutput, scheme: .dark), OMRGBA(hex: 0xF59E6B))
        XCTAssertEqual(OMPalette.rgba(.tokenOutput, scheme: .light), OMRGBA(hex: 0xEE7B3A))
        XCTAssertEqual(OMPalette.rgba(.tokenCacheRead, scheme: .dark), OMRGBA(hex: 0x5CC8C8))
        XCTAssertEqual(OMPalette.rgba(.tokenCacheRead, scheme: .light), OMRGBA(hex: 0x26A8A8))
        XCTAssertEqual(OMPalette.rgba(.tokenCacheWrite, scheme: .dark), OMRGBA(hex: 0xC79BFF))
        XCTAssertEqual(OMPalette.rgba(.tokenCacheWrite, scheme: .light), OMRGBA(hex: 0x9A66EE))
    }

    // MARK: - "incl. … thinking" copy

    func testThinkingNoteFormatsTheCountWhenPresent() {
        var breakdown = TokenBreakdown(input: 1, output: 2)
        breakdown.thinking = 716_600
        XCTAssertEqual(TokensTodayCard.thinkingNote(breakdown), "incl. 716.6k thinking")
    }

    func testThinkingNoteIsNilWhenThereIsNoThinking() {
        let breakdown = TokenBreakdown(input: 1, output: 2)
        XCTAssertNil(TokensTodayCard.thinkingNote(breakdown))
    }

    // MARK: - Cache-share caption

    func testCacheShareCaptionRoundsToTheNearestPercent() {
        // input 32, cacheRead 68 of a 100-token context → 68%.
        let breakdown = TokenBreakdown(input: 32, output: 5, cacheRead: 68)
        XCTAssertEqual(TokensTodayCard.cacheShareCaption(breakdown), "68% of context came from cache")
    }

    func testCacheShareCaptionIsNilWithNoInputAtAll() {
        let breakdown = TokenBreakdown(input: 0, output: 100, cacheRead: 0, cacheWrite5m: 0)
        XCTAssertNil(TokensTodayCard.cacheShareCaption(breakdown), "no context tokens means no share to report")
    }

    // MARK: - Cost bar: nil for a whole-turn priced provider or an all-zero breakdown

    func testCostSharesIsNilWhenTheProviderPricesATurnAsAWhole() {
        let breakdown = TokenBreakdown(input: 10, output: 10) // no `.cost`
        XCTAssertNil(TokensTodayCard.costShares(breakdown))
    }

    func testCostSharesIsNilWhenEveryCategoryCostNothing() {
        var breakdown = TokenBreakdown(input: 10, output: 10)
        breakdown.cost = TokenCostBreakdown(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertNil(TokensTodayCard.costShares(breakdown))
    }

    func testCostSharesKeepsOnlyThePositiveCategories() {
        var breakdown = TokenBreakdown(input: 10, output: 10, cacheRead: 10)
        breakdown.cost = TokenCostBreakdown(input: 0, output: 2.5, cacheRead: 1.1, cacheWrite: 0)
        let shares = TokensTodayCard.costShares(breakdown)
        XCTAssertEqual(shares?.map(\.category), [.output, .cacheRead])
    }

    // MARK: - Token shares keep TokenCategory's declared order

    func testTokenSharesDropEmptyCategoriesAndKeepDeclaredOrder() {
        let breakdown = TokenBreakdown(input: 0, output: 5, cacheRead: 7, cacheWrite5m: 0)
        let shares = TokensTodayCard.tokenShares(breakdown)
        XCTAssertEqual(shares.map(\.category), [.output, .cacheRead])
    }
}
