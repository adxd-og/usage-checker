import XCTest
@testable import Omelette

/// Independent verification of `SessionListRule` against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § 4 and the plan's own
/// decisions 3 and 4 ("The chip is decided once", "Ordering is total"). Written from the
/// spec and the diff, not from `SessionListRuleTests` — this file asserts boundaries the
/// executor's own suite does not: the exact 15-total edge, ties that fall on the
/// recent/top cutoff itself (not just ties inside a fully-sorted list), and the 8/9/0 and
/// 14/15 caps at their exact values.
final class SessionListRuleVerificationTests: XCTestCase {
    // MARK: - The merged list at its exact capacity

    /// 10 recent + 5 distinct-cost old chats, none tied: every one of the 15 must
    /// survive the pick, and "Show all" must have nothing left to reveal.
    func testExactlyFifteenDistinctChatsAllSurviveThePickWithNothingCut() {
        let recent = (1...10).map {
            SessionFixture.simple(id: "recent\($0)", hoursAgo: Double($0), cost: 1)
        }
        let old = (1...5).map {
            SessionFixture.simple(id: "old\($0)", hoursAgo: 200 + Double($0), cost: 51 - Double($0))
        }
        let sessions = recent + old

        let rows = SessionListRule.pick(sessions: sessions)

        XCTAssertEqual(rows.count, 15, "10 recent plus 5 old, no overlap, nothing should be dropped")
        XCTAssertEqual(Set(rows.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertFalse(SessionListRule.canShowAll(shown: rows.count, total: sessions.count))
    }

    // MARK: - A tie exactly at the recent/top cutoff

    /// Nine chats with distinct, strictly-recent timestamps, then two more — "x" and
    /// "y" — tied at the same `lastAt`, one position past the recent cutoff. The tie is
    /// broken by id, so "x" (alphabetically first) is the one that fills the tenth
    /// recent slot; "y" is pushed out of the recent pick entirely. "y" is given a huge
    /// cost so it still reaches the list — but only via the *top-spend* door, with the
    /// chip to prove it, while "x" (identical timestamp, one-tenth the cost) carries no
    /// chip at all because it got in on recency.
    func testATieAtTheRecentCutoffIsBrokenByIdAndDecidesWhichDoorAChatEntersThrough() {
        let nineDistinct = (1...9).map {
            SessionFixture.simple(id: "a\($0)", hoursAgo: Double($0), cost: 1)
        }
        let x = SessionFixture.simple(id: "x", hoursAgo: 10, cost: 1)
        let y = SessionFixture.simple(id: "y", hoursAgo: 10, cost: 1_000)
        let sessions = nineDistinct + [x, y]

        let rows = SessionListRule.pick(sessions: sessions)

        XCTAssertEqual(rows.count, 11, "every chat here is either recent or top spend")
        XCTAssertEqual(rows.first { $0.id == "x" }?.isTop, false, "x filled the tied recent slot")
        XCTAssertEqual(rows.first { $0.id == "y" }?.isTop, true, "y only got in for what it cost")
    }

    // MARK: - A tie exactly at the top-spend cutoff

    /// Ten recent chats (irrelevant cost) plus six older chats tied on cost: the top
    /// pick keeps five of them, so the tie must be broken by id — otherwise the fifth
    /// and sixth would be interchangeable and the list could reorder itself.
    func testATieAtTheTopSpendCutoffIsBrokenByIdNotByArrivalOrder() {
        let recent = (1...10).map {
            SessionFixture.simple(id: "r\($0)", hoursAgo: Double($0), cost: 0)
        }
        let tiedOld = (1...6).map {
            SessionFixture.simple(id: "o\($0)", hoursAgo: 300, cost: 10)
        }
        let sessions = recent + tiedOld

        let topIDs = SessionListRule.topSpendIDs(sessions: sessions)

        XCTAssertEqual(topIDs, ["o1", "o2", "o3", "o4", "o5"], "lowest ids among the tie win the five slots")
        let rows = SessionListRule.pick(sessions: sessions)
        XCTAssertFalse(rows.contains { $0.id == "o6" }, "o6 lost the tie and must not appear")
        XCTAssertTrue(SessionListRule.canShowAll(shown: rows.count, total: sessions.count))
    }

    // MARK: - sorted(by:) is deterministic across repeated calls

    func testSortedProducesTheSameOrderOnEveryCall() {
        let sessions = (1...9).map {
            SessionFixture.simple(id: "s\($0)", hoursAgo: Double($0 % 3), cost: Double($0 % 4))
        }

        let recentFirst = SessionListRule.sorted(sessions, by: .recent).map(\.id)
        let recentSecond = SessionListRule.sorted(sessions, by: .recent).map(\.id)
        let costFirst = SessionListRule.sorted(sessions, by: .cost).map(\.id)
        let costSecond = SessionListRule.sorted(sessions, by: .cost).map(\.id)

        XCTAssertEqual(recentFirst, recentSecond, "two identical reads must produce the same list")
        XCTAssertEqual(costFirst, costSecond)
    }

    // MARK: - pickAgents at its exact cap boundaries

    private func agent(_ n: Int) -> SessionAgentSummary {
        SessionFixture.agent(
            id: "a\(n)",
            tokens: SessionFixture.tokens(input: 10, cost: SessionFixture.cost(input: Double(n)))
        )
    }

    func testPickAgentsAtExactlyEightDrawsAllOfThemUnclipped() {
        let agents = (1...8).map(agent)
        XCTAssertEqual(SessionListRule.pickAgents(agents), SessionListRule.agentsByCost(agents))
        XCTAssertEqual(SessionListRule.pickAgents(agents).count, 8)
    }

    func testPickAgentsAtNineDropsExactlyTheCheapestOne() {
        let agents = (1...9).map(agent)
        let picked = SessionListRule.pickAgents(agents)
        XCTAssertEqual(picked.count, 8)
        XCTAssertFalse(picked.contains { $0.id == "a1" }, "a1 is the cheapest and the one over the cap")
    }

    func testPickAgentsWithNoAgentsIsEmpty() {
        XCTAssertTrue(SessionListRule.pickAgents([]).isEmpty)
    }

    // MARK: - pickDays at its exact cap boundaries

    private func day(_ daysBefore: Int) -> SessionDaySummary {
        SessionFixture.day(daysBefore: daysBefore)
    }

    func testPickDaysAtExactlyFourteenKeepsEveryDayInOrder() {
        let days = (0..<14).map { day(13 - $0) }
        XCTAssertEqual(SessionListRule.pickDays(days).map(\.day), days.map(\.day))
    }

    func testPickDaysAtFifteenDropsExactlyTheOldestOne() {
        let days = (0..<15).map { day(14 - $0) }
        let picked = SessionListRule.pickDays(days)
        XCTAssertEqual(picked.count, 14)
        XCTAssertEqual(picked.first?.day, SessionFixture.startOfDay(daysBefore: 13), "the oldest day is the one cut")
        XCTAssertEqual(picked.last?.day, SessionFixture.startOfDay(daysBefore: 0))
    }
}
