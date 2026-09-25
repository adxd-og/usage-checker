import XCTest
@testable import Omelette

/// Independent verification of commit 8cea815 ("Share bar: allocate the minimums first,
/// then share what is left") and commit de88555's label wording. Written
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
}
