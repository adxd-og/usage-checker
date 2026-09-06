import XCTest
@testable import Omelette

/// Independent verification of commit 8cea815 ("Share bar: allocate the minimums first,
/// then share what is left") and commit de88555's label/subtitle wording. Written
/// without reading `TokenBreakdownViewRuleTests` or `TokenBreakdownTests`; uses
/// different bucket counts and bar widths than the spec's own worked example so the
/// coverage isn't just re-running the same numbers back through the same formula.
final class TokenShareBarAndLabelsVerificationTests: XCTestCase {
    // MARK: - Widths never exceed the bar, and never go negative

    func testFourUnevenBucketsAtAWideBarSumExactlyToTheWidthWithEveryFloorHonoured() {
        // A different skew than the spec's [1, 1, 9997, 1]: three small buckets and one
        // dominant one, at a different bar width (250, not 300).
        let b = TokenBreakdown(input: 3, output: 4, cacheRead: 9_990, cacheWrite5m: 3)
        let widths = TokenShareBar.widths(b, in: 250).map(\.1)

        XCTAssertEqual(widths.count, 4)
        XCTAssertEqual(widths.reduce(0, +), 250, accuracy: 1e-9, "never more bar than there is")
        XCTAssertTrue(widths.allSatisfy { $0 >= 2 - 1e-9 }, "every non-zero bucket still gets its 2pt floor")
    }

    func testThreeBucketsInABarTooNarrowForTheirMinimumsShareWhatThereIsWithoutGoingNegative() {
        // 3 buckets need 6pt of floor at the default minimum; the bar only has 4.
        let b = TokenBreakdown(input: 10, output: 20, cacheRead: 30)
        let widths = TokenShareBar.widths(b, in: 4).map(\.1)

        XCTAssertEqual(widths.count, 3)
        XCTAssertEqual(widths.reduce(0, +), 4, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 > 0 }, "narrower than the ideal floor, but nothing disappears or goes negative")
    }

    func testACategoryWithZeroTokensNeverGetsASegment() {
        let b = TokenBreakdown(input: 500, output: 0, cacheRead: 500, cacheWrite5m: 0)
        let categories = TokenShareBar.widths(b, in: 200).map(\.0)
        XCTAssertEqual(categories, [.input, .cacheRead], "output and cacheWrite are both zero and absent entirely")
    }

    func testAllFourBucketsPresentAtExactlyTheMinimumTimesCountFitsWithNoRemainderToShare() {
        // 4 buckets x 2pt minimum = 8pt exactly — the remainder to share is zero, so
        // every segment should land exactly on the floor regardless of share.
        let b = TokenBreakdown(input: 1, output: 1_000_000, cacheRead: 1, cacheWrite5m: 1)
        let widths = TokenShareBar.widths(b, in: 8).map(\.1)
        XCTAssertEqual(widths.count, 4)
        XCTAssertTrue(widths.allSatisfy { abs($0 - 2) < 1e-9 }, "zero remainder to share, so every floor is exactly 2")
        XCTAssertEqual(widths.reduce(0, +), 8, accuracy: 1e-9)
    }

    func testNegativeOrZeroWidthNeverEscapesTheBar() {
        // Same shape as the spec's overdraft example but pushed further: five very
        // unequal buckets are not possible (only four categories exist), so instead
        // push the width itself to something smaller than any reasonable floor.
        let b = TokenBreakdown(input: 1, output: 1, cacheRead: 1, cacheWrite5m: 100_000)
        let widths = TokenShareBar.widths(b, in: 1).map(\.1)
        XCTAssertEqual(widths.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 >= 0 }, "must never go negative even at a 1pt bar")
    }

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
