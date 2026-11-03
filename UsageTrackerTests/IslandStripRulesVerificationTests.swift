import XCTest
@testable import Omelette

/// Tester's verification of the plan's round-2 amendment R2-2 (spec 2026-11-03): every strip control
/// takes its own height where the row leaves a point above and below, shrinks to row - 2 where it
/// does not, never below 16 pt (a logo's glyph) and never above its own height.
final class IslandStripRulesVerificationTests: XCTestCase {
    private let small = OMButtonRules.height(.small)      // "‹ All"
    private let logo = IslandLogoButton.size              // a provider's circle

    func testTheNativeHeightsAreTheOnesTheAmendmentNames() {
        XCTAssertEqual(small, 28)
        XCTAssertEqual(logo, 26)
        XCTAssertEqual(IslandLogoButton.glyph, 16)
        XCTAssertEqual(IslandStripRules.minimumHeight, IslandLogoButton.glyph, "never smaller than the glyph")
    }

    func testAt24ThePointsEachControlLeavesAPointAboveAndBelow() {
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 24), 22)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 24), 22)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: 24), 22)
    }

    func testAt25ThePointsTheControlsTakeTheRowLessTwo() {
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 25), 23)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 25), 23)
    }

    func testAt32ThePointsTheBackButtonKeeps28AndTheLogosKeep26() {
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 32), 28)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 32), 26)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: 32), 26)
    }

    func testTheOwnHeightIsKeptExactlyWhereTheRowHasRoomForIt() {
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 30), 28, "28 + 1 + 1 fits 30")
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 29), 27)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 28), 26)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 27), 25)
        XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: 80), 26, "never grows")
    }

    func testAnAbsurdlyShortRowStillGivesTheGlyphsHeightNotZeroOrNegative() {
        for row: CGFloat in [0, 1, 10, 17, 18] {
            XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: row), 16, "row \(row)")
            XCTAssertEqual(IslandStripRules.controlHeight(native: logo, rowHeight: row), 16, "row \(row)")
        }
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: 19), 17)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: -5), 16)
    }

    func testAControlShorterThanTheFloorKeepsItsOwnHeight() {
        XCTAssertEqual(IslandStripRules.controlHeight(native: 12, rowHeight: 24), 12)
        XCTAssertEqual(IslandStripRules.controlHeight(native: 12, rowHeight: 0), 12)
    }

    func testTheHeightGrowsWithTheRowOneForOneThenStopsAtTheNativeHeight() {
        var last: CGFloat = 0
        for row in stride(from: CGFloat(0), through: 40, by: 1) {
            let height = IslandStripRules.controlHeight(native: small, rowHeight: row)
            XCTAssertGreaterThanOrEqual(height, last, "row \(row)")
            XCTAssertLessThanOrEqual(height, small)
            XCTAssertGreaterThanOrEqual(height, 16)
            last = height
        }
        XCTAssertEqual(last, 28)
    }

    func testTheStripsOfTheLayoutsFitTheirControls() {
        for (name, screen) in [
            ("external", ScreenFixture.externalRight), ("1280", ScreenFixture.wide1280),
            ("14-inch", ScreenFixture.builtIn), ("narrow notched", ScreenFixture.narrowNotched),
        ] {
            let strip = IslandLayout(on: screen, petOn: true).stripHeight
            XCTAssertEqual(strip, screen.islandNotch?.height, name)
            for native in [small, logo] {
                let height = IslandStripRules.controlHeight(native: native, rowHeight: strip)
                XCTAssertLessThanOrEqual(height + 2, strip, "\(name): a point above and below")
            }
        }
    }

    func testAPanelDisplayHasNoStripSoItsHeaderRowIsTheOnlyRowThatIsRead() {
        let layout = IslandLayout(on: ScreenFixture.narrow1279, petOn: true)
        XCTAssertEqual(layout.kind, .panel)
        XCTAssertEqual(layout.stripHeight, 0)
        // The panel's header is 32 pt: its controls keep their own heights there, as in 4.0.
        XCTAssertEqual(IslandStripRules.controlHeight(native: small, rowHeight: IslandHeightRules.panelHeaderHeight), 28)
        XCTAssertEqual(IslandLogoButton.diameter(rowHeight: IslandHeightRules.panelHeaderHeight), 26)
    }
}
