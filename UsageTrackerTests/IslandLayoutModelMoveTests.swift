import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Height) during a page move (§ 3.2; P3b plan ruling R2,
/// Codex re-review finding 2): the model hands the rules the destination as it will lay out at
/// rest, from the column and the move drawn in the same pass, so the agents list's cap holds at
/// the destination's pass after pass whichever report comes first; the island is drawn at the
/// column as drawn; at rest nothing changes.
@MainActor
final class IslandLayoutModelMoveTests: XCTestCase {
    private enum Order { case lowerRowFirst, columnFirst }

    /// The 14-inch island: right budget 838.
    private func placed() -> IslandLayoutModel {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        return model
    }

    /// One layout pass halfway through a move between two pages whose stages are 300 tall, the
    /// rest of the column 290 (so `fixed` is 590): the list takes the model's cap under the agents
    /// card's 48 of chrome, the lower row lays out at its taller half (keep awake 138), the drawn
    /// lower row goes halfway from the page left's 308 to the destination's last measured height,
    /// and the reports arrive in `order`. Returns the lower row as it laid out: the destination's
    /// measured height for the next pass. Codex's replay of revision 2 (2026-10-30), whose caps
    /// ran 200, 140, 140, 200, 260, 260 …
    private func pass(_ model: IslandLayoutModel, measured: CGFloat, order: Order) -> CGFloat {
        let shown = min(600, model.agentsListCap)
        let agents = 48 + shown
        let lowerDrawn = 308 + (measured - 308) * 0.5
        let move = IslandHeightRules.MoveHeights(stageDrawn: 300, stageAtRest: 300, lowerRowDrawn: lowerDrawn)
        let list = AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: 600)
        switch order {
        case .lowerRowFirst:
            model.record(list: list)
            model.record(agentsColumn: agents)
            model.record(keepAwake: 138)
            model.record(rightColumn: 590 + lowerDrawn, move: move)
        case .columnFirst:
            model.record(rightColumn: 590 + lowerDrawn, move: move)
            model.record(keepAwake: 138)
            model.record(agentsColumn: agents)
            model.record(list: list)
        }
        return max(agents, 138)
    }

    func testReplayedPassesHoldTheCapAtTheDestinationsWhicheverReportComesFirst() {
        for order in [Order.lowerRowFirst, .columnFirst] {
            let model = placed()
            var measured: CGFloat = 308
            var caps: [CGFloat] = []
            for _ in 0..<8 {
                measured = pass(model, measured: measured, order: order)
                caps.append(model.agentsListCap)
            }
            XCTAssertEqual(caps, Array(repeating: 200, count: 8), "\(order)")
        }
    }

    func testDuringAMoveTheRulesReadTheDestinationAtRestAndTheIslandShowsTheColumnAsDrawn() {
        let list = AgentsListGeometry(shownHeight: 200, minimumHeight: 109, contentHeight: 600)
        let moving = placed()
        moving.record(list: list)
        moving.record(agentsColumn: 248)
        moving.record(keepAwake: 138)
        moving.record(rightColumn: 805, move: IslandHeightRules.MoveHeights(stageDrawn: 275, stageAtRest: 300, lowerRowDrawn: 240))
        let rest = placed()
        rest.record(list: list)
        rest.record(agentsColumn: 248)
        rest.record(keepAwake: 138)
        rest.record(rightColumn: 838) // 805 − 275 − 240 + 300 + 248: the destination at rest
        XCTAssertEqual(moving.agentsListCap, rest.agentsListCap)
        XCTAssertEqual(moving.agentsListCap, 200)
        XCTAssertEqual(moving.scrolls, rest.scrolls)
        XCTAssertEqual(moving.rightColumnViewport, 805, "the island at the column as drawn")
        XCTAssertEqual(rest.rightColumnViewport, 838)
    }

    func testAtRestTheMoveIsGoneAndTheColumnReadsAsDrawn() {
        let model = placed()
        model.record(list: AgentsListGeometry(shownHeight: 200, minimumHeight: 109, contentHeight: 600))
        model.record(agentsColumn: 248)
        model.record(keepAwake: 138)
        model.record(rightColumn: 805, move: IslandHeightRules.MoveHeights(stageDrawn: 275, stageAtRest: 300, lowerRowDrawn: 240))
        model.record(rightColumn: 838, move: nil)
        XCTAssertNil(model.move)
        XCTAssertEqual(model.agentsListCap, 200)
        XCTAssertEqual(model.rightColumnViewport, 838)
    }
}
