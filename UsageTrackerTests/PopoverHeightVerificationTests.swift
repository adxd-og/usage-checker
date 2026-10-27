import XCTest
@testable import Omelette

/// Popover height budget spec 2026-10-27, § Design and § Tests: edges of the clamp, of the
/// samples and of the kept string that `PopoverHeightRulesTests` and `AgentsSectionTests`
/// do not reach.
final class PopoverHeightVerificationTests: XCTestCase {
    private func cap(budget: CGFloat, fixed: CGFloat, minimum: CGFloat = 109) -> CGFloat {
        PopoverHeightRules.agentsListHeight(budget: budget, fixedHeight: fixed, minimumHeight: minimum)
    }

    private func kept(_ fixed: CGFloat, _ minimum: CGFloat) -> PopoverHeightRules.Persisted {
        PopoverHeightRules.Persisted(fixedHeight: fixed, minimumHeight: minimum)
    }

    private func samples(popover: CGFloat?, shown: CGFloat, minimum: CGFloat = 109) -> PopoverHeightRules.Samples {
        PopoverHeightRules.Samples(
            popoverHeight: popover,
            list: AgentsListGeometry(shownHeight: shown, minimumHeight: minimum)
        )
    }

    // MARK: - The clamp

    /// Budget exactly at the floor, a hair under it, and the first whole point over it.
    func testTheCapAtTheFloorBoundary() {
        XCTAssertEqual(cap(budget: 709, fixed: 600), 109)
        XCTAssertEqual(cap(budget: 708.9, fixed: 600), 109)
        XCTAssertEqual(cap(budget: 710, fixed: 600), 110)
        XCTAssertEqual(cap(budget: 709.9, fixed: 600), 109, "the rest rounds down")
    }

    /// The cap boundary: 260 left gives 260, 261 left and a fraction over still 260.
    func testTheCapAtTheCeilingBoundary() {
        XCTAssertEqual(cap(budget: 860, fixed: 600), 260)
        XCTAssertEqual(cap(budget: 859.9, fixed: 600), 259)
        XCTAssertEqual(cap(budget: 861, fixed: 600), 260)
    }

