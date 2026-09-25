import XCTest
@testable import Omelette

/// Which chats History's Sessions list shows and in what order: the ten most recent by
/// `lastAt`, plus up to five more by cost, merged and ordered newest first — and a chip
/// on the ones that got in for what they cost.
/// Spec: docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4.
final class SessionListRuleTests: XCTestCase {
    /// Ten cheap chats from the last ten hours, then six expensive ones from four days
    /// ago — the shape the rule exists for.
    private func recentAndExpensive() -> [SessionSummary] {
        var sessions = (1...10).map {
            SessionFixture.simple(id: "recent\($0)", hoursAgo: Double($0), cost: 1)
        }
        sessions += (1...6).map {
            SessionFixture.simple(id: "old\($0)", hoursAgo: 100 + Double($0), cost: 100 - Double($0))
        }
        return sessions
    }

    func testFewerChatsThanTheRecentLimitAreAllShownAndNoneIsChipped() {
        let sessions = (1...4).map {
            SessionFixture.simple(id: "s\($0)", hoursAgo: Double($0), cost: Double($0))
        }

        let rows = SessionListRule.pick(sessions: sessions)

        XCTAssertEqual(rows.map(\.id), ["s1", "s2", "s3", "s4"], "newest first")
        XCTAssertTrue(rows.allSatisfy { !$0.isTop }, "nothing is on the list *only* for its cost")
    }

    func testTheFiveMostExpensiveOlderChatsJoinTheTenMostRecent() {
        let rows = SessionListRule.pick(sessions: recentAndExpensive())

        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(rows.prefix(10).map(\.id), (1...10).map { "recent\($0)" })
        XCTAssertEqual(rows.suffix(5).map(\.id), ["old1", "old2", "old3", "old4", "old5"])
        XCTAssertTrue(rows.suffix(5).allSatisfy(\.isTop), "they are here for the money")
        XCTAssertTrue(rows.prefix(10).allSatisfy { !$0.isTop })
        XCTAssertFalse(rows.contains { $0.id == "old6" }, "the sixth most expensive is one too many")
    }

    func testAnExpensiveChatThatIsAlsoRecentIsNeitherDuplicatedNorChipped() {
        var sessions = (1...10).map {
            SessionFixture.simple(id: "recent\($0)", hoursAgo: Double($0), cost: 1)
        }
        sessions[0] = SessionFixture.simple(id: "recent1", hoursAgo: 1, cost: 999)
        sessions.append(SessionFixture.simple(id: "old1", hoursAgo: 200, cost: 5))

        let rows = SessionListRule.pick(sessions: sessions)

        XCTAssertEqual(rows.filter { $0.id == "recent1" }.count, 1, "one row per chat")
        XCTAssertEqual(rows.first { $0.id == "recent1" }?.isTop, false, "it was already on the list")
        XCTAssertEqual(rows.first { $0.id == "old1" }?.isTop, true)
    }

    func testAChatWithNoPricedCostRanksAsZeroRatherThanCrashing() {
        // Grok prices a turn as a whole and leaves no split; nothing in this list may
        // invent a dollar figure for it.
        let unpriced = SessionFixture.session(
            id: "unpriced", lastAt: SessionFixture.at(hoursBefore: 300),
            tokens: SessionFixture.tokens(input: 10_000, output: 500)
        )

        XCTAssertEqual(SessionListRule.cost(of: unpriced), 0)
        let rows = SessionListRule.pick(sessions: recentAndExpensive() + [unpriced])
        XCTAssertFalse(rows.contains { $0.id == "unpriced" }, "old and worth $0 is not a top spend")
    }

    func testTheChipIsTheSameRowWhetherTheListIsShortOrFull() {
        let sessions = recentAndExpensive()

        let short = Set(SessionListRule.pick(sessions: sessions).filter(\.isTop).map(\.id))
        let full = Set(SessionListRule.sorted(sessions, by: .recent).filter(\.isTop).map(\.id))

        XCTAssertEqual(short, full, "expanding the list must not move a chip")
    }

