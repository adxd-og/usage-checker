import XCTest
@testable import Omelette

/// Stretch edges: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab,
/// item 5. A stretch starts at the chat's first turn, a compaction or a cold start (Claude:
/// cache read under 5 % of input + cache read + cache write, with a cache write of at least
/// 10,000; Codex: cache read under 5 % of an input of at least 10,000). Beginnings less than
/// 10 minutes apart merge. Points come from the bins' split of the chat's points, by the
/// chat's dollars per bin, a bin with no turn of the chat using the previous bin. The cold
/// start costs fresh input plus cache write. The prompt is the first one after the chat's
/// previous main-thread turn, else within 60 minutes before the stretch's first main turn;
/// after a compaction, the first prompt after it.
final class LimitStretchesVerificationTests: XCTestCase {
    /// 2026-09-06 10:00 UTC, a Sunday.
    private let t0 = Date(timeIntervalSince1970: 1_788_688_800)
    private var window: LimitWindow { LimitWindow(start: t0, end: t0.addingTimeInterval(8 * 3_600)) }

    private func minute(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }

    private func warm(_ m: Double, chat: String = "chat-a", isMain: Bool = true) -> TurnCost {
        Fixture.promptTurn(at: minute(m), chat: chat, input: 1_000, cacheRead: 100_000, output: 2_000, isMainThread: isMain)
    }

    private func cold(_ m: Double, chat: String = "chat-a", isMain: Bool = true) -> TurnCost {
        Fixture.promptTurn(at: minute(m), chat: chat, cacheWrite1h: 50_000, output: 1_000, isMainThread: isMain)
    }

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

    // MARK: - Cold start thresholds

    func testAClaudeTurnReadingExactlyFivePercentOfItsPromptIsNotCold() {
        // 9,000 fresh + 1,000 read + 10,000 written: a 20,000 prompt, 5 % read.
        let edge = Fixture.promptTurn(at: t0, chat: "c", input: 9_000, cacheRead: 1_000, cacheWrite1h: 10_000)
        let under = Fixture.promptTurn(at: t0, chat: "c", input: 9_000, cacheRead: 999, cacheWrite1h: 10_000)
        XCTAssertFalse(LimitShareRules.isColdStart(edge, serviceID: "claude"), "5 % is not under 5 %")
        XCTAssertTrue(LimitShareRules.isColdStart(under, serviceID: "claude"))
    }

    func testTheFivePercentIsOfFreshInputPlusReadPlusWriteNotOfReadPlusWrite() {
        // 100,000 fresh input around 1,000 read and 10,000 written: 0.9 % of 111,000.
        let turn = Fixture.promptTurn(at: t0, chat: "c", input: 100_000, cacheRead: 1_000, cacheWrite5m: 10_000)
        XCTAssertTrue(LimitShareRules.isColdStart(turn, serviceID: "claude"))
        // With input left out it would be 1,000 of 11,000 = 9 %.
        XCTAssertEqual(LimitShareRules.rebuildCost(turn), turn.tokens.cost!.input + turn.tokens.cost!.cacheWrite, accuracy: 1e-12)
    }

    func testTheCacheWriteOfBothLifetimesCountsTowardTenThousand() {
        let split = Fixture.promptTurn(at: t0, chat: "c", cacheWrite5m: 4_000, cacheWrite1h: 6_000)
        let short = Fixture.promptTurn(at: t0, chat: "c", cacheWrite5m: 4_000, cacheWrite1h: 5_999)
        XCTAssertTrue(LimitShareRules.isColdStart(split, serviceID: "claude"))
        XCTAssertFalse(LimitShareRules.isColdStart(short, serviceID: "claude"))
    }

    func testACodexTurnIsColdAtExactlyTenThousandTokensAndUnderFivePercent() {
        func codex(input: Int, cacheRead: Int) -> TurnCost {
            Fixture.promptTurn(at: t0, chat: "c", input: input, cacheRead: cacheRead)
        }
        XCTAssertTrue(LimitShareRules.isColdStart(codex(input: 10_000, cacheRead: 0), serviceID: "codex"))
        XCTAssertFalse(LimitShareRules.isColdStart(codex(input: 9_999, cacheRead: 0), serviceID: "codex"))
        XCTAssertFalse(LimitShareRules.isColdStart(codex(input: 19_000, cacheRead: 1_000), serviceID: "codex"), "exactly 5 %")
        XCTAssertTrue(LimitShareRules.isColdStart(codex(input: 19_001, cacheRead: 999), serviceID: "codex"))
        XCTAssertFalse(LimitShareRules.isColdStart(codex(input: 0, cacheRead: 0), serviceID: "codex"), "an empty prompt")
    }

    // MARK: - Beginnings less than ten minutes apart

    func testBeginningsExactlyTenMinutesApartAreTwoStretchesAndJustUnderAreOne() {
        let atTen = stretches([warm(10), cold(20), warm(25)])
        XCTAssertEqual(atTen.map(\.opening), [.firstTurn, .coldStart], "10 minutes is not less than 10")
        let justUnder = stretches([warm(10), cold(19.9), warm(25)])
        XCTAssertEqual(justUnder.map(\.opening), [.firstTurn])
        XCTAssertEqual(justUnder.first?.coldStartCost ?? 0, 0.30, accuracy: 1e-9, "the merged rebuild still cost")
    }

