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

/// The bar's other decision: how wide each segment is drawn. A minimum applied to
/// each segment independently is not a layout — it is an overdraft, and the segments
/// past the end of the bar are simply not visible.
final class TokenShareBarWidthTests: XCTestCase {
    private let bar: CGFloat = 300

    func testTheSegmentsNeverAddUpToMoreThanTheBar() {
        // [1, 1, 9997, 1] at 300 pt: `max(2, width * share)` per segment asked for
        // 305.9 pt, and the 2-pt cache write on the end was clipped away entirely.
        let b = TokenBreakdown(input: 1, output: 1, cacheRead: 9_997, cacheWrite5m: 1)
        let widths = TokenShareBar.widths(b, in: bar).map(\.1)

        XCTAssertEqual(widths.count, 4)
        XCTAssertEqual(widths.reduce(0, +), bar, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 >= 2 }, "and every visible bucket is still visible")
    }

    func testTheBigBucketKeepsEverythingTheMinimumsLeave() {
        let b = TokenBreakdown(input: 1, output: 1, cacheRead: 9_997, cacheWrite5m: 1)
        let widths = TokenShareBar.widths(b, in: bar)
        let cacheRead = try? XCTUnwrap(widths.first { $0.0 == .cacheRead }?.1)

        // 300 − 4 × 2 = 292 to share out; the cache read's 99.97% of it, plus its own
        // 2-pt floor.
        XCTAssertEqual(cacheRead ?? 0, 2 + 292 * 0.9997, accuracy: 1e-9)
    }

    func testAnEmptyBucketIsStillNotDrawn() {
        let b = TokenBreakdown(input: 300, output: 100, cacheRead: 600)
        XCTAssertEqual(TokenShareBar.widths(b, in: bar).map { $0.0 }, [.input, .output, .cacheRead])
        XCTAssertTrue(TokenShareBar.widths(.zero, in: bar).isEmpty)
    }

    func testASingleBucketTakesTheWholeBar() {
        let widths = TokenShareBar.widths(TokenBreakdown(cacheRead: 5_000), in: bar)
        XCTAssertEqual(widths.count, 1)
        XCTAssertEqual(widths[0].1, bar, accuracy: 1e-9)
    }

    func testABarTooNarrowForEveryMinimumSharesWhatItHas() {
        // Four buckets and 5 pt: the 2-pt floor cannot be honoured, and honouring it
        // anyway would draw 8 pt of bar in 5 pt of space.
        let b = TokenBreakdown(input: 1, output: 1, cacheRead: 1, cacheWrite5m: 1)
        let widths = TokenShareBar.widths(b, in: 5).map(\.1)

        XCTAssertEqual(widths.reduce(0, +), 5, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 > 0 }, "narrow, but nothing vanishes")
    }

    func testAZeroWidthBarAsksForNoWidthAtAll() {
        // SwiftUI hands a GeometryReader zero on the first pass; a negative remainder
        // would come back as a negative frame width.
        let b = TokenBreakdown(input: 1, output: 9)
        XCTAssertTrue(TokenShareBar.widths(b, in: 0).allSatisfy { $0.1 == 0 })
    }

    func testTheProportionsSurviveTheMinimums() {
        // Nothing pathological: four even buckets stay even.
        let b = TokenBreakdown(input: 250, output: 250, cacheRead: 250, cacheWrite5m: 250)
        let widths = TokenShareBar.widths(b, in: bar).map(\.1)
        XCTAssertTrue(widths.allSatisfy { abs($0 - 75) < 1e-9 })
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

/// The history header's one line of explanation. It names the unit on the chart, and
/// in Tokens mode the chart is not a cost chart.
final class SessionHistorySubtitleTests: XCTestCase {
    func testCostModeNamesTheCostAndItsSource() {
        XCTAssertEqual(
            SessionHistoryView.costSubtitle(mode: .cost, source: "the Claude Code session logs"),
            "Daily cost from the Claude Code session logs"
        )
    }

    func testTokensModeSaysTokensNotCost() {
        XCTAssertEqual(
            SessionHistoryView.costSubtitle(mode: .tokens, source: "the Claude Code session logs"),
            "Daily tokens by type from the Claude Code session logs"
        )
    }

    func testAProviderWithNoNamedSourceStillGetsTheUnit() {
        XCTAssertEqual(SessionHistoryView.costSubtitle(mode: .cost, source: nil), "Daily cost")
        XCTAssertEqual(SessionHistoryView.costSubtitle(mode: .tokens, source: nil), "Daily tokens by type")
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
