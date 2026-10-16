import XCTest
@testable import Omelette

/// The price of a percent: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design, Price of a percent. The price is the local cost in the window (every bin
/// with local turns, zero-Δp bins included; ruling C5) divided by the attributed points
/// (window percent minus Outside), and tokens the same way. Below 1 attributed point
/// there is no price ("Not enough use yet").
final class LimitSharePriceTests: XCTestCase {
    /// The window's start: 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func share(_ readings: [(Double, Double)], _ turns: [TurnCost]) -> LimitShare {
        LimitShareRules.share(
            window: LimitWindow(start: start, end: at(180)),
            bucketID: "seven_day",
            readings: Fixture.readings(
                bucketID: "seven_day", points: readings.map { (at: at($0.0), percent: $0.1) }
            ),
            log: TurnCostLog(turns: turns)
        )
    }

    func testAPercentCostsTheWindowsLocalDollarsOverItsAttributedPoints() throws {
        // The window moves by 5 points:
        // - 1 in the first half hour, with the $62 turn;
        // - 0 in the second, with the $124 turn. Its dollars still count;
        // - 2 a half hour late, which lag back to the $124 turn's chat;
        // - 2 after an empty half hour, which go to Outside.
        // So there are 3 attributed points for $186 and 390 M tokens.
        let result = share(
            [(20, 1), (50, 1), (70, 3), (100, 5)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 62, tokens: 130_000_000),
                Fixture.turnCost(at: at(35), chat: "chat-a", cost: 124, tokens: 260_000_000),
            ]
        )

        XCTAssertEqual(result.outside, 2)
        XCTAssertEqual(result.attributedPoints, 3, accuracy: 1e-9)
        let price = try XCTUnwrap(result.price)
        XCTAssertEqual(price.dollars, 62, accuracy: 1e-9, "1 % ≈ $62")
        XCTAssertEqual(price.tokens, 130_000_000, accuracy: 1e-3, "· 130 M tokens")
    }

    func testBelowOneAttributedPointThereIsNoPriceYet() {
        let allOutside = share(
            [(20, 0), (80, 2)],
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 5)]
        )
        XCTAssertEqual(allOutside.percent, 2)
        XCTAssertEqual(allOutside.attributedPoints, 0)
        XCTAssertNil(allOutside.price, "two points, both from Outside this Mac")

        let fraction = share(
            [(20, 0.6)],
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 5)]
        )
        XCTAssertNil(fraction.price, "Codex reports fractions: 0.6 of a point is not enough use yet")
    }

    func testATurnInAHalfHourThatMovedNothingStillCountsInThePrice() throws {
        // The review's isolated tail. The $62 turn earns the only point. Later, a $124
        // turn runs in a half hour whose percent does not move, and neither does the
        // half hour after it. The price is the window's whole local cost over the
        // attributed point.
        let result = share(
            [(20, 1), (140, 1), (170, 1)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 62, tokens: 130_000_000),
                Fixture.turnCost(at: at(125), chat: "chat-b", cost: 124, tokens: 260_000_000),
            ]
        )

        XCTAssertEqual(result.bins.map(\.delta), [1, 0, 0, 0, 0, 0])
        XCTAssertEqual(result.attributedPoints, 1, accuracy: 1e-9)
        XCTAssertEqual(result.chats.first { $0.id == "chat-b" }?.points, 0)
        let price = try XCTUnwrap(result.price)
        XCTAssertEqual(price.dollars, 186, accuracy: 1e-9, "$62 + $124 over one point")
        XCTAssertEqual(price.tokens, 390_000_000, accuracy: 1e-3, "130 M + 260 M tokens over one point")
    }

    func testOneAttributedPointIsEnoughForAPrice() throws {
        let result = share([(20, 1)], [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 10)])
        let price = try XCTUnwrap(result.price)
        XCTAssertEqual(price.dollars, 10, accuracy: 1e-9)
        XCTAssertEqual(price.tokens, 1_000, accuracy: 1e-9)
    }
}
