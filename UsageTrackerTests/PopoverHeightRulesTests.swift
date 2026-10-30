import XCTest
@testable import Omelette

/// Popover height budget spec 2026-10-27, § Design, § Tests, session calls Q1–Q2 and plan
/// rulings C1, C3, C4, R3: the agents list gives way to the screen. It takes what the
/// screen's visible height leaves after the popover's chrome and everything else in the
/// popover, never under its first
/// two rows, never over the old five-row cap.
final class PopoverHeightRulesTests: XCTestCase {
    /// Two rows before the list has measured itself: 54 + 1 + 54.
    private let twoEstimatedRows: CGFloat = 109

    private func cap(screen: CGFloat, fixed: CGFloat, minimum: CGFloat? = nil) -> CGFloat {
        PopoverHeightRules.agentsListHeight(
            budget: PopoverHeightRules.budget(screenVisibleHeight: screen),
            fixedHeight: fixed,
            minimumHeight: minimum ?? twoEstimatedRows
        )
    }

    func testTheBudgetIsTheVisibleHeightLessThePopoversChrome() {
        XCTAssertEqual(PopoverHeightRules.chrome, 40)
        XCTAssertEqual(PopoverHeightRules.budget(screenVisibleHeight: 945), 905)
        XCTAssertEqual(PopoverHeightRules.budget(screenVisibleHeight: 1400), 1360)
    }

    func testOnALargeScreenTheListKeepsItsFiveRows() {
        XCTAssertEqual(cap(screen: 1400, fixed: 600), 260)
    }

    func testOnTheFourteenInchWithRoomToSpareTheListStillStopsAtFiveRows() {
        // 945 − 40 − 600 = 305.
        XCTAssertEqual(cap(screen: 945, fixed: 600), 260)
    }

    /// Plan D6: 145 lies between two rows and five, so it stands.
    func testOnTheFourteenInchWithFiveTilesAndKeepAwakeTheListTakesWhatIsLeft() {
        // 945 − 40 − 760 = 145: two full rows and the top of a third.
        XCTAssertEqual(cap(screen: 945, fixed: 760), 145)
    }

    func testWhenTwoRowsDoNotFitTwoRowsItIs() {
        // 945 − 40 − 860 = 45 and 945 − 40 − 900 = 5.
        XCTAssertEqual(cap(screen: 945, fixed: 860), twoEstimatedRows)
        XCTAssertEqual(cap(screen: 945, fixed: 900), twoEstimatedRows)
    }

    func testANegativeOrZeroScreenHeightStillGivesTwoRows() {
        XCTAssertEqual(cap(screen: 0, fixed: 600), twoEstimatedRows)
        XCTAssertEqual(cap(screen: -100, fixed: 600), twoEstimatedRows)
    }

    /// Ruling C4: the floor is the first two rows as measured.
    func testTheFirstTwoRowsAsMeasuredSetTheFloor() {
        // The spec's measured row of 60: 60 + 1 + 60.
        XCTAssertEqual(cap(screen: 945, fixed: 900, minimum: 121), 121)
        // A 90 pt needs-you row with Allow/Deny over a 70 pt row: 90 + 1 + 70.
        XCTAssertEqual(cap(screen: 945, fixed: 900, minimum: 161), 161)
    }

    /// Plan D7: two very tall rows do not lift the cap past today's.
    func testTheCapNeverExceedsTheOldFiveRowCap() {
        XCTAssertEqual(AgentsSection.defaultMaxListHeight, 260)
        for screen: CGFloat in [-100, 0, 600, 945, 1400, 2400] {
            for fixed: CGFloat in [0, 300, 600, 760, 900] {
                for minimum: CGFloat in [54, 109, 161, 401] {
                    XCTAssertLessThanOrEqual(
                        cap(screen: screen, fixed: fixed, minimum: minimum),
                        AgentsSection.defaultMaxListHeight,
                        "screen \(screen), fixed \(fixed), minimum \(minimum)"
                    )
                }
            }
        }
        // Two 200 pt rows (401) are over the cap: the cap wins.
        XCTAssertEqual(cap(screen: 945, fixed: 900, minimum: 401), 260)
    }

    /// Plan D5: what is left rounds down, so the footer stays on screen; the floor rounds
    /// up, so the second row stays whole.
    func testTheCapIsAWholeNumberOfPoints() {
        // 945 − 40 − 700.4 = 204.6.
        XCTAssertEqual(cap(screen: 945, fixed: 700.4), 204)
        XCTAssertEqual(cap(screen: 945, fixed: 900, minimum: 110.4), 111)
    }

    /// A height that is not a number never reaches the list's frame. A NaN budget or fixed
    /// height leaves nothing to compute, so the list keeps today's cap, as with no screen;
    /// a NaN floor, or one below every height, counts as two unmeasured rows. Infinities
    /// still give the clamp's ends.
    func testAHeightThatIsNotANumberLeavesTheListAtTheOldCap() {
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: .nan, fixedHeight: 600, minimumHeight: 109), 260)
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: 905, fixedHeight: .nan, minimumHeight: 109), 260)
        // ∞ − ∞ is not a number either.
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: .infinity, fixedHeight: .infinity, minimumHeight: 109), 260)
        // 905 − 900 = 5 → two unmeasured rows.
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: 905, fixedHeight: 900, minimumHeight: .nan), twoEstimatedRows)
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: 905, fixedHeight: 900, minimumHeight: -.infinity), twoEstimatedRows)
        // The clamp's ends: an endless budget, none at all, and a floor over the cap.
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: .infinity, fixedHeight: 600, minimumHeight: 109), 260)
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: -.infinity, fixedHeight: 600, minimumHeight: 109), 109)
        XCTAssertEqual(PopoverHeightRules.agentsListHeight(budget: 905, fixedHeight: 900, minimumHeight: .infinity), 260)
    }

    // MARK: - Reviewer V4: an auto-hidden menu bar

    /// A 982-point screen whose menu bar (33) is shown: the visible frame stops below it, and
    /// is the height the popover has.
    func testAVisibleFrameThatLeavesTheMenuBarOutIsTheHeight() {
        XCTAssertEqual(
            PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 949, visibleFrameHeight: 900, menuBarHeight: 33),
            900
        )
    }

    /// With the menu bar set to hide, the visible frame reaches the screen's top, but the
    /// popover still opens below the menu bar: it loses the menu bar's height.
    func testAVisibleFrameThatReachesTheTopLosesTheMenuBar() {
        XCTAssertEqual(
            PopoverHeightRules.screenVisibleHeight(frameMaxY: 982, visibleFrameMaxY: 982, visibleFrameHeight: 933, menuBarHeight: 33),
            900
        )
    }
}
