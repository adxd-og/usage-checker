import XCTest
import SwiftUI
@testable import Omelette

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
        XCTAssertEqual(HistoryChartMode.sessions.rawValue, "sessions")
    }

    func testTheThreeModesAreOfferedInOrderWithCostFirst() {
        // Cost is the default and the question the tab has always answered; Sessions is
        // the newest and the narrowest, so it goes last.
        XCTAssertEqual(HistoryChartMode.allCases, [.cost, .tokens, .sessions])
    }

    func testTheSegmentsAreLabelledForPeopleNotForStorage() {
        XCTAssertEqual(HistoryChartMode.cost.displayName, "Cost")
        XCTAssertEqual(HistoryChartMode.tokens.displayName, "Tokens")
        XCTAssertEqual(HistoryChartMode.sessions.displayName, "Sessions")
    }

    func testAnUnknownStoredValueIsNotADecodableMode() {
        // @AppStorage falls back to the default when the raw value no longer
        // parses; this is the assumption that makes that safe.
        XCTAssertNil(HistoryChartMode(rawValue: "spend"))
    }
}
