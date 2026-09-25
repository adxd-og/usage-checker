import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · All": "cost tile includes Claude +
/// API-equivalent caption", today first (issue #6's rule, `OMCostTileTests`), in
/// `Main.dc.html`'s group look.
final class OMCostTileLookTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 57, kind: .session)

    func testTheCostTileIsAPopoverGroupWithTheMockupsType() {
        XCTAssertEqual(OMCostTile.surface, .group)
        XCTAssertEqual(OMCostTile.titleSize, 12.5)
        XCTAssertEqual(OMCostTile.secondarySize, 11.5)
        XCTAssertEqual(OMCostTile.headlineSize, 22)
        XCTAssertEqual(OMCostTile.captionSize, 11)
        XCTAssertEqual(OMCostTile.verticalPadding, 12)
        XCTAssertEqual(OMCostTile.horizontalPadding, 14)
    }

    /// `Main.dc.html`'s week: Claude's dollars are in the tile, split out, and the tile
    /// says what they are.
    func testClaudesDollarsAreInTheTileWithTheAPIEquivalentCaption() {
        let services = [
            Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session], weekCost: 2940.52),
            Fixture.snapshot(id: "codex", displayName: "Codex", weekCost: 29.04),
            Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 6.41),
        ]
        XCTAssertEqual(OMCostTile.money(OMCostTile.total(services), locale: us), "$2,975.97")
        XCTAssertEqual(OMCostTile.secondary(services: services, today: [:], locale: us),
                       "Claude $2,940.52 · Codex $29.04 · Grok $6.41")
        XCTAssertEqual(OMCostTile.caption(services: services), CostCopy.apiEquivalent)
    }

    func testTodayLeadsAndTheWeekKeepsItsNumber() {
        let services = [Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session], weekCost: 2940.52)]
        let today = ["claude": 118.4]
        XCTAssertEqual(OMCostTile.title(todayKnown: OMCostTile.todayTotal(services, today: today) != nil), "Today")
        XCTAssertEqual(OMCostTile.secondary(services: services, today: today, locale: us),
                       "Last 7 days $2,940.52 · Claude $2,940.52")
    }
}
