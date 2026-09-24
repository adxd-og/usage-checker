import XCTest
@testable import Omelette

/// History → Tokens at the dashboard's narrowest widths. Measured (report D § 5): the
/// six fixed columns (540 pt of frames) and their gaps need 580 pt inside the 24 pt
/// gutters. The 820 pt window with a 220 pt sidebar leaves 551, and Cost was clipped by
/// about 29 pt. With the 160 pt sidebar it leaves 611. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — Tokens table.
final class TokenColumnsTests: XCTestCase {
    private let day = SessionFixture.tokens(
        input: 1_000, output: 200, cacheRead: 1_200_000, cacheWrite5m: 200_000, cacheWrite1h: 100_000
    )

    func testAWideSidebarAtTheMinimumWindowMergesTheCacheColumns() {
        XCTAssertEqual(SessionHistoryView.tokenColumns(availableWidth: 551), [.input, .output, .cache, .cost])
    }

    func testTheNarrowSidebarAtTheMinimumWindowKeepsBothCacheColumns() {
        XCTAssertEqual(
            SessionHistoryView.tokenColumns(availableWidth: 611),
            [.input, .output, .cacheRead, .cacheWrite, .cost]
        )
    }

    func testTheSplitStartsAtExactly580() {
        XCTAssertEqual(SessionHistoryView.minimumSplitCacheWidth, 580)
        XCTAssertEqual(SessionHistoryView.tokenColumns(availableWidth: 580).count, 5)
        XCTAssertEqual(SessionHistoryView.tokenColumns(availableWidth: 579.5).count, 4)
    }

    func testMergingSavesMoreThanTheMeasuredOverflow() {
        let split = SessionHistoryView.tokenColumns(availableWidth: 611).reduce(0) { $0 + $1.width }
        let merged = SessionHistoryView.tokenColumns(availableWidth: 551).reduce(0) { $0 + $1.width }
        XCTAssertEqual(split, 420, "In 80 + Out 80 + Cache read 90 + Cache write 90 + Cost 80")
        XCTAssertEqual(merged, 330)
        XCTAssertGreaterThan(split - merged, 29, "Cost was clipped by about 29 pt at 551")
    }

    func testTheMergedCacheCellIsReadPlusWrite() {
        XCTAssertEqual(TokenColumn.cache.value(breakdown: day, cost: 0), "1.5M")
        XCTAssertEqual(TokenColumn.cacheRead.value(breakdown: day, cost: 0), "1.2M")
        XCTAssertEqual(TokenColumn.cacheWrite.value(breakdown: day, cost: 0), "300.0k")
    }

    func testEveryOtherCellIsTheFigureItWasBefore() {
        XCTAssertEqual(TokenColumn.input.value(breakdown: day, cost: 0), "1.0k")
        XCTAssertEqual(TokenColumn.output.value(breakdown: day, cost: 0), "200")
        XCTAssertEqual(TokenColumn.cost.value(breakdown: .zero, cost: 3.456), "$3.46")
    }

    func testTheHeaderSaysWhatEachColumnHolds() {
        XCTAssertEqual(TokenColumn.input.title, "In")
        XCTAssertEqual(TokenColumn.input.help, "Uncached input")
        XCTAssertEqual(TokenColumn.cache.title, "Cache")
        XCTAssertEqual(TokenColumn.cache.help, "Cache read + cache write")
        XCTAssertEqual(TokenColumn.cacheRead.title, "Cache read")
        XCTAssertEqual(TokenColumn.cacheWrite.title, "Cache write")
        XCTAssertEqual(TokenColumn.cost.title, "Cost")
    }

    func testOnlyTheCacheFiguresAreDrawnSecondary() {
        XCTAssertEqual(TokenColumn.allCases.filter(\.isSecondary), [.cacheRead, .cacheWrite, .cache])
    }
}