    func testSortedKeepsEveryChatAndAnswersBothQuestions() {
        let sessions = recentAndExpensive()

        let byRecent = SessionListRule.sorted(sessions, by: .recent)
        let byCost = SessionListRule.sorted(sessions, by: .cost)

        XCTAssertEqual(byRecent.count, 16)
        XCTAssertEqual(byCost.count, 16)
        XCTAssertEqual(byRecent.first?.id, "recent1")
        XCTAssertEqual(byCost.first?.id, "old1", "$99 is the most expensive")
        // The ten $1 chats tie, so the id orders them ascending — "recent1", "recent10",
        // "recent2" … "recent9" — and the last of the list is the last of that run.
        XCTAssertEqual(byCost.last?.id, "recent9", "ties at $1 fall back to the id")
    }

    func testTiesAreBrokenByIdSoTheListNeverReordersItself() {
        let b = SessionFixture.simple(id: "b", hoursAgo: 3, cost: 5)
        let a = SessionFixture.simple(id: "a", hoursAgo: 3, cost: 5)

        XCTAssertEqual(SessionListRule.sorted([b, a], by: .recent).map(\.id), ["a", "b"])
        XCTAssertEqual(SessionListRule.sorted([b, a], by: .cost).map(\.id), ["a", "b"])
    }

    func testAnEmptyListIsAnEmptyList() {
        XCTAssertTrue(SessionListRule.pick(sessions: []).isEmpty)
        XCTAssertTrue(SessionListRule.sorted([], by: .cost).isEmpty)
        XCTAssertTrue(SessionListRule.topSpendIDs(sessions: []).isEmpty)
    }

    func testShowAllIsOfferedOnlyWhenSomethingIsHidden() {
        XCTAssertTrue(SessionListRule.canShowAll(shown: 15, total: 34))
        XCTAssertFalse(SessionListRule.canShowAll(shown: 4, total: 4))
    }

    /// The sort is persisted under a raw String, so its cases are a storage contract.
    func testTheSortToggleSpellsItselfForPeopleAndForStorage() {
        XCTAssertEqual(SessionListRule.Sort.allCases, [.recent, .cost])
        XCTAssertEqual(SessionListRule.Sort.recent.rawValue, "recent")
        XCTAssertEqual(SessionListRule.Sort.cost.rawValue, "cost")
        XCTAssertEqual(SessionListRule.Sort.recent.displayName, "Recent")
        XCTAssertEqual(SessionListRule.Sort.cost.displayName, "Cost")
        XCTAssertNil(SessionListRule.Sort(rawValue: "spend"))
    }

    func testTheDefaultsAreTheSpecsTenAndFive() {
        XCTAssertEqual(SessionListRule.defaultRecent, 10)
        XCTAssertEqual(SessionListRule.defaultTop, 5)
    }

    // MARK: - Inside one chat