    /// Whole-point rounding at .5: the rest goes down, the floor goes up.
    func testHalfPointsRoundTheRestDownAndTheFloorUp() {
        XCTAssertEqual(cap(budget: 905, fixed: 700.5), 204)
        XCTAssertEqual(cap(budget: 905, fixed: 699.5), 205)
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 110.5), 111)
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 110), 110)
    }

    /// A negative remainder (fixed height over the budget) is floored by the minimum, with
    /// the floor's own rounding applied.
    func testANegativeRemainderGivesTheFloor() {
        XCTAssertEqual(cap(budget: 100, fixed: 900), 109)
        XCTAssertEqual(cap(budget: 100, fixed: 100.5), 109, "-0.5 rounds down to -1, still under the floor")
        XCTAssertEqual(cap(budget: 100, fixed: 900, minimum: 120.2), 121)
    }

    /// § Design: two rows are the least, five rows the most, and where two tall rows cross
    /// the five-row cap, the cap wins (plan D7).
    func testWhenTheFloorExceedsTheCeilingTheCeilingWins() {
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 260), 260)
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 260.5), 260, "261 rounded up is over the cap")
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 400), 260)
        XCTAssertEqual(cap(budget: 905, fixed: 0, minimum: 400), 260)
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: .infinity), 260)
    }

    /// An absent floor (the first row alone: a single short row 54, or zero rows 0) still
    /// clamps to what is left, not above the cap.
    func testASingleRowOrEmptyFloorStillClamps() {
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 54), 54)
        XCTAssertEqual(cap(budget: 905, fixed: 900, minimum: 0), 5)
        XCTAssertEqual(cap(budget: 905, fixed: 905, minimum: 0), 0)
    }

    /// Infinite screens and heights give the clamp's ends.
    func testInfiniteInputsClampToTheEnds() {
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: .infinity, samples: nil, persisted: kept(600, 109)), 260)
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: -.infinity, samples: nil, persisted: kept(600, 109)), 109)
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: samples(popover: .infinity, shown: 100), persisted: nil), 109)
    }

    /// A screen height or sample that is not a number must not reach `AgentsSection` as a
    /// NaN frame height: the cap stays inside [floor, 260].
    func testNaNInputsStayInsideTheClamp() {
        let nanScreen = PopoverHeightRules.agentsListCap(screenVisibleHeight: .nan, samples: nil, persisted: kept(600, 109))
        XCTAssertFalse(nanScreen.isNaN, "a NaN screen height gave a NaN cap")
        XCTAssertTrue((109...260).contains(nanScreen), "got \(nanScreen)")

        let nanPopover = PopoverHeightRules.agentsListCap(
            screenVisibleHeight: 945, samples: samples(popover: .nan, shown: 100), persisted: nil
        )
        XCTAssertFalse(nanPopover.isNaN, "a NaN popover sample gave a NaN cap")
        XCTAssertTrue((109...260).contains(nanPopover), "got \(nanPopover)")

        let nanFixed = PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: nil, persisted: kept(.nan, 109))
        XCTAssertFalse(nanFixed.isNaN, "a NaN kept fixed height gave a NaN cap")
    }

    // MARK: - Samples

    /// A list taller than the popover (the two samples came from different layout passes):
    /// fixed is negative, which only widens the room and never breaks the clamp.
    func testAListTallerThanThePopoverGivesANegativeFixedHeight() {
        let s = samples(popover: 100, shown: 260)
        XCTAssertEqual(PopoverHeightRules.fixedHeight(s, persisted: 700), -160)
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: 945, samples: s, persisted: nil), 260)
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(screenVisibleHeight: 100, samples: s, persisted: nil),
            220,
            "budget 60, fixed -160: 220 left"
        )
    }

    /// Samples with a popover height beat the kept pair even when the sampled pair is the
    /// smaller number; a sample without a popover height never does.
    func testSamplesWithAPopoverHeightBeatTheKeptPair() {
        XCTAssertEqual(PopoverHeightRules.fixedHeight(samples(popover: 500, shown: 100), persisted: 900), 400)
        XCTAssertEqual(PopoverHeightRules.fixedHeight(samples(popover: nil, shown: 100), persisted: 900), 900)
        XCTAssertNil(PopoverHeightRules.fixedHeight(samples(popover: nil, shown: 100), persisted: nil))
        XCTAssertNil(PopoverHeightRules.fixedHeight(PopoverHeightRules.Samples(), persisted: nil))
        XCTAssertEqual(PopoverHeightRules.fixedHeight(PopoverHeightRules.Samples(), persisted: 321), 321)
    }

    /// The floor falls back sample -> kept -> two unmeasured rows, while the fixed height
    /// is chosen independently of it.
    func testTheFloorFallsBackSampleThenKeptThenEstimate() {
        // List report present: its floor, whatever the kept one says.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: samples(popover: 1000, shown: 100, minimum: 121), persisted: kept(0, 161)
            ),
            121
        )
        // No list report: the kept floor.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945,
                samples: PopoverHeightRules.Samples(popoverHeight: 1000, list: nil),
                persisted: kept(0, 161)
            ),
            161
        )
        // Neither: 109.
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(
                screenVisibleHeight: 945, samples: PopoverHeightRules.Samples(popoverHeight: 1000, list: nil), persisted: nil
            ),
            109
        )
    }

    /// No screen: today's cap whatever the samples (spec Design: "falling back" is the
    /// controller's job; with no height at all the list keeps 260).
    func testNoScreenKeepsTodaysCapWithOrWithoutSamples() {
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: nil, samples: nil, persisted: nil), 260)
        XCTAssertEqual(PopoverHeightRules.agentsListCap(screenVisibleHeight: nil, samples: nil, persisted: kept(900, 109)), 260)
        XCTAssertEqual(
            PopoverHeightRules.agentsListCap(screenVisibleHeight: nil, samples: samples(popover: 2000, shown: 100), persisted: kept(900, 109)),
            260
        )
    }

    /// Q1: a cap change moves the popover and the list by the same amount, so the fixed
    /// height does not move, and the cap it gives back is the cap that produced the
    /// samples, for every cap, on every screen, including quarter-point layouts.
    func testTheFixedHeightIsInvariantToTheCapAndTheCapIsAFixedPoint() {
        for screen: CGFloat in [700, 945, 1117, 1400] {
            for fixed in stride(from: CGFloat(300), through: 1000, by: 12.25) {
                let first = PopoverHeightRules.agentsListCap(
                    screenVisibleHeight: screen, samples: samples(popover: fixed + 200, shown: 200), persisted: nil
                )
                let again = PopoverHeightRules.agentsListCap(
                    screenVisibleHeight: screen, samples: samples(popover: fixed + first, shown: first), persisted: nil
                )
                XCTAssertEqual(again, first, "screen \(screen), fixed \(fixed)")
                XCTAssertEqual(
                    PopoverHeightRules.fixedHeight(samples(popover: fixed + first, shown: first), persisted: nil),
                    fixed,
                    "screen \(screen), fixed \(fixed)"
                )
            }
        }
    }

    // MARK: - The kept string

    func testAnEmptyStringReadsNothingAndWritesTheOneEntry() {
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: ""))
        XCTAssertNil(PopoverHeightRules.persisted(for: "", in: ""))
        XCTAssertEqual(PopoverHeightRules.storing(kept(0, 0), for: "all", in: ""), "all=0/0")
    }

    func testATrailingOrDoubledCommaStillReadsTheEntries() {
        XCTAssertEqual(PopoverHeightRules.persisted(for: "all", in: "all=812/161,"), kept(812, 161))
        XCTAssertEqual(PopoverHeightRules.persisted(for: "claude", in: ",,all=812/161,,claude=905/109,"), kept(905, 109))
        XCTAssertEqual(PopoverHeightRules.storing(kept(1, 2), for: "x", in: "all=812/161,"), "all=812/161,x=1/2")
    }

    func testNegativeAndNonNumericEntriesAreIgnored() {
        let stored = "a=-1/109,b=109/-1,c=1.5/109,d=109/1.5,e= 812/109,f=812 /109,g=0x10/109,h=/,i=1e3/109"
        for tab in ["a", "b", "c", "d", "e", "f", "g", "h", "i"] {
            XCTAssertNil(PopoverHeightRules.persisted(for: tab, in: stored), tab)
        }
    }

    func testAnEntryWithoutATabIdOrWithAnExtraEqualsSignIsIgnored() {
        XCTAssertNil(PopoverHeightRules.persisted(for: "", in: "=812/109"))
        XCTAssertNil(PopoverHeightRules.persisted(for: "a", in: "a=b=812/109"))
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all=812/109/5"))
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all 812/109"))
    }

    /// An entry too big for an Int is not a reading.
    func testAnIntegerOverflowIsIgnored() {
        XCTAssertNil(PopoverHeightRules.persisted(for: "all", in: "all=99999999999999999999/109"))
    }

    /// Duplicate tab ids: one entry survives and a write leaves exactly one.
    func testDuplicateTabIdsLeaveOneEntry() {
        let stored = "all=1/2,all=3/4"
        let read = PopoverHeightRules.persisted(for: "all", in: stored)
        XCTAssertNotNil(read)
        let written = PopoverHeightRules.storing(kept(5, 6), for: "claude", in: stored)
        XCTAssertEqual(written.split(separator: ",").filter { $0.hasPrefix("all=") }.count, 1)
        XCTAssertEqual(PopoverHeightRules.storing(kept(7, 8), for: "all", in: stored), "all=7/8")
    }

    /// Writing never keeps what does not read and the output is in tab-id order whatever
    /// the order it came in.
    func testStoringSortsTabsAndDropsEntriesThatNoLongerRead() {
        let stored = "grok=3/4,junk,codex=5/x,all=1/2"
        XCTAssertEqual(PopoverHeightRules.storing(kept(9, 9), for: "claude", in: stored), "all=1/2,claude=9/9,grok=3/4")
    }

    /// A write is a fixed point for what it wrote: storing the same pair again changes
    /// nothing (the view writes only when the string changes), and the pair reads back
    /// rounded up to whole points.
    func testStoringTheSamePairTwiceChangesNothing() {
        let once = PopoverHeightRules.storing(kept(812.2, 160.01), for: "all", in: "claude=905/109")
        XCTAssertEqual(once, "all=813/161,claude=905/109")
        XCTAssertEqual(PopoverHeightRules.storing(kept(812.2, 160.01), for: "all", in: once), once)
        XCTAssertEqual(PopoverHeightRules.persisted(for: "all", in: once), kept(813, 161))
        // And a whole-point pair is kept as it is, not bumped by one.
        XCTAssertEqual(PopoverHeightRules.storing(kept(812, 161), for: "all", in: ""), "all=812/161")
    }

    /// Refused values leave the string untouched, bound included: 99 999.5 is stored,
    /// 100 000 is not; infinity and NaN never are, in either field.
    func testRefusedValuesLeaveTheStringAsItWas() {
        let stored = "claude=905/109"
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, .infinity), for: "all", in: stored), stored)
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, .nan), for: "all", in: stored), stored)
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, -1), for: "all", in: stored), stored)
        XCTAssertEqual(PopoverHeightRules.storing(kept(100_000, 109), for: "all", in: stored), stored)
        XCTAssertEqual(PopoverHeightRules.storing(kept(760, 100_000), for: "all", in: stored), stored)
        XCTAssertEqual(PopoverHeightRules.storing(kept(99_999.5, 109), for: "all", in: stored), "all=100000/109,claude=905/109")
        // A refused write on a string holding junk does not clean it either.
        XCTAssertEqual(PopoverHeightRules.storing(kept(-1, 109), for: "all", in: "junk"), "junk")
    }

    /// A value that reads but is absurd (it came from outside) must not make the next
    /// write of another tab trap on a conversion to Int.
    func testAnAbsurdKeptValueDoesNotBreakTheNextWrite() {
        let stored = "evil=9223372036854775807/1"
        let written = PopoverHeightRules.storing(kept(760, 109), for: "all", in: stored)
        XCTAssertTrue(written.contains("all=760/109"), written)
    }

    // MARK: - The two-row floor

    /// Second row measured, first not: the first counts as the estimate.
    func testOneMeasuredRowAndOneUnmeasuredRow() {
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: ["b": 70]), 54 + 1 + 70)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: ["a": 90]), 90 + 1 + 54)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: [:]), 109)
    }

    /// Cached heights of rows outside the first two, or no longer in the list, do not move
    /// the floor; only ids in the first two positions count.
    func testRowsOutsideTheFirstTwoDoNotMoveTheFloor() {
        let heights: [String: CGFloat] = ["a": 60, "b": 62, "c": 300, "gone": 500]
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b", "c"], rowHeights: heights), 60 + 1 + 62)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: heights), 123)
        // A single row with a stale second entry in the cache.
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a"], rowHeights: heights), 60)
        // Ids missing from the cache entirely.
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["x", "y"], rowHeights: heights), 109)
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: [], rowHeights: [:]), 0)
    }

    /// A measured height of zero is a measurement, not "missing".
    func testAMeasuredZeroIsNotTheEstimate() {
        XCTAssertEqual(AgentsSection.minimumListHeight(rowIDs: ["a", "b"], rowHeights: ["a": 0, "b": 0]), 1)
    }
}

