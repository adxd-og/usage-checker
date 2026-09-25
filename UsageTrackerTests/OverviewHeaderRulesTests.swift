import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Overview", and `Dashboard-Overview(-Light).dc.html`: the
/// selected provider's logo tile left of the title (`width: 40px; height: 40px;
/// border-radius: 13px`, `gap: 14px` to the title block, `align-items: center`). The
/// mockup's brand-coloured letter is a placeholder; the app draws the provider's own logo
/// in the text colour, as every other 3.0 logo box does, on the cards' pane glass.
final class OverviewHeaderRulesTests: XCTestCase {
    func testTheTileIsTheMockupsFortyPointBoxWithAThirteenPointCorner() {
        XCTAssertEqual(OverviewHeaderRules.tileSize, 40)
        XCTAssertEqual(OverviewHeaderRules.tileRadius, 13)
    }

    func testTheLogoSitsInsideTheTileWithRoomAroundIt() {
        XCTAssertEqual(OverviewHeaderRules.iconSize, 24)
        XCTAssertLessThan(OverviewHeaderRules.iconSize, OverviewHeaderRules.tileSize)
    }

    func testTheTileSitsOnTheCardsPaneGlass() {
        XCTAssertEqual(OverviewHeaderRules.surface, .pane)
    }

    func testTheTileSitsFourteenPointsLeftOfTheTitleBlock() {
        XCTAssertEqual(DashboardHeader.leadingSpacing, 14)
    }

    func testTheTileShowsTheSelectedProvidersLogo() {
        let codex = Fixture.snapshot(id: "codex", icon: "terminal", plan: "Codex Plus")
        XCTAssertEqual(OverviewHeaderRules.logo(serviceID: "codex", service: codex),
                       OverviewHeaderLogo(serviceID: "codex", sfFallback: "terminal"))
    }

    func testAProviderKnownOnlyFromHistoryStillGetsItsTile() {
        // No live snapshot: the bundled logo is found by id; the symbol is the provider
        // row's own fallback.
        XCTAssertEqual(OverviewHeaderRules.logo(serviceID: "grok", service: nil),
                       OverviewHeaderLogo(serviceID: "grok", sfFallback: "sparkles"))
    }

    func testWithNoSingleProviderThereIsNoTile() {
        XCTAssertNil(OverviewHeaderRules.logo(serviceID: "", service: nil))
    }
}
