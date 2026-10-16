import XCTest
@testable import Omelette

/// Stretches inside a chat: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 5. A new stretch starts at a compaction or at a cold start: a
/// main-thread turn reading under 5 % of its prompt (input + cache read + cache write)
/// from cache while writing at least 10,000 tokens of cache; on Codex, which logs no
/// write, a prompt of at least 10,000 tokens. Stretches shorter than 10 minutes merge into
/// the next one. Each has its time range, its share and dollars, its cold-start cost, and
/// as its name the first prompt typed for it. Its share is what § The rule gave the chat
/// in the stretch's half hours.
///
/// Turns are priced at Sonnet's list prices (`Fixture.sonnetPrice`). The shares are cut by
/// the rule itself from readings at the minutes given.
final class LimitStretchesTests: XCTestCase {
    /// 2026-09-06 10:00 UTC, a Sunday; the window runs five hours from here.
    private let t0 = Date(timeIntervalSince1970: 1_788_688_800)
    private var window: LimitWindow { LimitWindow(start: t0, end: t0.addingTimeInterval(5 * 3_600)) }

    private func minute(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    /// Reads 100,000 tokens from cache, takes 1,000 fresh, answers in 2,000: $0.063.
    private func warm(_ m: Double, chat: String = "chat-a", isMainThread: Bool = true) -> TurnCost {
        Fixture.promptTurn(
            at: minute(m), chat: chat, input: 1_000, cacheRead: 100_000, output: 2_000, isMainThread: isMainThread
        )
    }

    /// Reads nothing from cache, writes 50,000 tokens to the 1-hour cache, answers in
    /// 1,000: $0.315, of which rebuilding the context is $0.30.
    private func cold(_ m: Double, chat: String = "chat-a", isMainThread: Bool = true) -> TurnCost {
        Fixture.promptTurn(at: minute(m), chat: chat, cacheWrite1h: 50_000, output: 1_000, isMainThread: isMainThread)
    }

    /// Chat A's stretches in the window, its share cut by the rule from readings of the
    /// window's percent at the minutes given.
    private func stretches(
        _ turns: [TurnCost], rises: [(minute: Double, percent: Double)] = [],
        compactions: [Date] = [], prompts: [ChatPrompt] = [], serviceID: String = "claude"
    ) -> [ChatStretch] {
        let log = TurnCostLog(
            turns: turns.sorted { $0.timestamp < $1.timestamp }, titles: [:],
            compactions: ["chat-a": compactions], prompts: ["chat-a": prompts]
        )
        let share = LimitShareRules.share(
            window: window, series: rises.map { LimitReading(time: minute($0.minute), percent: $0.percent) }, log: log
        )
        return LimitShareRules.stretches(of: share, log: log, serviceID: serviceID)["chat-a"] ?? []
    }

    func testAChatWithNoCompactionOrColdStartIsOneStretch() throws {
        let result = stretches(
            [warm(10), warm(40), warm(70)], rises: [(minute: 75, percent: 3)],
            prompts: [ChatPrompt(at: minute(9), text: "Fix the flaky reset test")]
        )
        XCTAssertEqual(result.count, 1)
        let only = try XCTUnwrap(result.first)
        XCTAssertEqual(only.opening, .firstTurn)
        XCTAssertEqual(only.firstAt, minute(10))
        XCTAssertEqual(only.lastAt, minute(70))
        XCTAssertEqual(only.points, 3, accuracy: 1e-9)
        XCTAssertEqual(only.cost, 0.189, accuracy: 1e-9)
        XCTAssertEqual(only.coldStartCost, 0, accuracy: 1e-9)
        XCTAssertEqual(only.prompt, "Fix the flaky reset test", "typed a minute before the chat's first turn")
    }

    func testACompactionStartsAStretchNamedByThePromptAfterIt() {
        let result = stretches(
            [warm(10), warm(40), warm(65), warm(90)],
            rises: [(minute: 45, percent: 2), (minute: 95, percent: 4)],
            compactions: [minute(60)],
            prompts: [
                ChatPrompt(at: minute(9), text: "Fix the flaky reset test"),
                ChatPrompt(at: minute(62), text: "Now the changelog"),
            ]
        )
        guard result.count == 2 else { return XCTFail("expected two stretches, got \(result.count)") }
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .compaction])
        XCTAssertEqual(result.map(\.firstAt), [minute(10), minute(65)])
        XCTAssertEqual(result.map(\.lastAt), [minute(40), minute(90)])
        XCTAssertEqual(result.map(\.prompt), ["Fix the flaky reset test", "Now the changelog"])
        XCTAssertEqual(result[0].points, 2, accuracy: 1e-9, "the 30–60 half hour's two points")
        XCTAssertEqual(result[1].points, 2, accuracy: 1e-9, "the 90–120 half hour's two points")
    }

    func testAColdStartStartsAStretchAndCountsWhatTheRebuildCost() {
        let result = stretches(
            [warm(10), cold(120), warm(125)],
            rises: [(minute: 20, percent: 1), (minute: 130, percent: 5)],
            prompts: [
                ChatPrompt(at: minute(9), text: "Fix the flaky reset test"),
                ChatPrompt(at: minute(119), text: "After lunch: the appcast"),
            ]
        )
        guard result.count == 2 else { return XCTFail("expected two stretches, got \(result.count)") }
        XCTAssertEqual(result[1].opening, .coldStart)
        XCTAssertEqual(result[1].prompt, "After lunch: the appcast", "typed just before the turn that rebuilt the context")
        XCTAssertEqual(result[1].coldStartCost, 0.30, accuracy: 1e-9)
        XCTAssertEqual(result[1].cost, 0.378, accuracy: 1e-9)
        XCTAssertEqual(result[0].coldStartCost, 0, accuracy: 1e-9)
        XCTAssertEqual(result[0].points, 1, accuracy: 1e-9)
        XCTAssertEqual(result[1].points, 4, accuracy: 1e-9)
    }

    func testAWarmTurnOrASmallRebuildIsNoColdStart() {
        func isCold(_ turn: TurnCost) -> Bool { LimitShareRules.isColdStart(turn, serviceID: "claude") }
        XCTAssertFalse(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheRead: 60_000, cacheWrite1h: 20_000)),
                       "75 % read from cache")
        XCTAssertFalse(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheWrite5m: 9_999)), "under 10,000 tokens written")
        XCTAssertTrue(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheWrite5m: 10_000)))
        XCTAssertFalse(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheRead: 600, cacheWrite1h: 10_000)),
                       "600 of 10,600 is over 5 %")
        XCTAssertTrue(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheRead: 500, cacheWrite1h: 10_000)),
                      "500 of 10,500 is under 5 %")
        XCTAssertFalse(isCold(Fixture.promptTurn(at: t0, chat: "c", cacheWrite1h: 50_000, isMainThread: false)),
                       "a sub-agent's context is not the chat's")
    }

    func testOnCodexAColdStartIsAFreshPromptOfTenThousandTokens() {
        let fresh = Fixture.promptTurn(at: t0, chat: "c", input: 20_000, cacheRead: 500)
        XCTAssertTrue(LimitShareRules.isColdStart(fresh, serviceID: "codex"), "500 of 20,500 read from cache")
        XCTAssertFalse(LimitShareRules.isColdStart(fresh, serviceID: "claude"), "on Claude a rebuild writes the cache")
        XCTAssertFalse(LimitShareRules.isColdStart(Fixture.promptTurn(at: t0, chat: "c", input: 9_000), serviceID: "codex"))
    }

    func testAStretchUnderTenMinutesMergesIntoTheNext() {
        let result = stretches([warm(10), cold(15), warm(20), cold(60), warm(62)])
        guard result.count == 2 else { return XCTFail("expected two stretches, got \(result.count)") }
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .coldStart])
        XCTAssertEqual(result.map(\.firstAt), [minute(10), minute(60)])
        XCTAssertEqual(result.map(\.lastAt), [minute(20), minute(62)])
        XCTAssertEqual(result[0].coldStartCost, 0.30, accuracy: 1e-9, "the merged cold start still rebuilt the context")
        XCTAssertEqual(result[1].coldStartCost, 0.30, accuracy: 1e-9)
    }

    func testTheLastStretchStaysHoweverShort() {
        let result = stretches([warm(10), cold(100)])
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .coldStart])
        XCTAssertEqual(result.last?.firstAt, minute(100))
        XCTAssertEqual(result.last?.lastAt, minute(100))
    }

    func testASubAgentsTurnsCountInTheStretchTheyRanIn() {
        let result = stretches([warm(10), cold(30, isMainThread: false), warm(40)])
        XCTAssertEqual(result.count, 1, "a sub-agent rebuilding its own context starts no stretch of the chat")
        XCTAssertEqual(result.first?.cost ?? -1, 0.441, accuracy: 1e-9)
        XCTAssertEqual(result.first?.coldStartCost ?? -1, 0, accuracy: 1e-9)
    }

    func testAStretchNoPromptWasTypedForHasNoName() {
        let result = stretches(
            [warm(10), cold(120)],
            prompts: [ChatPrompt(at: minute(9), text: "Fix the flaky reset test")]
        )
        XCTAssertEqual(result.map(\.prompt), ["Fix the flaky reset test", nil], "that prompt was answered at minute 10")
    }

    func testOnlyTheWindowsTurnsAndCompactionsCount() {
        let result = stretches([warm(-20), warm(10), warm(40)], compactions: [minute(-5), minute(400)])
        XCTAssertEqual(result.count, 1, "a compaction before the chat's first turn here, or after the window, cuts nothing")
        XCTAssertEqual(result.first?.firstAt, minute(10))
        XCTAssertEqual(result.first?.cost ?? -1, 0.126, accuracy: 1e-9, "the turn before the window is not this window's")
    }

    func testEveryChatOfTheShareIsCut() {
        let log = TurnCostLog(turns: [warm(10), warm(20, chat: "chat-b"), cold(90, chat: "chat-b")])
        let share = LimitShareRules.share(window: window, series: [], log: log)
        let all = LimitShareRules.stretches(of: share, log: log, serviceID: "claude")
        XCTAssertEqual(all["chat-a"]?.count, 1)
        XCTAssertEqual(all["chat-b"]?.map(\.opening), [.firstTurn, .coldStart])
    }

    func testAStretchsPointsAreWhatTheBinsGaveItNotItsDollars() {
        // $100 before a compaction, in a half hour where the percent rose 1 point; $1 after
        // it, in one where it rose 9. Split by the chat's dollars they would read 9.9 and
        // 0.1.
        let result = stretches(
            [
                Fixture.turnCost(at: minute(10), chat: "chat-a", cost: 100),
                Fixture.turnCost(at: minute(125), chat: "chat-a", cost: 1),
            ],
            rises: [(minute: 20, percent: 1), (minute: 130, percent: 10)],
            compactions: [minute(60)]
        )
        guard result.count == 2 else { return XCTFail("expected two stretches, got \(result.count)") }
        XCTAssertEqual(result.map(\.cost), [100, 1])
        XCTAssertEqual(result[0].points, 1, accuracy: 1e-9)
        XCTAssertEqual(result[1].points, 9, accuracy: 1e-9)
    }

    func testAStepTheLimitReportedLateCountsForTheStretchBeforeIt() {
        // The 60–90 half hour has no turn: its 2 points lag from 30–60, which ran before
        // the compaction at minute 60.
        let result = stretches(
            [
                Fixture.turnCost(at: minute(45), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: minute(95), chat: "chat-a", cost: 1),
            ],
            rises: [(minute: 61, percent: 2), (minute: 100, percent: 3)],
            compactions: [minute(60)]
        )
        guard result.count == 2 else { return XCTFail("expected two stretches, got \(result.count)") }
        XCTAssertEqual(result[0].points, 2, accuracy: 1e-9)
        XCTAssertEqual(result[1].points, 1, accuracy: 1e-9)
    }

    func testASubAgentTurnJustBeforeAColdStartDoesNotHideItsPrompt() {
        // The prompt at minute 119, a sub-agent's turn at 119.5, the cold start at 120:
        // the prompt came after the chat's previous main-thread turn (minute 10).
        let result = stretches(
            [warm(10), warm(119.5, isMainThread: false), cold(120)],
            prompts: [
                ChatPrompt(at: minute(9), text: "Fix the flaky reset test"),
                ChatPrompt(at: minute(119), text: "After lunch: the appcast"),
            ]
        )
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .coldStart])
        XCTAssertEqual(result.map(\.prompt), ["Fix the flaky reset test", "After lunch: the appcast"])
    }

    func testAPromptBeforeASlowFirstAnswerStillNamesTheStretch() {
        XCTAssertEqual(
            stretches([warm(40)], prompts: [ChatPrompt(at: minute(15), text: "Review the installer")]).first?.prompt,
            "Review the installer",
            "answered 25 minutes later"
        )
        XCTAssertNil(
            stretches([warm(100)], prompts: [ChatPrompt(at: minute(39), text: "Review the installer")]).first?.prompt,
            "61 minutes before, with no earlier turn of the chat to say, it is not taken"
        )
    }
}