/// Spec § Design and Q1: the cap is a fixed point of the layout it causes. A tiny SwiftUI
/// stand-in lays the popover out for the model's current cap (list = content up to the cap,
/// popover = the rest + list) and reports both measurements, in either order, until the
/// cap stops moving.
@MainActor
final class PopoverHeightModelVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Layout {
        let rest: CGFloat      // everything but the list
        let content: CGFloat   // the list's natural height
        func shown(_ cap: CGFloat) -> CGFloat { min(content, cap) }
        func popover(_ cap: CGFloat) -> CGFloat { rest + shown(cap) }
    }

    private func expectedCap(screen: CGFloat, rest: CGFloat) -> CGFloat {
        min(max((screen - 40 - rest).rounded(.down), 109), 260)
    }

    /// Both measurements of one layout pass reach the model before the next pass.
    func testTheCapSettlesInOnePassWhicheverReportComesFirst() {
        for listFirst in [true, false] {
            for screen: CGFloat in [945, 1117, 1400] {
                for rest: CGFloat in [500, 640, 760, 860, 950] {
                    for content: CGFloat in [54, 109, 145, 330, 700] {
                        let layout = Layout(rest: rest, content: content)
                        let model = PopoverHeightModel(stored: "", now: { self.t0 })
                        model.setScreen(visibleHeight: screen)
                        var settled = false
                        for _ in 0..<4 {
                            let cap = model.cap(for: "all")
                            let list = AgentsListGeometry(shownHeight: layout.shown(cap), minimumHeight: 109)
                            if listFirst {
                                model.recordAgentsList(list, tab: "all")
                                model.recordPopoverHeight(layout.popover(cap), tab: "all")
                            } else {
                                model.recordPopoverHeight(layout.popover(cap), tab: "all")
                                model.recordAgentsList(list, tab: "all")
                            }
                            if model.cap(for: "all") == cap { settled = true; break }
                        }
                        // A list shorter than its floor can not be capped under its content.
                        if content >= 109 {
                            XCTAssertTrue(settled, "listFirst \(listFirst), screen \(screen), rest \(rest), content \(content)")
                            XCTAssertEqual(
                                model.cap(for: "all"), expectedCap(screen: screen, rest: rest),
                                "listFirst \(listFirst), screen \(screen), rest \(rest), content \(content)"
                            )
                        }
                    }
                }
            }
        }
    }
}
