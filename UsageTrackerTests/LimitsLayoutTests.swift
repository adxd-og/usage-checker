import XCTest
@testable import Omelette

/// `Dashboard-Limits(-Light).dc.html`, spec 2026-10-16 § The tab, item 3: a ranked row is
/// the mockup's `minmax(0, 1fr) 280px 96px 80px` where it fits, and folds the project
/// under the name where it does not, one decision for every row. The dashboard must stay
/// usable at its narrowest window.
final class LimitsLayoutTests: XCTestCase {
    func testTheWideRowNeedsItsFourColumnsAndThreeGaps() {
        // 160 + 280 + 96 + 80 = 616, plus three 18 pt gaps.
        XCTAssertEqual(LimitsLayout.wideRowsMinWidth, 670)
        // 1036 − 30 − 32 − 2 × 24.
        XCTAssertEqual(LimitsLayout.rowsWidth(detailWidth: 1036), 926)
    }

    func testTheMockupsWindowDrawsWideRowsAndTheNarrowestFoldsThem() {
        // 1280 − 10 − 224 − 10: the detail column of the mockups' window.
        XCTAssertTrue(LimitsLayout.isWideRows(detailWidth: 1036))
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: DashboardShellLayout.minimumDetailWidth))
    }

    func testTheSwitchIsAtExactlyTheWideWidth() {
        // 670 + 30 + 32 + 48.
        XCTAssertTrue(LimitsLayout.isWideRows(detailWidth: 780))
        XCTAssertFalse(LimitsLayout.isWideRows(detailWidth: 779.5))
    }
}
