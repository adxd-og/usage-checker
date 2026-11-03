import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 (the logos beside the camera) with spec 2026-11-03: a logo fits
/// the strip it stands in — the MacBook's 32 pt notch, an external's 24 pt menu bar, the panel's 32 pt
/// top row — with a point above and below, and is never smaller than its glyph.
final class IslandLogoButtonTests: XCTestCase {
    func testOnAnExternalsStripTheLogoShrinksToLeaveAPointAboveAndBelow() {
        let strip = IslandLayout(on: ScreenFixture.externalRight, petOn: true).stripHeight
        XCTAssertEqual(strip, 24)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: strip), 22)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: 25), 23)
    }

    func testFromA28PointRowOnTheLogoKeepsThePrototypes26() {
        let rows: [CGFloat] = [28, 32, 34, 37, IslandHeightRules.panelHeaderHeight]
        for row in rows {
            XCTAssertEqual(IslandLogoButton.diameter(rowHeight: row), 26, "\(row)")
        }
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: IslandLayout(on: ScreenFixture.builtIn, petOn: true).stripHeight), 26)
    }

    func testALogoNeverShrinksBelowItsGlyph() {
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: 0), IslandLogoButton.glyph)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: 10), 16)
    }
}