    func testACompactionAndAColdStartInsideTenMinutesAreOneStretchOpenedByTheCompaction() {
        let result = stretches(
            [warm(10), warm(50), cold(63), warm(70)],
            compactions: [minute(60)],
            prompts: [ChatPrompt(at: minute(61), text: "Now the changelog")]
        )
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .compaction])
        XCTAssertEqual(result.last?.prompt, "Now the changelog")
        XCTAssertEqual(result.last?.firstAt, minute(63))
        XCTAssertEqual(result.last?.coldStartCost ?? 0, 0.30, accuracy: 1e-9)
    }

    func testACompactionBeforeTheChatsFirstTurnOrAfterItsLastCutsNothing() {
        let result = stretches([warm(10), warm(40)], compactions: [minute(10), minute(9), minute(500)])
        XCTAssertEqual(result.count, 1, "at the first turn, before it, and after the window: no stretch of their own")
    }

    // MARK: - Names

    func testAPromptSixtyMinutesBeforeTheFirstTurnNamesTheStretchAndOneSecondMoreDoesNot() {
        let exact = stretches([warm(100)], prompts: [ChatPrompt(at: minute(40), text: "On the dot")])
        XCTAssertEqual(exact.first?.prompt, "On the dot", "within 60 minutes before the first main-thread turn")
        let over = stretches([warm(100)], prompts: [ChatPrompt(at: minute(40).addingTimeInterval(-1), text: "Too early")])
        XCTAssertNil(over.first?.prompt)
    }

    func testWithAnEarlierTurnOfTheChatThePromptNeedNotBeWithinAnHour() {
        // Typed 3 hours after the chat's previous main-thread turn, answered 3 hours later by a cold start.
        let result = stretches(
            [warm(10), cold(240)],
            prompts: [
                ChatPrompt(at: minute(9), text: "First task"),
                ChatPrompt(at: minute(20), text: "Second task, typed long before it was answered"),
            ]
        )
        XCTAssertEqual(result.map(\.prompt), ["First task", "Second task, typed long before it was answered"])
    }

    func testTheFirstPromptAfterThePreviousTurnNamesAColdStartNotALaterOne() {
        let result = stretches(
            [warm(10), cold(120)],
            prompts: [
                ChatPrompt(at: minute(9), text: "First task"),
                ChatPrompt(at: minute(110), text: "Typed first after the pause"),
                ChatPrompt(at: minute(118), text: "Typed second"),
            ]
        )
        XCTAssertEqual(result.last?.prompt, "Typed first after the pause")
    }

    func testAPromptTypedBeforeACompactionDoesNotNameTheStretchItOpened() {
        let result = stretches(
            [warm(10), warm(50), warm(70)],
            compactions: [minute(60)],
            prompts: [
                ChatPrompt(at: minute(9), text: "First task"),
                ChatPrompt(at: minute(55), text: "Typed before the compaction"),
                ChatPrompt(at: minute(62), text: "Typed after it"),
            ]
        )
        XCTAssertEqual(result.map(\.prompt), ["First task", "Typed after it"])
    }

    func testAPromptAtTheInstantOfThePreviousMainTurnIsNotAfterIt() {
        // The prompt that asked for the turn at minute 10 is logged in the same second as the turn.
        let result = stretches(
            [warm(10), cold(120)],
            prompts: [
                ChatPrompt(at: minute(9), text: "First task"),
                ChatPrompt(at: minute(10), text: "Typed with the previous turn"),
                ChatPrompt(at: minute(115), text: "After the pause"),
            ]
        )
        XCTAssertEqual(result.last?.prompt, "After the pause", "the first prompt after the previous turn, not at it")
    }

    func testAPromptAtTheInstantOfACompactionNamesTheStretch() {
        let result = stretches(
            [warm(10), warm(70)], compactions: [minute(60)],
            prompts: [ChatPrompt(at: minute(9), text: "First task"), ChatPrompt(at: minute(60), text: "At once")]
        )
        XCTAssertEqual(result.last?.prompt, "At once", "the first prompt after the compaction")
    }

    func testAPromptTypedAfterAStretchsLastTurnNeverNamesIt() {
        let result = stretches(
            [warm(10), cold(120)],
            prompts: [ChatPrompt(at: minute(9), text: "First task"), ChatPrompt(at: minute(300), text: "Typed long after")]
        )
        XCTAssertEqual(result.map(\.prompt), ["First task", nil])
    }

    func testASubAgentsTurnOpeningAStretchesWindowDoesNotMoveItsPromptBound() {
        // Main turn at 10; the pause; a sub-agent's turn at 118; the cold main turn at 120. The prompt at
        // 112 came after the last main-thread turn, whatever the sub-agent did at 118.
        let result = stretches(
            [warm(10), warm(118, isMain: false), cold(120)],
            prompts: [ChatPrompt(at: minute(9), text: "First task"), ChatPrompt(at: minute(112), text: "After the pause")]
        )
        XCTAssertEqual(result.last?.prompt, "After the pause")
    }

    // MARK: - Points and dollars add up

    func testAChatsStretchesAddUpToItsPointsAndDollars() throws {
        // Three chats over four hours; chat A has a sub-agent, a compaction and two cold
        // starts; the readings rise in half hours with turns, in one with none (the lag) and in
        // one whose only turn is another chat's.
        let a = [
            warm(5), warm(20, isMain: false), warm(35), cold(100), warm(110), warm(111, isMain: false),
            cold(170), warm(175), warm(200),
        ]
        let b = [warm(40, chat: "chat-b"), warm(130, chat: "chat-b"), cold(135, chat: "chat-b")]
        let c = [warm(64, chat: "chat-c"), warm(150, chat: "chat-c")]
        let log = TurnCostLog(
            turns: (a + b + c).sorted { $0.timestamp < $1.timestamp },
            compactions: ["chat-a": [minute(150)], "chat-b": [minute(132)]]
        )
        let readings = [
            (30.0, 2.0), (59.0, 4.0), (95.0, 5.0), (125.0, 9.0), (155.0, 11.0), (165.0, 12.0), (185.0, 15.0), (230.0, 16.0),
        ].map { LimitReading(time: minute($0.0), percent: $0.1) }
        let share = LimitShareRules.share(window: window, series: readings, log: log)
        let all = LimitShareRules.stretches(of: share, log: log, serviceID: "claude")
        for chat in share.chats {
            let cut = try XCTUnwrap(all[chat.id], "chat \(chat.id)")
            XCTAssertEqual(cut.reduce(0) { $0 + $1.points }, chat.points, accuracy: 1e-9, "points of \(chat.id)")
            XCTAssertEqual(cut.reduce(0) { $0 + $1.cost }, chat.cost, accuracy: 1e-9, "dollars of \(chat.id)")
            XCTAssertEqual(cut.map(\.firstAt), cut.map(\.firstAt).sorted(), "oldest first")
            for (before, after) in zip(cut, cut.dropFirst()) {
                XCTAssertLessThanOrEqual(before.lastAt, after.firstAt, "stretches of \(chat.id) do not overlap")
            }
        }
        XCTAssertGreaterThan(all["chat-a"]?.count ?? 0, 2)
    }

    func testAHalfHourSplitBetweenTwoStretchesGoesByTheChatsDollarsInIt() throws {
        // One half hour (60–90): $90 before the compaction at minute 75, $10 after. It gave
        // the chat 10 points.
        let result = stretches(
            [
                Fixture.turnCost(at: minute(50), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: minute(70), chat: "chat-a", cost: 90),
                Fixture.turnCost(at: minute(80), chat: "chat-a", cost: 10),
            ],
            rises: [(minute: 85, percent: 10)],
            compactions: [minute(75)]
        )
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .compaction])
        XCTAssertEqual(result[0].points, 9, accuracy: 1e-9)
        XCTAssertEqual(result[1].points, 1, accuracy: 1e-9)
    }

    func testTwoChatsInOneHalfHourEachKeepTheirOwnPointsWhateverTheOtherDoes() throws {
        let log = TurnCostLog(
            turns: [
                Fixture.turnCost(at: minute(10), chat: "chat-a", cost: 30),
                Fixture.turnCost(at: minute(20), chat: "chat-b", cost: 10),
                Fixture.turnCost(at: minute(100), chat: "chat-b", cost: 10),
            ],
            compactions: ["chat-b": [minute(60)]]
        )
        let share = LimitShareRules.share(
            window: window,
            series: [LimitReading(time: minute(25), percent: 4), LimitReading(time: minute(110), percent: 6)],
            log: log
        )
        let all = LimitShareRules.stretches(of: share, log: log, serviceID: "claude")
        XCTAssertEqual(all["chat-a"]?.map(\.points).first ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(all["chat-b"]?.map(\.points) ?? [], [1, 2], "its quarter of the first half hour, all of the second step")
    }

    func testAColdStartCostIsFreshInputPlusCacheWriteOfEveryLaterColdTurnInTheStretchNotTheFirstTurns() {
        // The chat's first turn builds its context (cold by the numbers, not a rebuild). The second is a
        // cold start three minutes later, merged into the same stretch: input 1,000 @ $3/M, write 20,000 @ $3.75/M.
        let first = Fixture.promptTurn(at: minute(10), chat: "chat-a", input: 2_000, cacheWrite1h: 50_000, output: 1_000)
        let later = Fixture.promptTurn(at: minute(13), chat: "chat-a", input: 1_000, cacheWrite5m: 20_000, output: 500)
        let result = stretches([first, later, warm(20)])
        let expected = (1_000 * 3.0 + 20_000 * 3.75) / 1_000_000
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.coldStartCost ?? 0, expected, accuracy: 1e-9)
    }
}
