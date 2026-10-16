import XCTest
@testable import Omelette

/// Attribution and totals: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design.
/// - Turns: a sub-agent's turns belong to its parent chat.
/// - Attribution: a bin's Δp goes to its chats by dollars; a lagging Δp goes to the
///   previous bin's chats; otherwise it goes to Outside this Mac.
/// - Totals: chats plus Outside equal the window's percent; a project is the sum of
///   its chats; a reading closes its bin (ruling C1).
/// - § Design, The tab, item 2: Outside is whole points on Claude's whole-number
///   percents.
final class LimitShareAttributionTests: XCTestCase {
    /// The window's start: 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)
    private let alpha = "-Users-tester-Projects-alpha"
    private let beta = "-Users-tester-Projects-beta"

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Three hours: six bins.
    private var window: LimitWindow { LimitWindow(start: start, end: at(180)) }

    private func share(
        _ readings: [(Double, Double)], _ turns: [TurnCost], titles: [String: String] = [:]
    ) -> LimitShare {
        LimitShareRules.share(
            window: window,
            bucketID: "five_hour",
            readings: Fixture.readings(
                bucketID: "five_hour", points: readings.map { (at: at($0.0), percent: $0.1) }
            ),
            log: TurnCostLog(turns: turns, titles: titles)
        )
    }

    func testOneChatFillsTheWholeWindow() throws {
        let result = share(
            [(20, 4), (50, 9)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", project: alpha, cost: 2),
                Fixture.turnCost(at: at(35), chat: "chat-a", project: alpha, cost: 3),
            ],
            titles: ["chat-a": "Fix the flaky reset test"]
        )

        XCTAssertEqual(result.percent, 9)
        XCTAssertEqual(result.outside, 0)
        XCTAssertEqual(result.bins.map(\.delta), [4, 5, 0, 0, 0, 0])
        let chat = try XCTUnwrap(result.chats.first)
        XCTAssertEqual(result.chats.count, 1)
        XCTAssertEqual(chat.id, "chat-a")
        XCTAssertEqual(chat.title, "Fix the flaky reset test")
        XCTAssertEqual(chat.projectSlug, alpha)
        XCTAssertEqual(chat.points, 9, accuracy: 1e-9)
        XCTAssertEqual(chat.cost, 5, accuracy: 1e-9)
        XCTAssertEqual(chat.tokens, 2_000)
        XCTAssertEqual(chat.lastAt, at(35))
        XCTAssertEqual(result.projects.map(\.id), [alpha])
        XCTAssertEqual(result.cost, 5, accuracy: 1e-9)
        XCTAssertEqual(result.tokens, 2_000)
    }

    func testTwoChatsInOneHalfHourSplitItsPointsByDollars() {
        let result = share(
            [(25, 8), (55, 10)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 3),
                Fixture.turnCost(at: at(10), chat: "chat-b", cost: 1),
                Fixture.turnCost(at: at(40), chat: "chat-b", cost: 2),
            ]
        )

        XCTAssertEqual(result.chats.map(\.id), ["chat-a", "chat-b"])
        XCTAssertEqual(result.chats[0].points, 6, accuracy: 1e-9, "$3 of the first half hour's $4: 6 of its 8 points")
        XCTAssertEqual(result.chats[1].points, 4, accuracy: 1e-9, "2 of the first half hour's points and all 2 of the second's")
        XCTAssertEqual(result.bins[0].chats["chat-a"] ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(result.bins[0].chats["chat-b"] ?? -1, 2, accuracy: 1e-9)
    }

    func testAPercentThatArrivesABinLateGoesToThePreviousBinsChatsButNoFurther() {
        let result = share(
            [(20, 0), (35, 4), (70, 6)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(10), chat: "chat-b", cost: 3),
            ]
        )

        XCTAssertEqual(result.bins.map(\.delta), [0, 4, 2, 0, 0, 0])
        XCTAssertEqual(Set(result.bins[1].chats.keys), ["chat-a", "chat-b"])
        XCTAssertEqual(result.bins[1].chats["chat-a"] ?? -1, 1, accuracy: 1e-9, "the previous half hour's proportions: $1 of $4")
        XCTAssertEqual(result.bins[1].chats["chat-b"] ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(result.bins[1].outside, 0)
        XCTAssertEqual(result.bins[2].chats, [:], "the half hour before this one had no turn: the lag reaches one bin back, never two")
        XCTAssertEqual(result.bins[2].outside, 2)
        XCTAssertEqual(result.outside, 2)
        XCTAssertEqual(result.percent, 6)
    }