    /// Measured on this Mac: one chat has 1,235 sub-agent transcripts (the next two,
    /// 487 and 244). An expanded row that drew a line per agent would be a mile of
    /// table nobody scrolls, built on the main actor on every re-render.
    func testOnlyTheEightMostExpensiveSubAgentsAreDrawn() {
        let agents = (1...1_235).map {
            SessionFixture.agent(
                id: String(format: "a%04d", $0),
                tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: Double($0)))
            )
        }

        let picked = SessionListRule.pickAgents(agents)

        XCTAssertEqual(picked.count, 8)
        XCTAssertEqual(picked.count, SessionListRule.maxAgentRows)
        XCTAssertEqual(picked.map(\.id), (1_228...1_235).reversed().map { String(format: "a%04d", $0) })
    }

    func testAChatWithFewerAgentsThanTheCapShowsThemAll() {
        let agents = (1...3).map {
            SessionFixture.agent(id: "a\($0)", tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: Double($0))))
        }
        XCTAssertEqual(SessionListRule.pickAgents(agents).map(\.id), ["a3", "a2", "a1"])
    }

    func testAgentsAreOrderedByCostWhateverOrderTheyArriveIn() {
        let cheap = SessionFixture.agent(id: "a1", tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: 1)))
        let dear = SessionFixture.agent(id: "a2", tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: 9)))
        let free = SessionFixture.agent(id: "a3", tokens: SessionFixture.tokens(input: 10))

        XCTAssertEqual(SessionListRule.agentsByCost([cheap, free, dear]).map(\.id), ["a2", "a1", "a3"])
    }

    func testTheByDayTableKeepsTheFourteenMostRecentDaysInOrder() {
        // 90 days is a range the picker offers, and a chat can span all of it.
        let days = (0..<90).map { SessionFixture.day(daysBefore: 89 - $0) }

        let picked = SessionListRule.pickDays(days)

        XCTAssertEqual(picked.count, 14)
        XCTAssertEqual(picked.count, SessionListRule.maxDayRows)
        XCTAssertEqual(picked.first?.day, SessionFixture.startOfDay(daysBefore: 13))
        XCTAssertEqual(picked.last?.day, SessionFixture.startOfDay(daysBefore: 0), "still ascending")
    }

    func testAShortChatKeepsEveryDayAndTheirOrder() {
        let days = [SessionFixture.day(daysBefore: 2), SessionFixture.day(daysBefore: 1)]
        XCTAssertEqual(SessionListRule.pickDays(days).map(\.day), days.map(\.day))
    }

    // MARK: - The model rows inside one chat

    private func models(_ costs: [Double]) -> [SessionModelSummary] {
        costs.enumerated().map { index, dollars in
            SessionFixture.model(
                model: "model-\(index)", effort: "high", turns: 1,
                tokens: SessionFixture.tokens(
                    input: 1_000, cost: SessionFixture.cost(input: dollars)
                )
            )
        }
    }

    func testOnlyTheSixMostExpensiveModelsAreDrawn() {
        let drawn = SessionListRule.pickModels(models([1, 9, 2, 8, 3, 7, 4, 6]))

        XCTAssertEqual(drawn.count, 6, "six rows, and the button says how many are left")
        XCTAssertEqual(
            drawn.map { $0.tokens.cost?.total ?? -1 }, [9, 8, 7, 6, 4, 3],
            "most expensive first, whatever order they arrived in"
        )
    }

    func testAChatOnFewerModelsThanTheCapShowsThemAll() {
        XCTAssertEqual(SessionListRule.pickModels(models([1, 2, 3])).count, 3)
    }

    func testModelsThatCostTheSameFallBackToTheirKey() {
        let rows = [
            SessionFixture.model(model: "claude-opus-4-5", effort: "xhigh", turns: 1),
            SessionFixture.model(model: "claude-opus-4-5", effort: "high", turns: 1),
            SessionFixture.model(model: "claude-haiku-4-5", effort: nil, turns: 1),
        ]

        XCTAssertEqual(
            SessionListRule.modelsByCost(rows).map(\.id),
            ["claude-haiku-4-5|", "claude-opus-4-5|high", "claude-opus-4-5|xhigh"],
            "an unpriced row ranks as zero, and the key keeps the order from wandering"
        )
    }

    func testTheModelTableIsWorthDrawingOnlyWhenItSplitsSomething() {
        XCTAssertFalse(SessionListRule.showsModels([]), "a chat with no rows has no table")
        XCTAssertFalse(
            SessionListRule.showsModels([SessionFixture.model(effort: nil)]),
            "one model and no effort is the chat restated"
        )
        XCTAssertTrue(
            SessionListRule.showsModels([SessionFixture.model(effort: "xhigh")]),
            "the effort is a fact no other row of the expanded chat carries"
        )
        XCTAssertTrue(
            SessionListRule.showsModels([
                SessionFixture.model(model: "claude-opus-4-5", effort: nil),
                SessionFixture.model(model: "claude-haiku-4-5", effort: nil),
            ]),
            "two models always split something"
        )
    }

    func testTheModelCapIsTheSpecsSix() {
        XCTAssertEqual(SessionListRule.maxModelRows, 6)
    }
}
