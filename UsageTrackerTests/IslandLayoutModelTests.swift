import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3 and § 3.9: the island's content takes its layout from
/// the display it opens on (640 / 720 / 560, the strip, the habitat) and its agents list's
/// cap from `IslandHeightRules`, through one model that publishes only what moved and
/// settles whatever order the measurements arrive in.
@MainActor
final class IslandLayoutModelTests: XCTestCase {
    private enum Order { case listFirst, columnFirst }

    /// One layout pass of a stand-in right column at the model's current cap, reported in
    /// `order` (`IslandHeightRulesTests`' numbers).
    private func layOut(
        _ model: IslandLayoutModel, fixed: CGFloat, costTile: CGFloat? = nil,
        keepAwake: CGFloat = 138, order: Order = .listFirst
    ) {
        let shown = min(330, model.agentsListCap)
        let agents = 48 + shown
        let right = fixed + max(agents, IslandHeightRules.otherColumn(costTile: costTile, keepAwake: keepAwake))
        let list = AgentsListGeometry(shownHeight: shown, minimumHeight: 109, contentHeight: 330)
        switch order {
        case .listFirst:
            model.record(list: list)
            model.record(agentsColumn: agents)
            model.record(costTile: costTile)
            model.record(keepAwake: keepAwake)
            model.record(rightColumn: right)
        case .columnFirst:
            model.record(rightColumn: right)
            model.record(keepAwake: keepAwake)
            model.record(costTile: costTile)
            model.record(agentsColumn: agents)
            model.record(list: list)
        }
    }

    // MARK: - The layout per display

    func testOnThe14InchTheContentIsThe640IslandWithItsStripAndHabitat() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        XCTAssertEqual(
            model.layout,
            IslandLayout(kind: .island, bodyWidth: 640, stripHeight: 32, notchWidth: 185, showsHabitat: true)
        )
        XCTAssertEqual(model.rightBudget, 838)
    }

    func testOnANarrowNotchedDisplayTheIslandIs560WithoutAHabitat() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
        XCTAssertEqual(
            model.layout,
            IslandLayout(kind: .island, bodyWidth: 560, stripHeight: 34, notchWidth: 192, showsHabitat: false)
        )
        XCTAssertEqual(model.rightBudget, 740)
    }

    func testOnAnExternalDisplayItIsThe720PanelWithThe3xBudget() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.externalRight, visibleHeight: 1416)
        XCTAssertEqual(
            model.layout,
            IslandLayout(kind: .panel, bodyWidth: 720, stripHeight: 0, notchWidth: 0, showsHabitat: true)
        )
        XCTAssertEqual(model.rightBudget, 1306)
    }

    func testWithThePetOffTheHabitatGoes() {
        XCTAssertFalse(IslandLayout(on: ScreenFixture.builtIn, petOn: false).showsHabitat)
        XCTAssertEqual(IslandLayout(on: ScreenFixture.builtIn, petOn: false).columns.right, 612)
    }

    // MARK: - The cap

    func testAMeasurementThatMovesNothingPublishesNothing() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        layOut(model, fixed: 342, costTile: 140)
        layOut(model, fixed: 342, costTile: 140)
        XCTAssertEqual(model.agentsListCap, 260)
        XCTAssertEqual(model.rightColumnViewport, 650)
        var published = 0
        let subscriptions = [
            model.$agentsListCap.dropFirst().sink { _ in published += 1 },
            model.$scrolls.dropFirst().sink { _ in published += 1 },
            model.$rightColumnViewport.dropFirst().sink { _ in published += 1 },
        ]
        defer { subscriptions.forEach { $0.cancel() } }

        layOut(model, fixed: 342, costTile: 140)

        XCTAssertEqual(published, 0, "an equal pass re-rendered the island")
    }

    func testATallerFixedPartTakesTheCapDownOnce() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
        layOut(model, fixed: 342, costTile: 140)
        XCTAssertEqual(model.agentsListCap, 260)
        var caps: [CGFloat] = []
        let subscription = model.$agentsListCap.dropFirst().sink { caps.append($0) }
        defer { subscription.cancel() }

        // The stale notice appears: 170 pt more outside the lower row.
        model.record(rightColumn: 512 + 308)

        XCTAssertEqual(caps, [240], "down to the other half's 288 − 48, once")
    }

    func testWhenTwoRowsCannotFitTheColumnScrollsInsideTheBudget() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
        layOut(model, fixed: 600, costTile: 140)
        layOut(model, fixed: 600, costTile: 140)
        XCTAssertEqual(model.agentsListCap, 240)
        XCTAssertTrue(model.scrolls)
        XCTAssertEqual(model.rightColumnViewport, 740)
    }

    /// Plan ruling R8, review finding 1: while the column fits, the scroll view around it is
    /// at least as tall as the column, so it has nothing to scroll and needs no
    /// `scrollDisabled` (which would also stop the agents list and an expanded detail).
    func testWhileItFitsTheViewportIsTheColumnRoundedUpToAWholePoint() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        model.record(keepAwake: 138)
        model.record(rightColumn: 480.4)
        XCTAssertFalse(model.scrolls)
        XCTAssertEqual(model.rightColumnViewport, 481)
    }

    func testAPartThatLeavesTakesItsMeasurementWithIt() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
        layOut(model, fixed: 472)
        layOut(model, fixed: 472)
        XCTAssertEqual(model.agentsListCap, 220)

        model.record(list: nil)
        model.record(agentsColumn: nil)

        XCTAssertEqual(model.agentsListCap, 260, "no list to cap")
        XCTAssertFalse(model.scrolls)
    }

    func testTheCapSettlesByTheSecondPassWhicheverReportComesFirst() {
        for order in [Order.listFirst, .columnFirst] {
            let model = IslandLayoutModel()
            model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)
            for pass in 1...2 {
                layOut(model, fixed: 472, order: order)
                XCTAssertEqual(model.agentsListCap, 220, "\(order), pass \(pass)")
                XCTAssertFalse(model.scrolls, "\(order), pass \(pass)")
            }
            XCTAssertEqual(model.rightColumnViewport, 740, "\(order)")
            var published = 0
            let subscription = model.$agentsListCap.dropFirst().sink { _ in published += 1 }
            layOut(model, fixed: 472, order: order)
            subscription.cancel()
            XCTAssertEqual(published, 0, "\(order): the third pass moved the cap")
        }
    }

    func testANewDisplayRecomputesTheCap() {
        let model = IslandLayoutModel()
        model.place(on: ScreenFixture.builtIn, visibleHeight: 872)
        layOut(model, fixed: 472)
        layOut(model, fixed: 472)
        XCTAssertEqual(model.agentsListCap, 260)

        model.place(on: ScreenFixture.narrowNotched, visibleHeight: 774)

        XCTAssertEqual(model.agentsListCap, 220)
    }
}
