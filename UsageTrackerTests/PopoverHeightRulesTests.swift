import XCTest
@testable import Omelette

/// Popover height budget spec 2026-10-27, § Design, § Tests, session calls Q1–Q2 and plan
/// rulings C1, C3, C4, R3: the agents list gives way to the screen. It takes what the
/// screen's visible height leaves after the popover's chrome and everything else in the
/// popover (sampled on the same tab, or kept from an earlier open), never under its first
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

    private func samples(popover: CGFloat?, shown: CGFloat, minimum: CGFloat = 109) -> PopoverHeightRules.Samples {
        PopoverHeightRules.Samples(
            popoverHeight: popover,
            list: AgentsListGeometry(shownHeight: shown, minimumHeight: minimum)
        )
    }

    private func kept(_ fixed: CGFloat, _ minimum: CGFloat) -> PopoverHeightRules.Persisted {
        PopoverHeightRules.Persisted(fixedHeight: fixed, minimumHeight: minimum)
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

    // MARK: - From what the popover measured

    /// Plan D8: no screen known, the list keeps today's cap.
    func testWithNoScreenKnownTheListKeepsTheOldCap() {
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: nil, samples: samples(popover: 1200, shown: 260), persisted: kept(600, 109)
            ),
            260
        )
    }

    /// Ruling C1: the fixed height is the popover less the list, both sampled on the tab.
    func testTheFixedHeightIsThePopoverLessTheListBothSampledOnTheTab() {
        XCTAssertEqual(PopoverHeightRules.fixedHeight(samples(popover: 900, shown: 140), persisted: nil), 760)
        // A tab without a list: all of the popover is fixed.
        XCTAssertEqual(
            PopoverHeightRules.fixedHeight(PopoverHeightRules.Samples(popoverHeight: 760, list: nil), persisted: nil),
            760
        )
        // 905 − (900 − 140) = 145.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: samples(popover: 900, shown: 140), persisted: nil
            ),
            145
        )
        // The list's floor reaches the cap: 905 − (1000 − 100) = 5 → 161.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: samples(popover: 1000, shown: 100, minimum: 161), persisted: nil
            ),
            161
        )
        // No list report and nothing kept: two unmeasured rows.
        XCTAssertEqual(PopoverHeightRules.unmeasuredMinimumHeight, 109)
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945,
                samples: PopoverHeightRules.Samples(popoverHeight: 900, list: nil),
                persisted: nil
            ),
            twoEstimatedRows
        )
    }

    /// Rulings C1, C3 and R3: a tab with no popover sample of its own (the first open after a
    /// launch) takes the fixed height and the floor it kept from its last open; a fresh list
    /// report beats the kept floor, and once the tab has sampled the popover, its own pair
    /// wins.
    func testATabWithNoSamplesUsesWhatItKeptFromTheLastOpen() {
        XCTAssertEqual(PopoverHeightRules.fixedHeight(nil, persisted: 760), 760)
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: nil, persisted: kept(760, 109)), 145)
        // Two tall leading rows kept from the last open: 905 − 860 = 45 → their 161.
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: nil, persisted: kept(860, 161)), 161)
        // A list report without the popover's sample is no pair: the kept fixed height, the
        // fresh floor.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: samples(popover: nil, shown: 100, minimum: 121), persisted: kept(860, 161)
            ),
            121
        )
        // 905 − (805 − 100) = 200.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: samples(popover: 805, shown: 100), persisted: kept(760, 161)
            ),
            200
        )
    }

    /// Ruling C3: only a fresh install, with nothing sampled and nothing kept, starts from
    /// today's cap.
    func testAFreshInstallStartsAtTodaysCap() {
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: nil, persisted: nil), 260)
    }

    /// § Design and Q1: no feedback loop. A new cap moves the tab's popover and list
    /// samples by the same amount, so the cap they give back is the one that produced them.
    func testTheCapItProducesIsTheCapItGetsBack() {
        for shown: CGFloat in [109, 145, 205, 260] {
            XCTAssertEqual(
                PopoverHeightRules.agentsListCap(
                    screenVisibleHeight: 945, samples: samples(popover: 700 + shown, shown: shown), persisted: nil
                ),
                205,
                "shown \(shown)"
            )
        }
    }

    // MARK: - Kept across launches (plan D13)

    func testATabsFixedHeightAndFloorAreStoredAndReadBack() {
        XCTAssertEqual(PopoverHeightRules.fixedHeightsKey, "popoverFixedHeights")
        let all = PopoverHeightRules.storing(kept(812, 161), for: "all", in: "")
        XCTAssertEqual(all, "all=812/161")
        // Whole points rounded up, tabs in id order.
        let both = PopoverHeightRules.storing(kept(904.2, 108.6), for: "claude", in: all)
        XCTAssertEqual(both, "all=812/161,claude=905/109")
        XCTAssertEqual(PopoverHeightRules.persisted(for: "claude", in: both), kept(905, 109))
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, 109), for: "all", in: both), "all=760/109,claude=905/109")
        XCTAssertNil(PopoverHeightRules.persisted(for: "codex", in: both))
    }

    /// Ruling R3: a malformed or partial entry is ignored and dropped at the next write; an
    /// impossible value is neither stored nor read back.
    func testAMalformedOrPartialEntryIsIgnored() {
        let stored = "all=812,codex=812/,grok=/161,antigravity=tall/109,claude=905/109/1,orphan"
        for tab in ["all", "codex", "grok", "antigravity", "claude", "orphan"] {
            XCTAssertNil(PopoverHeightRules.persisted(for: tab, in: stored), tab)
        }
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, 109), for: "all", in: "all=812,claude=905/109"), "all=760/109,claude=905/109")
        XCTAssertEqual(PopoverHeightRules.storing(kept(-5, 109), for: "all", in: "claude=905/109"), "claude=905/109")
        XCTAssertEqual(PopoverHeightRules.storing(kept(.nan, 109), for: "all", in: "claude=905/109"), "claude=905/109")
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, 1_000_000), for: "all", in: "claude=905/109"), "claude=905/109")
        // The read path holds the write path's ceiling: a height of 100 000 pt or more does
        // not read back, so it never reaches the next write's conversion to whole points.
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all=100000/109"))
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all=760/100000"))
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all=9223372036854775807/1"))
        XCTAssertEqual(PopoverHeightRules.persisted(for: "all", in: "all=99999/109"), kept(99_999, 109))
    }
}
