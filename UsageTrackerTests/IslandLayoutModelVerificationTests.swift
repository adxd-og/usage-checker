import Combine
import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.3 and § 3.9 for `IslandLayoutModel`:
/// it publishes only on change, converges by the second layout pass whichever measurement
/// arrives first (every arrival order, not two), rounds the viewport up while the column
/// fits, re-places on another display, and agrees with the controller's width rule.
@MainActor
final class IslandLayoutModelVerificationTests: XCTestCase {
    private enum Report: CaseIterable { case list, agents, cost, keepAwake, column }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    /// One layout pass of the stand-in right column at the model's current cap, reported in
    /// `order` (the same numbers as `IslandHeightRulesTests`).
    private func layOut(
        _ model: IslandLayoutModel, fixed: CGFloat, costTile: CGFloat? = nil, keepAwake: CGFloat = 138, order: [Report]
    ) {
        let shown = min(330, model.agentsListCap)
        let agents = 48 + shown
        let right = fixed + max(agents, IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake))
        for report in order {
            switch report {
            case .list: model.record(list: AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: 330))
            case .agents: model.record(agentsColumn: agents)
            case .cost: model.record(costTile: costTile)
            case .keepAwake: model.record(keepAwake: keepAwake)
            case .column: model.record(rightColumn: right)
            }
        }
    }

    private func changes(of model: IslandLayoutModel, during body: () -> Void) -> Int {
        var count = 0
        let subscription = model.objectWillChange.sink { count += 1 }
        defer { subscription.cancel() }
        body()
        return count
    }

    // MARK: - Convergence

    func testTheCapSettlesByTheSecondPassForEveryArrivalOrderOfBothPasses() {
        let orders = permutations(Report.allCases)
        XCTAssertEqual(orders.count, 120)
        for first in orders {
            for second in orders {
                let model = IslandLayoutModel()
                model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
                layOut(model, fixed: 472, order: first)
                layOut(model, fixed: 472, order: second)
                guard model.agentsListCap == 220, !model.scrolls, model.rightColumnViewport == 740 else {
                    XCTFail("not settled after pass two: \(first) then \(second): cap \(model.agentsListCap), scrolls \(model.scrolls), viewport \(String(describing: model.rightColumnViewport))")
                    return
                }
                let third = changes(of: model) { layOut(model, fixed: 472, order: first) }
                guard third == 0 else {
                    XCTFail("a third pass republished (\(third)) after \(first) then \(second)")
                    return
                }
            }
        }
    }

    func testTheCapSettlesTheSameWayWhenTheColumnCannotFitAndScrolls() {
        for order in permutations(Report.allCases) {
            let model = IslandLayoutModel()
            model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
            for _ in 1...2 { layOut(model, fixed: 600, costTile: 140, order: order) }
            XCTAssertEqual(model.agentsListCap, 240, "\(order)")
            XCTAssertTrue(model.scrolls, "\(order)")
            XCTAssertEqual(model.rightColumnViewport, 740, "the budget, not the column: \(order)")
        }
    }

    // MARK: - Publishing

    func testPlacingTheSameDisplayAgainPublishesNothingOnceSettled() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        for _ in 1...2 { layOut(model, fixed: 342, costTile: 140, order: Report.allCases) }
        let published = changes(of: model) {
            model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
            model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        }
        XCTAssertEqual(published, 0, "re-placing on the same display moved nothing")
    }

    func testAnEqualReportOfEveryKindPublishesNothing() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        for _ in 1...2 { layOut(model, fixed: 342, costTile: 140, order: Report.allCases) }
        for report in Report.allCases {
            let published = changes(of: model) { layOut(model, fixed: 342, costTile: 140, order: [report]) }
            XCTAssertEqual(published, 0, "\(report)")
        }
    }

    // MARK: - The viewport

    func testTheViewportIsTheColumnRoundedUpOnlyWhileItFits() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertNil(model.rightColumnViewport, "nothing measured yet")
        for (column, viewport) in [(480.0, 480.0), (480.0001, 481), (480.5, 481), (0.2, 1), (838.0, 838)] as [(CGFloat, CGFloat)] {
            model.record(rightColumn: column)
            XCTAssertEqual(model.rightColumnViewport, viewport, "column \(column)")
            XCTAssertFalse(model.scrolls, "column \(column)")
        }
        model.record(rightColumn: nil)
        XCTAssertNil(model.rightColumnViewport, "a column that left takes its viewport with it")
    }

    func testAColumnOverTheBudgetScrollsInsideExactlyTheBudgetNotItsRoundedHeight() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        model.record(rightColumn: 838.2)
        XCTAssertTrue(model.scrolls)
        XCTAssertEqual(model.rightColumnViewport, 838)
    }

    // MARK: - Another display

    func testMovingToASmallerDisplayStartsTheScrollAndMovingBackStopsIt() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        model.record(rightColumn: 780)
        XCTAssertFalse(model.scrolls)
        XCTAssertEqual(model.rightColumnViewport, 780)

        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
        XCTAssertTrue(model.scrolls, "780 > 740")
        XCTAssertEqual(model.rightColumnViewport, 740)
        XCTAssertEqual(model.layout.bodyWidth, 560)
        XCTAssertFalse(model.layout.showsHabitat)

        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertFalse(model.scrolls)
        XCTAssertEqual(model.rightColumnViewport, 780)
        XCTAssertEqual(model.layout.bodyWidth, 640)
        XCTAssertTrue(model.layout.showsHabitat)
    }

    func testMovingToAnExternalDisplayMakesAPanelWithTheThreeXBudget() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertEqual(model.layout.kind, .island)
        let published = changes(of: model) { model.place(on: ScreenFixture.externalRightMenuBarHidden, visibleHeight: 1416) }
        XCTAssertGreaterThan(published, 0)
        XCTAssertEqual(model.layout.kind, .panel)
        XCTAssertEqual(model.layout.stripHeight, 0)
        XCTAssertEqual(model.layout.notchWidth, 0)
        XCTAssertEqual(model.rightBudget, 1416 - 40 - 70)
    }

    func testTheLayoutsWidthIsTheRuleTheControllerHandsTheResolverOnEveryDisplay() {
        let screens = [
            ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.externalLeft, ScreenFixture.narrowNotched,
        ]
        for screen in screens {
            for petOn in [true, false] {
                XCTAssertEqual(
                    IslandLayout(on: screen, petOn: petOn).bodyWidth,
                    IslandPresentationRules.width(screenWidth: screen.frame.width),
                    "display \(screen.id), pet \(petOn)"
                )
            }
        }
    }

    func testTheHabitatFollowsThePetAndTheScreenWidthAndTheGridFollowsTheHabitat() {
        for screen in [ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.narrowNotched] {
            let withPet = IslandLayout(on: screen, petOn: true)
            let without = IslandLayout(on: screen, petOn: false)
            XCTAssertFalse(without.showsHabitat)
            XCTAssertEqual(withPet.showsHabitat, screen.frame.width >= 1420, "display \(screen.id)")
            XCTAssertEqual(without.columns.right, without.bodyWidth - 28)
            XCTAssertEqual(
                withPet.columns.right,
                withPet.bodyWidth - 28 - (withPet.showsHabitat ? 162 : 0)
            )
        }
    }
}
