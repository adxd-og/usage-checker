import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.3 (Height) and § 3.9
/// (`IslandHeightRules`), written from the spec and plan rulings R6, R7, R8: the budget
/// counts the notch once, the panel keeps the 3.x rule, the lower row is the taller of two
/// halves, the agents cap is a fixed point of the layout it causes, and the right column
/// scrolls only when the list's first two rows cannot fit.
final class IslandHeightRulesVerificationTests: XCTestCase {
    private func samples(
        fixed: CGFloat, chrome: CGFloat = 48, content: CGFloat = 330, minimum: CGFloat = 109,
        costTile: CGFloat? = 140, keepAwake: CGFloat = 138, cap: CGFloat = 260
    ) -> IslandHeightRules.Samples {
        let shown = min(content, cap)
        let agents = chrome + shown
        let other = IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake)
        return IslandHeightRules.Samples(
            rightColumn: fixed + max(agents, other), agentsColumn: agents, costTile: costTile, keepAwake: keepAwake,
            list: AgentsListGeometry(shownHeight: shown, minimumHeight: minimum, contentHeight: content)
        )
    }

    // MARK: - The budget

    func testTheNotchIsCountedOnceOnEveryNotchedDisplayWhateverTheVisibleHeightSays() {
        for screen in [ScreenFixture.builtIn, ScreenFixture.narrowNotched] {
            let notch = screen.notchRect!.height
            let dock = screen.visibleFrame.minY - screen.frame.minY
            // The window runs from the screen's top to 8 pt above the Dock (spec § 3.3).
            let window = screen.frame.height - dock - 8
            let expected = window - notch - IslandGeometry.islandBottomPadding
            for visible in [0, 500, screen.visibleFrame.height, 5_000] as [CGFloat] {
                XCTAssertEqual(IslandHeightRules.budget(on: screen, screenVisibleHeight: visible), expected, "visible \(visible)")
            }
            XCTAssertEqual(
                IslandHeightRules.rightColumnBudget(on: screen, screenVisibleHeight: 0), expected - IslandHeightRules.islandTopInset
            )
        }
        XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.builtIn, screenVisibleHeight: 872), 850)
    }

    func testAMenuBarAndDockThatBothAutoHideLeaveTheWholeScreenLessTheMarginAndTheStrip() {
        let bare = IslandScreen(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        // 982 − 8 − 32 − 14.
        XCTAssertEqual(IslandHeightRules.budget(on: bare, screenVisibleHeight: 982), 928)
    }

    func testThePanelKeepsThe3xRuleOnEveryNonNotchedDisplayWhateverItsFrame() {
        for visible in [600, 1056, 1416] as [CGFloat] {
            XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.externalLeft, screenVisibleHeight: visible), visible - 40)
            XCTAssertEqual(IslandHeightRules.budget(on: ScreenFixture.externalRight, screenVisibleHeight: visible), visible - 40)
            XCTAssertEqual(
                IslandHeightRules.budget(on: ScreenFixture.externalRight, screenVisibleHeight: visible),
                PopoverHeightRules.budget(screenVisibleHeight: visible)
            )
        }
    }

    func testASafeAreaWithoutAuxiliaryAreasIsNoNotchSoItIsThePanelsRule() {
        let odd = IslandScreen(
            id: 9, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 872),
            safeAreaTop: 32, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        XCTAssertEqual(IslandHeightRules.budget(on: odd, screenVisibleHeight: 872), 832)
        XCTAssertEqual(IslandHeightRules.outsideRightColumn(.panel), 2 * 14 + 32 + 10)
    }

    // MARK: - The lower row and the cap

    func testTheOutcomeIsTheSameWhateverCapTheMeasurementsWereTakenAt() {
        for chrome in [48, 60] as [CGFloat] {
            for content in [60, 150, 330, 900] as [CGFloat] {
                for costTile in [nil, 140] as [CGFloat?] {
                    for budget in [400, 560, 640, 740, 838, 1200] as [CGFloat] {
                        let outcomes = [109, 180, 260].map { (at: CGFloat) in
                            IslandHeightRules.outcome(
                                rightBudget: budget,
                                samples: samples(fixed: 342, chrome: chrome, content: content, costTile: costTile, cap: at)
                            )
                        }
                        let label = "chrome \(chrome) content \(content) cost \(String(describing: costTile)) budget \(budget)"
                        XCTAssertEqual(outcomes[0], outcomes[1], label)
                        XCTAssertEqual(outcomes[1], outcomes[2], label)
                    }
                }
            }
        }
    }

    func testTheCapNeverRisesWhenTheFixedPartGrowsAndNeverPassesTheListsOwnCeiling() {
        var previous: CGFloat = .greatestFiniteMagnitude
        for fixed in stride(from: 200 as CGFloat, through: 800, by: 25) {
            let cap = IslandHeightRules.outcome(rightBudget: 740, samples: samples(fixed: fixed)).agentsListCap
            XCTAssertLessThanOrEqual(cap, previous, "fixed \(fixed)")
            XCTAssertLessThanOrEqual(cap, AgentsSection.defaultMaxListHeight)
            XCTAssertGreaterThanOrEqual(cap, 109)
            previous = cap
        }
    }

    func testTheListNeverYieldsBelowWhatTheOtherHalfAlreadyCosts() {
        // Cost tile 140 + gap 10 + keep awake 138 = 288; the agents card is 48 without its list.
        for budget in stride(from: 300 as CGFloat, through: 900, by: 20) {
            let cap = IslandHeightRules.outcome(rightBudget: budget, samples: samples(fixed: 342)).agentsListCap
            XCTAssertGreaterThanOrEqual(cap, min(AgentsSection.defaultMaxListHeight, 288 - 48), "budget \(budget)")
        }
    }

    // MARK: - The scroll fallback

    /// The column's least height: the list at its floor (or its rows, if fewer), against
    /// the other half.
    private func leastColumn(fixed: CGFloat, chrome: CGFloat, content: CGFloat, minimum: CGFloat, costTile: CGFloat?, keepAwake: CGFloat) -> CGFloat {
        fixed + max(chrome + min(content, minimum), IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake))
    }

    func testTheColumnScrollsExactlyWhenEvenTheFirstTwoRowsCannotFit() {
        for fixed in [342, 472, 600] as [CGFloat] {
            for content in [60, 109, 200, 330, 1_000] as [CGFloat] {
                for keepAwake in [138, 400] as [CGFloat] {
                    for costTile in [nil, 140] as [CGFloat?] {
                        let least = leastColumn(fixed: fixed, chrome: 48, content: content, minimum: 109, costTile: costTile, keepAwake: keepAwake)
                        for budget in [least - 40, least - 1, least, least + 1, least + 40, 1_400] {
                            let result = IslandHeightRules.outcome(
                                rightBudget: budget,
                                samples: samples(fixed: fixed, content: content, costTile: costTile, keepAwake: keepAwake)
                            )
                            XCTAssertEqual(
                                result.scrolls, budget < least,
                                "fixed \(fixed) content \(content) keep \(keepAwake) cost \(String(describing: costTile)) budget \(budget) least \(least)"
                            )
                            if !result.scrolls, let column = result.rightColumn {
                                XCTAssertLessThanOrEqual(column, budget)
                            }
                        }
                    }
                }
            }
        }
    }

    func testAListThatFitsAtItsFullHeightNeverScrollsHoweverTightTheBudgetIsToTheCap() {
        // Two rows of content (109): the list is already at its floor; a budget that fits it
        // exactly must not scroll.
        let tight = samples(fixed: 342, content: 109, costTile: nil, keepAwake: 60)
        let fits = 342 + 48 + 109
        XCTAssertFalse(IslandHeightRules.outcome(rightBudget: CGFloat(fits), samples: tight).scrolls)
        XCTAssertTrue(IslandHeightRules.outcome(rightBudget: CGFloat(fits - 1), samples: tight).scrolls)
    }

    func testWithoutAMeasuredColumnNothingScrollsAndNothingIsPredicted() {
        for budget in [0, 100, 838] as [CGFloat] {
            let result = IslandHeightRules.outcome(rightBudget: budget, samples: .init())
            XCTAssertEqual(result, .init(agentsListCap: 260, scrolls: false, rightColumn: nil))
        }
        let measured = IslandHeightRules.Samples(rightColumn: 500)
        XCTAssertEqual(IslandHeightRules.outcome(rightBudget: nil, samples: measured).scrolls, false, "no budget, no scroll")
    }

    func testAListThatHasMeasuredButWhoseCardHasNotYetReportedKeepsTheOldCap() {
        var half = samples(fixed: 342)
        half.agentsColumn = nil
        XCTAssertEqual(IslandHeightRules.outcome(rightBudget: 640, samples: half).agentsListCap, 260)
    }
}
