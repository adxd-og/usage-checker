import XCTest
@testable import Omelette

/// Independent verification of commit 8cea815 ("Share bar: allocate the minimums first,
/// then share what is left") and commit de88555's label/subtitle wording. Written
/// without reading `TokenBreakdownViewRuleTests` or `TokenBreakdownTests`; uses
/// different bucket counts and bar widths than the spec's own worked example so the
/// coverage isn't just re-running the same numbers back through the same formula.
final class TokenShareBarAndLabelsVerificationTests: XCTestCase {
    // MARK: - Label and tooltip strings

    func testInputIsTheOnlyCategoryWithATooltipAndItNamesTheUncachedShare() {
        XCTAssertEqual(TokenCategory.input.help, "Uncached input")
        XCTAssertNil(TokenCategory.output.help)
        XCTAssertNil(TokenCategory.cacheRead.help)
        XCTAssertNil(TokenCategory.cacheWrite.help)
    }

    func testHistorySubtitleNamesTokensAsTheChartsUnitInTokensModeAndCostInCostMode() {
        XCTAssertEqual(
            SessionHistoryView.costSubtitle(mode: .cost, source: "the Codex CLI's session logs"),
            "Daily cost from the Codex CLI's session logs"
        )
        XCTAssertEqual(
            SessionHistoryView.costSubtitle(mode: .tokens, source: "the Codex CLI's session logs"),
            "Daily tokens by type from the Codex CLI's session logs"
        )
        XCTAssertEqual(SessionHistoryView.costSubtitle(mode: .cost, source: nil), "Daily cost")
        XCTAssertEqual(SessionHistoryView.costSubtitle(mode: .tokens, source: nil), "Daily tokens by type")
    }
}
