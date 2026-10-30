import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.3 (Height) during a page move (§ 3.2,
/// Drill-down) and the session's ruling that the height rules read the destination's resting
/// column during a move, so the agents cap must not oscillate: a layout simulator that closes the
/// loop — the cap sets the list's height, which sets the column the next pass reports — swept over
/// destinations (stage height, agents card or none, a taller or a shorter other half, a list that
/// fits or not), sources, moves that stand still, advance or turn around, and either order of the
/// pass's reports. Whatever the move draws, the cap and the scroll decision are the destination's
/// at rest, and the island is drawn at the column as drawn.
@MainActor
final class IslandHeightRulesMoveVerificationTests: XCTestCase {
    private enum Order: CaseIterable { case listFirst, columnFirst, interleaved }

    private struct Destination {
        var stage: CGFloat
        /// Notice, footer and gaps: what the column holds besides the stage and the lower row.
        var extras: CGFloat
        var hasAgents: Bool
        var listContent: CGFloat?
        var costTile: CGFloat?
        var keepAwake: CGFloat = 138
        var chrome: CGFloat = 48

        var other: CGFloat { IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake) }
        func lowerRow(cap: CGFloat) -> CGFloat {
            max(hasAgents ? chrome + shown(cap: cap) : 0, other)
        }
        func shown(cap: CGFloat) -> CGFloat { min(listContent ?? cap, cap) }
    }

    private func placed() -> IslandLayoutModel {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        return model
    }

    /// One layout pass of `destination`'s lower row and the right column, `fraction` of the way
    /// from a source with `stageFrom` / `lowerFrom`; returns the destination's lower row as laid out.
    @discardableResult
    private func pass(
        _ model: IslandLayoutModel, _ d: Destination, fraction: Double?, stageFrom: CGFloat, lowerFrom: CGFloat,
        measuredLower: CGFloat, order: Order
    ) -> CGFloat {
        let cap = model.agentsListCap
        let shown = d.shown(cap: cap)
        let list = d.hasAgents
            ? AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: d.listContent) : nil
        let agents: CGFloat? = d.hasAgents ? d.chrome + shown : nil
        let lowerRest = d.lowerRow(cap: cap)
        var column: CGFloat
        var move: IslandHeightRules.MoveHeights?
        if let fraction {
            let f = CGFloat(fraction)
            let stageDrawn = stageFrom + (d.stage - stageFrom) * f
            let lowerDrawn = lowerFrom + (measuredLower - lowerFrom) * f
            column = stageDrawn + d.extras + lowerDrawn
            move = IslandHeightRules.MoveHeights(stageDrawn: stageDrawn, stageAtRest: d.stage, lowerRowDrawn: lowerDrawn)
        } else {
            column = d.stage + d.extras + lowerRest
            move = nil
        }
        switch order {
        case .listFirst:
            model.record(list: list)
            model.record(agentsColumn: agents)
            model.record(costTile: d.costTile)
            model.record(keepAwake: d.keepAwake)
            model.record(rightColumn: column, move: move)
        case .columnFirst:
            model.record(rightColumn: column, move: move)
            model.record(keepAwake: d.keepAwake)
            model.record(costTile: d.costTile)
            model.record(agentsColumn: agents)
            model.record(list: list)
        case .interleaved:
            model.record(agentsColumn: agents)
            model.record(rightColumn: column, move: move)
            model.record(list: list)
            model.record(keepAwake: d.keepAwake)
            model.record(costTile: d.costTile)
        }
        return lowerRest
    }

    /// The destination at rest: the cap the loop settles to, and whether it scrolls.
    private func atRest(_ d: Destination, order: Order) -> (cap: CGFloat, scrolls: Bool, converged: Bool) {
        let model = placed()
        var last: CGFloat = 0
        var caps: [CGFloat] = []
        for _ in 0..<8 {
            last = pass(model, d, fraction: nil, stageFrom: 0, lowerFrom: 0, measuredLower: last, order: order)
            caps.append(model.agentsListCap)
        }
        return (model.agentsListCap, model.scrolls, caps[5] == caps[6] && caps[6] == caps[7])
    }

    private var destinations: [Destination] {
        var all: [Destination] = []
        for stage: CGFloat in [250, 300, 420, 700] {
            for extras: CGFloat in [40, 60] {
                for content: CGFloat? in [nil, 100, 300, 600] {
                    for cost: CGFloat? in [nil, 92] {
                        all.append(Destination(stage: stage, extras: extras, hasAgents: true, listContent: content, costTile: cost))
                    }
                }
                all.append(Destination(stage: stage, extras: extras, hasAgents: false, listContent: nil, costTile: nil))
            }
        }
        return all
    }

    func testTheCapAndTheScrollDecisionDuringAnyMoveAreTheDestinationsAtRest() {
        for order in Order.allCases {
            for d in destinations {
                let rest = atRest(d, order: order)
                XCTAssertTrue(rest.converged, "the destination at rest settles: \(d) \(order)")
                for (stageFrom, lowerFrom) in [(CGFloat(250), CGFloat(330)), (400, 140), (300, 308)] {
                    // Frozen at a fraction; advancing 0 → 1; turning around (1 → 0 on the way back).
                    var fractions: [[Double]] = [[0], [0.25], [0.5], [0.9], [1]].map { Array(repeating: $0[0], count: 5) }
                    fractions.append(stride(from: 0.0, through: 1.0, by: 0.1).map { $0 })
                    fractions.append(stride(from: 0.0, through: 0.7, by: 0.1).map { $0 } + stride(from: 0.6, through: 0.0, by: -0.1).map { $0 })
                    for run in fractions {
                        let model = placed()
                        var measured = lowerFrom
                        for (index, f) in run.enumerated() {
                            measured = pass(
                                model, d, fraction: f, stageFrom: stageFrom, lowerFrom: lowerFrom,
                                measuredLower: measured, order: order
                            )
                            let tag = "\(d) from \(stageFrom)/\(lowerFrom), fractions \(run), pass \(index) at \(f), \(order)"
                            XCTAssertEqual(model.agentsListCap, rest.cap, "cap: \(tag)")
                            XCTAssertEqual(model.scrolls, rest.scrolls, "scrolls: \(tag)")
                        }
                    }
                }
            }
        }
    }

    func testTheIslandIsDrawnAtTheColumnAsDrawnWhileItFitsAndAtTheBudgetWhileItScrolls() {
        for d in destinations {
            let model = placed()
            let rest = atRest(d, order: .listFirst)
            var measured: CGFloat = 330
            for f in stride(from: 0.0, through: 1.0, by: 0.25) {
                let previous = measured
                measured = pass(model, d, fraction: f, stageFrom: 250, lowerFrom: 330, measuredLower: previous, order: .listFirst)
                let f = CGFloat(f)
                let drawn = (250 + (d.stage - 250) * f) + d.extras + (330 + (previous - 330) * f)
                if rest.scrolls {
                    XCTAssertEqual(model.rightColumnViewport, model.rightBudget, "\(d) at \(f)")
                } else {
                    XCTAssertEqual(model.rightColumnViewport, drawn.rounded(.up), "\(d) at \(f)")
                }
            }
        }
    }

    func testTheRestingColumnIsTheDestinationsNoMatterWhatTheMoveDrew() {
        // The same destination, drawn from any pair of heights at any progress: one answer.
        let samples = IslandHeightRules.Samples(agentsColumn: 248, costTile: 92, keepAwake: 138)
        let expected = 300 + 60 + max(248, 92 + ProviderGridRules.gap + 138)
        var seen: Set<CGFloat> = []
        for stageDrawn: CGFloat in [250, 275, 300, 350] {
            for lowerDrawn: CGFloat in [140, 248, 330] {
                let drawn = stageDrawn + 60 + lowerDrawn
                let move = IslandHeightRules.MoveHeights(stageDrawn: stageDrawn, stageAtRest: 300, lowerRowDrawn: lowerDrawn)
                seen.insert(IslandHeightRules.restingColumn(drawn: drawn, move: move, samples: samples))
            }
        }
        XCTAssertEqual(seen, [expected])
    }

    func testAnUnmeasuredLowerRowHalfCountsAsNothing() {
        // No agents card, no cost tile: the lower row is keep awake alone.
        var samples = IslandHeightRules.Samples(keepAwake: 138)
        let move = IslandHeightRules.MoveHeights(stageDrawn: 280, stageAtRest: 300, lowerRowDrawn: 200)
        XCTAssertEqual(IslandHeightRules.restingColumn(drawn: 280 + 60 + 200, move: move, samples: samples), 300 + 60 + 138)
        samples.keepAwake = nil
        XCTAssertEqual(IslandHeightRules.restingColumn(drawn: 280 + 60 + 200, move: move, samples: samples), 300 + 60)
    }

    func testARecordWithoutAMoveClearsTheMoveAndOneWithoutAChangeIsNotRepublished() {
        let model = placed()
        let move = IslandHeightRules.MoveHeights(stageDrawn: 275, stageAtRest: 300, lowerRowDrawn: 240)
        model.record(rightColumn: 805, move: move)
        XCTAssertEqual(model.move, move)
        model.record(rightColumn: 805, move: nil)
        XCTAssertNil(model.move, "the same column with the move gone is a change")
        model.record(rightColumn: nil, move: nil)
        XCTAssertNil(model.rightColumnViewport)
    }
}
