import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 (Height) during a page move (§ 3.2; P3b plan ruling R2,
/// Codex re-review finding 2): the rules read the destination as it will lay out at rest — the
/// column as drawn, less the stage and the lower row as drawn, plus the destination's stage and
/// its lower row's taller half — so what they call `fixed` never depends on the agents list.
final class IslandHeightRulesMoveTests: XCTestCase {
    func testTheRestingColumnTakesTheDrawnMoveOutAndTheDestinationIn() {
        let samples = IslandHeightRules.Samples(agentsColumn: 248, keepAwake: 138)
        let move = IslandHeightRules.MoveHeights(stageDrawn: 275, stageAtRest: 300, lowerRowDrawn: 278)
        // 843 − 275 − 278 + 300 + max(248, 138)
        XCTAssertEqual(IslandHeightRules.restingColumn(drawn: 843, move: move, samples: samples), 838)
    }

    func testWithoutAnAgentsCardTheLowerRowIsItsOtherHalf() {
        let samples = IslandHeightRules.Samples(costTile: 92, keepAwake: 138)
        let move = IslandHeightRules.MoveHeights(stageDrawn: 250, stageAtRest: 300, lowerRowDrawn: 260)
        // 700 − 250 − 260 + 300 + (92 + 10 + 138)
        XCTAssertEqual(IslandHeightRules.restingColumn(drawn: 700, move: move, samples: samples), 730)
    }

    func testWhateverTheListShowsTheCapIsTheDestinations() {
        // Budget 838; everything but the lower row 590 (the destination's stage 300 included);
        // the agents card's chrome 48: the cap is 838 − 590 − 48 = 200, whatever height the list
        // has in this pass and however far the drawn lower row is from it.
        for shown: CGFloat in [140, 200, 260] {
            for lowerDrawn: CGFloat in [248, 278, 308] {
                var samples = IslandHeightRules.Samples(agentsColumn: 48 + shown, keepAwake: 138)
                samples.list = AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: 600)
                let move = IslandHeightRules.MoveHeights(stageDrawn: 300, stageAtRest: 300, lowerRowDrawn: lowerDrawn)
                samples.rightColumn = IslandHeightRules.restingColumn(drawn: 590 + lowerDrawn, move: move, samples: samples)
                let outcome = IslandHeightRules.outcome(rightBudget: 838, samples: samples)
                XCTAssertEqual(outcome.agentsListCap, 200, "list \(shown), lower row drawn \(lowerDrawn)")
            }
        }
    }
}
