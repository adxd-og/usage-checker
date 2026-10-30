import XCTest
@testable import Omelette

/// Popover height budget spec 2026-10-27, § Design and § Tests: edges of the clamp and of
/// the two-row floor that `PopoverHeightRulesTests` and `AgentsSectionTests`
/// do not reach.
final class PopoverHeightVerificationTests: XCTestCase {
    private func cap(budget: CGFloat, fixed: CGFloat, minimum: CGFloat = 109) -> CGFloat {
        PopoverHeightRules.agentsListHeight(budget: budget, fixedHeight: fixed, minimumHeight: minimum)
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
