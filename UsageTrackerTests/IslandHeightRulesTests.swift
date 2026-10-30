import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Height) and § 3.9 (`IslandHeightRules`); review
/// findings 7 (the lower row is the taller of two halves) and 11 (the notch counted twice).
/// The budget is the island's window less the strip and its bottom padding; the agents list
/// yields only while its half is the taller; when even two rows cannot fit, the right column
/// scrolls. The layouts are a stand-in for the right column at a given cap: four providers
/// leave 342 pt outside the lower row, five 472; the agents card is 48 pt without its list;
/// the list's rows measure 330; the cost tile 140; keep awake 138.
final class IslandHeightRulesTests: XCTestCase {
    /// The right column laid out at `cap`: the list shows its rows up to the cap, the agents
    /// half is its chrome and the list, the column the fixed part and the taller half.
    private func samples(
        fixed: CGFloat, chrome: CGFloat = 48, content: CGFloat = 330,
        costTile: CGFloat? = 140, keepAwake: CGFloat = 138, cap: CGFloat = 260
    ) -> IslandHeightRules.Samples {
        let shown = min(content, cap)
        let agents = chrome + shown
        let other = IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake)
        return IslandHeightRules.Samples(
            rightColumn: fixed + max(agents, other),
            agentsColumn: agents,
            costTile: costTile,
            keepAwake: keepAwake,
            list: AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: content)
        )
    }

    private func outcome(_ budget: CGFloat?, _ samples: IslandHeightRules.Samples) -> IslandHeightRules.Outcome {
        IslandHeightRules.outcome(rightBudget: budget, samples: samples)
    }

    // MARK: - The budget

    func testOnThe14InchTheBudgetIsTheWindowLessTheStripAndThePadding() {
        // Window 982 − 86 = 896; less the 32 pt strip and 14 pt padding. "Visible height −
        // notch" would say 872 − 32 − 8 − 14 = 818: the menu bar counted twice.
        XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.builtIn, screenVisibleHeight: 872), 850)
        XCTAssertEqual(IslandHeightRules.rightColumnBudget(on: ScreenFixture.builtIn, screenVisibleHeight: 872), 838)
    }

    func testAHiddenDockGivesTheIslandTheDocksHeight() {
        let dockHidden = IslandScreen(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        // 982 − 8 = 974; less 32 and 14.
        XCTAssertEqual(IslandHeightRules.budget(on: dockHidden, screenVisibleHeight: 950), 928)
    }

    func testAHiddenMenuBarChangesNothingForTheIsland() {
        let menuBarHidden = IslandScreen(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 904),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        XCTAssertEqual(IslandHeightRules.budget(on: menuBarHidden, screenVisibleHeight: 872), 850)
    }

    func testANarrowNotchedDisplayHasALowerBudget() {
        // 878 − 78 = 800; less the 34 pt strip and 14.
        XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.narrowNotched, screenVisibleHeight: 774), 752)
        XCTAssertEqual(IslandHeightRules.rightColumnBudget(on: ScreenFixture.narrowNotched, screenVisibleHeight: 774), 740)
    }

    func testThePanelKeepsThe3xRule() {
        XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.externalRight, screenVisibleHeight: 1416), 1376)
        XCTAssertEqual(IslandHeightRules.outsideRightColumn(.panel), 70, "14 + 32 + 10 + 14")
        XCTAssertEqual(IslandHeightRules.outsideRightColumn(.island), 12)
        XCTAssertEqual(IslandHeightRules.rightColumnBudget(on: ScreenFixture.externalRight, screenVisibleHeight: 1416), 1306)
    }

    // MARK: - The lower row

    func testTheOtherHalfIsTheCostTileTheGapAndKeepAwake() {
        XCTAssertEqual(IslandHeightRules.otherColumn(costTile: 140, keepAwake: 138), 288)
        XCTAssertEqual(IslandHeightRules.otherColumn(costTile: nil, keepAwake: 138), 138)
        XCTAssertEqual(IslandHeightRules.otherColumn(costTile: nil, keepAwake: nil), 0)
    }

    func testWithTheAgentsHalfTallerTheListTakesWhatTheBudgetLeaves() {
        XCTAssertEqual(outcome(838, samples(fixed: 342)), .init(agentsListCap: 260, scrolls: false, rightColumn: 650))
        // 640 − 342 − 48 = 250: the list gives way and the column fits exactly.
        XCTAssertEqual(outcome(640, samples(fixed: 342)), .init(agentsListCap: 250, scrolls: false, rightColumn: 640))
    }

    func testTheListYieldsOnlyDownToTheOtherHalfsHeight() {
        // 620 would leave 230, but the cost tile and keep awake already make the row 288:
        // a list under 288 − 48 = 240 saves nothing, so it stops there and the column scrolls.
        XCTAssertEqual(outcome(620, samples(fixed: 342)), .init(agentsListCap: 240, scrolls: true, rightColumn: 630))
    }

    func testATallKeepAwakeCardLetsTheListFillItsHalfAndTheColumnScrolls() {
        // An approval line and a failure make keep awake 400: the row is 550.
        XCTAssertEqual(
            outcome(838, samples(fixed: 342, keepAwake: 400)),
            .init(agentsListCap: 260, scrolls: true, rightColumn: 892)
        )
    }

    func testWithoutAListTheColumnScrollsOnlyWhenItIsTooTall() {
        let noAgents = IslandHeightRules.Samples(rightColumn: 480, agentsColumn: 88, costTile: 140, keepAwake: 138, list: nil)
        XCTAssertEqual(outcome(838, noAgents), .init(agentsListCap: 260, scrolls: false, rightColumn: 480))
        XCTAssertEqual(outcome(400, noAgents), .init(agentsListCap: 260, scrolls: true, rightColumn: 480))
    }

    func testWithoutAnAgentsCardTheMeasuredColumnIsTheLayoutAndNothingIsCapped() {
        // Grok's page (owner 2026-10-30): no agents half, keep awake spans the row with its
        // controls on one line (104). Nothing yields, so the column stands as measured.
        let noAgentsCard = IslandHeightRules.Samples(rightColumn: 300 + 104, agentsColumn: nil, costTile: nil, keepAwake: 104, list: nil)
        XCTAssertEqual(outcome(838, noAgentsCard), .init(agentsListCap: 260, scrolls: false, rightColumn: 404))
        XCTAssertEqual(outcome(380, noAgentsCard), .init(agentsListCap: 260, scrolls: true, rightColumn: 404))
    }

    func testFiveProvidersFitThe14InchWithFiveRows() {
        // The cost tile is beside the fifth tile, so the lower row's other half is keep awake.
        XCTAssertEqual(
            outcome(838, samples(fixed: 472, costTile: nil)),
            .init(agentsListCap: 260, scrolls: false, rightColumn: 780)
        )
    }

    func testOnTheNarrowNotchedDisplayFiveProvidersTakeTheListTo220() {
        let budget = IslandHeightRules.rightColumnBudget(on: ScreenFixture.narrowNotched, screenVisibleHeight: 774)
        XCTAssertEqual(
            outcome(budget, samples(fixed: 472, costTile: nil)),
            .init(agentsListCap: 220, scrolls: false, rightColumn: 740)
        )
    }

    func testWhenTwoRowsCannotFitTheRightColumnScrolls() {
        XCTAssertEqual(
            outcome(560, samples(fixed: 472, costTile: nil)),
            .init(agentsListCap: 109, scrolls: true, rightColumn: 629)
        )
    }

    func testBeforeAnythingIsMeasuredTheListKeepsItsOldCap() {
        XCTAssertEqual(outcome(nil, samples(fixed: 342)), .init(agentsListCap: 260, scrolls: false, rightColumn: nil))
        XCTAssertEqual(outcome(838, IslandHeightRules.Samples()), .init(agentsListCap: 260, scrolls: false, rightColumn: nil))
    }

    // MARK: - What the rule guarantees

    func testTheCapIsAFixedPointOfTheLayoutItCauses() {
        for current in [109, 180, 250, 260] as [CGFloat] {
            XCTAssertEqual(outcome(640, samples(fixed: 342, cap: current)).agentsListCap, 250, "laid out at \(current)")
        }
    }

    func testTheFinalColumnFitsTheBudgetOrScrolls() {
        for fixed in [342, 472] as [CGFloat] {
            for keepAwake in [138, 400] as [CGFloat] {
                for budget in stride(from: 300 as CGFloat, through: 1000, by: 37) {
                    let result = outcome(budget, samples(fixed: fixed, keepAwake: keepAwake))
                    let after = samples(fixed: fixed, keepAwake: keepAwake, cap: result.agentsListCap).rightColumn
                    XCTAssertEqual(after, result.rightColumn, "the prediction is the layout")
                    XCTAssertEqual(result.scrolls, (after ?? 0) > budget, "\(fixed)/\(keepAwake) at \(budget)")
                }
            }
        }
    }

    func testAMeasurementThatIsNotANumberNeverGivesTheListANaNCap() {
        var broken = samples(fixed: 342)
        broken.rightColumn = .nan
        let fromColumn = outcome(838, broken).agentsListCap
        XCTAssertFalse(fromColumn.isNaN)
        XCTAssertTrue((109...260).contains(fromColumn), "got \(fromColumn)")

        var floorless = samples(fixed: 342)
        floorless.list = AgentsListGeometry(shownHeight: 260, minimumHeight: .nan, contentHeight: 330)
        let fromFloor = outcome(838, floorless).agentsListCap
        XCTAssertFalse(fromFloor.isNaN)
        XCTAssertTrue((109...260).contains(fromFloor), "got \(fromFloor)")
    }
}
