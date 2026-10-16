import XCTest
@testable import Omelette

/// The ranked row's one width decision: limit-analytics spec (2026-10-16) § The tab, item 3
/// (ranked rows, the mockup's grid), and the dashboard's narrowest window stays usable.
final class LimitsLayoutVerificationTests: XCTestCase {
    func testOnceWideAlwaysWideAsTheWindowGrows() {
        var wasWide = false
        for width in stride(from: -50.0, through: 3_000.0, by: 0.5) {
            let wide = LimitsLayout.isWideRows(detailWidth: CGFloat(width))
            if wasWide { XCTAssertTrue(wide, "wide at a narrower width, narrow again at \(width)") }
            wasWide = wasWide || wide
        }
        XCTAssertTrue(wasWide)
    }

    func testTheDecisionIsTheRowsWidthAgainstTheWideRowsNeed() {
        for width in stride(from: 0.0, through: 1_600.0, by: 7.25) {
            let detail = CGFloat(width)
            XCTAssertEqual(
                LimitsLayout.isWideRows(detailWidth: detail),
                LimitsLayout.rowsWidth(detailWidth: detail) >= LimitsLayout.wideRowsMinWidth,
                "\(width)"
            )
        }
    }

    func testAWiderColumnGivesTheRowsExactlyThatMuchMore() {
        XCTAssertEqual(
            LimitsLayout.rowsWidth(detailWidth: 900) - LimitsLayout.rowsWidth(detailWidth: 800), 100
        )
    }

    func testNoWidthIsWideBelowTheNarrowestWindowsDetailColumn() {
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: 0))
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: -10))
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: DashboardShellLayout.minimumDetailWidth))
    }

    func testTheRowIsWideAtExactlyTheWidthItNeedsAndNarrowJustBelow() {
        // The detail width at which the rows' width equals what the wide row needs.
        let exact = LimitsLayout.wideRowsMinWidth - LimitsLayout.rowsWidth(detailWidth: 0)
        XCTAssertEqual(LimitsLayout.rowsWidth(detailWidth: exact), LimitsLayout.wideRowsMinWidth)
        XCTAssertTrue(LimitsLayout.isWideRows(detailWidth: exact))
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: exact.nextDown))
    }
}