    func testAPercentWithNoLocalTurnBeforeItIsOutsideThisMac() {
        let result = share(
            [(20, 3), (45, 3), (75, 7)],
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 2)]
        )

        XCTAssertEqual(result.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(result.chats[0].points, 3, accuracy: 1e-9)
        XCTAssertEqual(result.bins[2].delta, 4)
        XCTAssertEqual(result.bins[2].chats, [:])
        XCTAssertEqual(result.bins[2].outside, 4, "claude.ai, the desktop app or another machine moved it")
        XCTAssertEqual(result.outside, 4)
        XCTAssertEqual(result.percent, 7)
    }

    func testOutsideThisMacTakesWholePointsOfWholeNumberPercents() {
        // Claude reports whole numbers (spec § Facts: `five_hour` 9).
        let result = share(
            [(20, 1), (40, 1), (70, 3)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(10), chat: "chat-b", cost: 2),
            ]
        )

        XCTAssertEqual(result.outside, 2)
        XCTAssertEqual(result.outside, result.outside.rounded(), "Outside takes whole bins of whole-number percents")
        XCTAssertEqual(result.chats.first { $0.id == "chat-a" }?.points ?? -1, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(result.chats.first { $0.id == "chat-b" }?.points ?? -1, 2.0 / 3, accuracy: 1e-9)
    }

    func testTheChatsAndOutsideAddUpToTheWindowsPercentNow() {
        let result = share(
            [(25, 2), (55, 6), (65, 7), (130, 9)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(35), chat: "chat-b", cost: 1),
                Fixture.turnCost(at: at(40), chat: "chat-a", cost: 3),
            ]
        )

        XCTAssertEqual(result.percent, 9, "the last monotone reading")
        XCTAssertEqual(result.chats.first { $0.id == "chat-a" }?.points ?? -1, 5.75, accuracy: 1e-9)
        XCTAssertEqual(result.chats.first { $0.id == "chat-b" }?.points ?? -1, 1.25, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 2)
        XCTAssertEqual(
            result.chats.reduce(0) { $0 + $1.points } + result.outside, result.percent, accuracy: 1e-9
        )
        XCTAssertEqual(result.attributedPoints, 7, accuracy: 1e-9)
    }

    func testAProjectsShareIsTheSumOfItsChats() {
        let result = share(
            [(25, 12)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", project: alpha, cost: 3),
                Fixture.turnCost(at: at(10), chat: "chat-b", project: alpha, cost: 1),
                Fixture.turnCost(at: at(12), chat: "chat-c", project: beta, cost: 2),
            ]
        )

        XCTAssertEqual(result.projects.map(\.id), [alpha, beta])
        XCTAssertEqual(result.projects[0].points, 8, accuracy: 1e-9, "6 + 2")
        XCTAssertEqual(result.projects[0].cost, 4, accuracy: 1e-9)
        XCTAssertEqual(result.projects[0].chats, 2)
        XCTAssertEqual(result.projects[0].tokens, 2_000)
        XCTAssertEqual(result.projects[1].points, 4, accuracy: 1e-9)
        XCTAssertEqual(result.projects[1].chats, 1)
    }

    func testASubAgentsTurnsCountForTheChatThatLaunchedIt() throws {
        let result = share(
            [(25, 8)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", project: alpha, cost: 1),
                // The log files a sub-agent's turn under its parent's chat id; its own
                // project can differ.
                Fixture.turnCost(
                    at: at(10), chat: "chat-a", project: "-Users-tester-Projects-alpha-worktree",
                    cost: 3, isMainThread: false
                ),
                Fixture.turnCost(at: at(15), chat: "chat-b", project: beta, cost: 4, isMainThread: false),
            ]
        )

        XCTAssertEqual(result.chats.map(\.id), ["chat-a", "chat-b"])
        let parent = try XCTUnwrap(result.chats.first)
        XCTAssertEqual(parent.points, 4, accuracy: 1e-9)
        XCTAssertEqual(parent.cost, 4, accuracy: 1e-9)
        XCTAssertEqual(parent.projectSlug, alpha, "the main thread names the chat's project, even with a later sub-agent turn")
        XCTAssertEqual(result.chats.last?.projectSlug, beta, "a chat only its sub-agents ran in takes their project")
    }

    func testAHalfHourOfUnpricedTurnsSplitsByTokens() {
        // A model no price table knows yet costs $0 (Codex, `ModelPricing.dynamicLookup`).
        let result = share(
            [(20, 4)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", model: "gpt-9-nova", cost: 0, tokens: 3_000),
                Fixture.turnCost(at: at(10), chat: "chat-b", model: "gpt-9-nova", cost: 0, tokens: 1_000),
            ]
        )

        XCTAssertEqual(result.outside, 0, "a turn with no dollars is still a turn on this Mac")
        XCTAssertEqual(result.chats.first { $0.id == "chat-a" }?.points ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(result.chats.first { $0.id == "chat-b" }?.points ?? -1, 1, accuracy: 1e-9)
    }

    func testTurnsOutsideTheWindowAreNotItsOwn() {
        let result = share(
            [(20, 2)],
            [
                Fixture.turnCost(at: at(-1), chat: "chat-before", cost: 5),
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(180), chat: "chat-after", cost: 5),
            ]
        )

        XCTAssertEqual(result.chats.map(\.id), ["chat-a"], "a turn on the window's end belongs to the next one")
        XCTAssertEqual(result.cost, 1, accuracy: 1e-9)
    }

    func testAReadingOnABinsEdgeClosesTheEarlierBinAndTheLagGivesTheRestToItsChat() {
        // Ruling C1, the review's fixture: a 90-minute window, chat A's turn at minute
        // 29, and the percent reads 4 at minute 30 and 6 at minute 60.
        let result = LimitShareRules.share(
            window: LimitWindow(start: start, end: at(90)),
            bucketID: "five_hour",
            readings: Fixture.readings(bucketID: "five_hour", points: [
                (at: at(30), percent: 4), (at: at(60), percent: 6),
            ]),
            log: TurnCostLog(turns: [Fixture.turnCost(at: at(29), chat: "chat-a", cost: 1)])
        )

        XCTAssertEqual(result.bins.map(\.delta), [4, 2, 0])
        XCTAssertEqual(result.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(
            result.chats[0].points, 6, accuracy: 1e-9,
            "4 in the half hour the minute-30 reading closes, 2 through the lag"
        )
        XCTAssertEqual(result.outside, 0)
    }

    func testAChatWhoseHalfHoursDidNotMoveThePercentIsListedAtZero() {
        let result = share(
            [(20, 2), (110, 2)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(100), chat: "chat-b", cost: 1),
            ]
        )

        XCTAssertEqual(result.chats.map(\.id), ["chat-a", "chat-b"])
        XCTAssertEqual(result.chats[1].points, 0)
        XCTAssertEqual(result.chats[1].cost, 1, accuracy: 1e-9)
    }
}
