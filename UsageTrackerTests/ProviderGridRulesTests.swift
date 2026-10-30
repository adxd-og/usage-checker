import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Grid rules) and § 3.9 (`ProviderGridRules`): every
/// row splits the same two equal columns right of the 150 pt habitat; one provider has no
/// grid (its page is home), two make one row, three put the cost tile in the orphan slot,
/// four make 2 × 2, five 2 + 2 + 1 with the cost tile beside the fifth (plan ruling R3).
final class ProviderGridRulesTests: XCTestCase {
    private let ids = ["claude", "codex", "antigravity", "grok", "anthropic-admin"]

    private func grid(_ count: Int, cost: Bool = true) -> ProviderGridRules.Grid {
        ProviderGridRules.grid(serviceIDs: Array(ids.prefix(count)), showsCostTile: cost)
    }

    func testOneProviderHasNoGridItsPageIsHome() {
        XCTAssertEqual(grid(1), .init(tileRows: [], costInLowerRow: false))
        XCTAssertTrue(ProviderGridRules.providerPageIsHome(count: 1))
        XCTAssertFalse(ProviderGridRules.providerPageIsHome(count: 2))
        XCTAssertFalse(ProviderGridRules.providerPageIsHome(count: 0))
        XCTAssertEqual(grid(0), .init(tileRows: [], costInLowerRow: false))
    }

    func testTwoProvidersMakeOneRowAndTheCostTileGoesOverKeepAwake() {
        XCTAssertEqual(
            grid(2),
            .init(tileRows: [[.provider("claude"), .provider("codex")]], costInLowerRow: true)
        )
    }

    func testThreeProvidersPutTheCostTileInTheOrphanSlot() {
        XCTAssertEqual(
            grid(3),
            .init(
                tileRows: [[.provider("claude"), .provider("codex")], [.provider("antigravity"), .cost]],
                costInLowerRow: false
            )
        )
    }

    func testFourProvidersMakeTwoByTwo() {
        XCTAssertEqual(
            grid(4),
            .init(
                tileRows: [[.provider("claude"), .provider("codex")], [.provider("antigravity"), .provider("grok")]],
                costInLowerRow: true
            )
        )
    }

    func testFiveProvidersMakeTwoTwoAndOneWithTheCostTileBesideTheFifth() {
        XCTAssertEqual(
            grid(5),
            .init(
                tileRows: [
                    [.provider("claude"), .provider("codex")],
                    [.provider("antigravity"), .provider("grok")],
                    [.provider("anthropic-admin"), .cost],
                ],
                costInLowerRow: false
            )
        )
    }

    func testWithoutDollarsTheOrphanSlotStaysEmpty() {
        XCTAssertEqual(grid(3, cost: false).tileRows.last, [.provider("antigravity"), .empty])
        XCTAssertFalse(grid(3, cost: false).costInLowerRow)
        XCTAssertFalse(grid(4, cost: false).costInLowerRow)
    }

    func testTheCostTileShowsOnlyWhenTheWeekHasDollars() {
        let spent = [Fixture.snapshot(id: "claude", weekCost: 12.5), Fixture.snapshot(id: "codex", weekCost: nil)]
        let none = [Fixture.snapshot(id: "claude", weekCost: 0), Fixture.snapshot(id: "codex", weekCost: nil)]
        XCTAssertTrue(ProviderGridRules.showsCostTile(spent))
        XCTAssertFalse(ProviderGridRules.showsCostTile(none))
        XCTAssertFalse(ProviderGridRules.showsCostTile([]))
    }

    func testAt640WithTheHabitatTheGridIs450AndAHalf220() {
        let columns = ProviderGridRules.columns(bodyWidth: 640, showsHabitat: true)
        XCTAssertEqual(columns, .init(content: 612, right: 450, half: 220))
        XCTAssertEqual(columns.cardInterior, 192)
    }

    func testAt720AndAt560TheHalvesFollowTheIslandsWidth() {
        let wide = ProviderGridRules.columns(bodyWidth: 720, showsHabitat: true)
        XCTAssertEqual(wide, .init(content: 692, right: 530, half: 260))
        XCTAssertEqual(wide.cardInterior, 232)
        // Below 1420 pt there is no habitat (D12).
        let narrow = ProviderGridRules.columns(bodyWidth: 560, showsHabitat: false)
        XCTAssertEqual(narrow, .init(content: 532, right: 532, half: 261))
        XCTAssertEqual(narrow.cardInterior, 233)
    }

    func testWithThePetOffTheGridTakesTheHabitatsWidth() {
        XCTAssertEqual(
            ProviderGridRules.columns(bodyWidth: 640, showsHabitat: false),
            .init(content: 612, right: 612, half: 301)
        )
    }
}
