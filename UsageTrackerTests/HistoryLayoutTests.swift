import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "History · Session expanded": the chat list draws the
/// mockup's five columns where they fit and folds three of them onto a caption where
/// they do not, one decision for the header and every row.
final class HistoryLayoutTests: XCTestCase {
    func testTheWideRowNeedsTheMockupsColumnsAndGaps() {
        // 22 + 160 + 140 + 80 + 96 + 104 = 602, plus five 18 pt gaps.
        XCTAssertEqual(HistoryLayout.minimumWideListWidth, 692)
    }

    func testTheListIsTheColumnLessItsGuttersAndTheCardsPadding() {
        // 1036 − 30 − 32 − 2 × 24.
        XCTAssertEqual(HistoryLayout.listWidth(detailWidth: 1036), 926)
    }

    func testTheMockupsWindowDrawsTheWideRow() {
        // 1280 − 10 − 224 − 10: the detail column of the mockups' window.
        XCTAssertTrue(HistoryLayout.isWideList(detailWidth: 1036))
    }

    func testTheNarrowestWindowFoldsTheRow() {
        XCTAssertFalse(HistoryLayout.isWideList(detailWidth: DashboardShellLayout.minimumDetailWidth))
    }

    func testTheSwitchIsAtExactlyTheWideWidth() {
        XCTAssertTrue(HistoryLayout.isWideList(detailWidth: 802))
        XCTAssertFalse(HistoryLayout.isWideList(detailWidth: 801.5))
    }
}
