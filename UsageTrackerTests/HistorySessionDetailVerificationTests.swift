import XCTest
@testable import Omelette

/// Independent verification of `HistorySessionDetail` / `HistoryMoneySplit` against
/// liquid-glass spec § Screens "History · Session expanded" (cost bar by type, By
/// model and By day, Sub-agents) and § Decisions "Agent time per chat: not shown".
final class HistorySessionDetailVerificationTests: XCTestCase {
    // MARK: - HistoryMoneySplit.build: shares sum to 1 for a priced chat

    func testMoneySplitSharesSumToOneForAPricedChat() {
        let breakdown = SessionFixture.tokens(
            input: 1_000, output: 2_000, cacheRead: 500,
            cost: SessionFixture.cost(input: 1.0, output: 2.0, cacheRead: 0.5)
        )
        let split = HistoryMoneySplit.build(breakdown)
        XCTAssertEqual(split.title, "Where the money went")
        XCTAssertEqual(split.total, "$3.50")
        let shareSum = split.segments.reduce(0) { $0 + $1.share }
        XCTAssertEqual(shareSum, 1.0, accuracy: 0.0001)
        XCTAssertEqual(split.segments.count, 3, "only categories with tokens appear")
    }

    func testMoneySplitOnAnUnpricedChatHasNoTotalAndZeroShares() {
        let breakdown = SessionFixture.tokens(input: 1_000, output: 500) // no .cost
        let split = HistoryMoneySplit.build(breakdown)
        XCTAssertEqual(split.title, "Tokens by type", "no dollars promised")
        XCTAssertNil(split.total)
        XCTAssertTrue(split.segments.allSatisfy { $0.share == 0 })
        XCTAssertTrue(split.segments.allSatisfy { $0.cost == nil })
    }

    func testThinkingIsCarriedSeparatelyNotAsItsOwnSegment() {
        let breakdown = SessionFixture.tokens(input: 1_000, output: 500, thinking: 200)
        let split = HistoryMoneySplit.build(breakdown)
        XCTAssertEqual(split.thinking, TokenFormat.formatTokens(200))
        XCTAssertFalse(split.segments.contains { $0.category.label == "Thinking" })
    }

    func testThinkingIsNilWhenThereIsNone() {
        let breakdown = SessionFixture.tokens(input: 1_000)
        XCTAssertNil(HistoryMoneySplit.build(breakdown).thinking)
    }

    // MARK: - widths: minimum kept, gaps subtracted, last segment takes the remainder

    func testWidthsSumToTheBarMinusGapsExactly() {
        let widths = HistoryMoneySplit.widths(shares: [0.7, 0.2, 0.1], in: 100, minimum: 3, gap: 2)
        let gaps = 2.0 * 2 // two gaps between three segments
        XCTAssertEqual(widths.reduce(0, +), 100 - gaps, accuracy: 0.001)
    }

    func testWidthsNeverDropASliverShareBelowItsMinimum() {
        let widths = HistoryMoneySplit.widths(shares: [0.999, 0.001], in: 100, minimum: 3, gap: 2)
        XCTAssertGreaterThanOrEqual(widths[1], 3 - 0.01, "a 0.1% type stays visible")
    }

    func testWidthsOnAZeroWidthBarAreAllZero() {
        let widths = HistoryMoneySplit.widths(shares: [0.5, 0.5], in: 0, minimum: 3, gap: 2)
        XCTAssertEqual(widths, [0, 0])
    }

    // MARK: - HistorySessionDetail.build: today, model shares, day shares, agent rows

    func testTodayDayIDIsSetOnlyWhenTheChatRanToday() {
        let now = SessionFixture.now
        let calendar = SessionFixture.calendar
        let today = calendar.startOfDay(for: now)
        let ranToday = SessionFixture.session(
            id: "a", tokens: SessionFixture.tokens(input: 10),
            days: [SessionDaySummary(day: today, turns: 1, tokens: SessionFixture.tokens(input: 10))]
        )
        let detail = HistorySessionDetail.build(
            session: ranToday, allAgents: true, allDays: true, allModels: true, now: now, calendar: calendar
        )
        XCTAssertNotNil(detail.todayDayID)

        let ranYesterday = SessionFixture.session(
            id: "b", tokens: SessionFixture.tokens(input: 10),
            days: [SessionFixture.day(daysBefore: 1)]
        )
        let detail2 = HistorySessionDetail.build(
            session: ranYesterday, allAgents: true, allDays: true, allModels: true, now: now, calendar: calendar
        )
        XCTAssertNil(detail2.todayDayID)
    }

    func testModelSharesAreRelativeToTheMostExpensiveModel() {
        let expensive = SessionModelSummary(
            model: "opus", effort: "xhigh", turns: 5,
            tokens: SessionFixture.tokens(input: 1_000, cost: SessionFixture.cost(input: 10))
        )
        let cheap = SessionModelSummary(
            model: "haiku", effort: nil, turns: 5,
            tokens: SessionFixture.tokens(input: 1_000, cost: SessionFixture.cost(input: 2.5))
        )
        let session = SessionFixture.session(id: "c", models: [expensive, cheap])
        let detail = HistorySessionDetail.build(session: session, allAgents: false, allDays: false, allModels: true)
        XCTAssertEqual(detail.modelShares[expensive.id] ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(detail.modelShares[cheap.id] ?? -1, 0.25, accuracy: 0.0001)
    }

    func testAgentRowsBlankTheMainThreadsModelAndEffort() {
        let agent = SessionFixture.agent(id: "sub-1", model: "claude-opus-4-5", effort: "high", turns: 3)
        let session = SessionFixture.session(id: "d", agents: [agent])
        let detail = HistorySessionDetail.build(session: session, allAgents: true, allDays: false, allModels: false)
        guard let main = detail.agentRows.first(where: { $0.isMain }) else {
            return XCTFail("expected a main-thread row")
        }
        XCTAssertEqual(main.model, "", "the chat names no model of its own")
        XCTAssertEqual(main.effort, "")
        guard let sub = detail.agentRows.first(where: { !$0.isMain }) else {
            return XCTFail("expected the sub-agent row")
        }
        XCTAssertFalse(sub.model.isEmpty, "a sub-agent's model is never blanked")
        XCTAssertNotEqual(sub.model, "—", "a known model resolves to a display name")
        XCTAssertEqual(sub.effort, "high")
    }

    func testShareIsClampedAndZeroWhenMaxIsZero() {
        XCTAssertEqual(HistorySessionDetail.share(5, max: 0), 0, "no basis for a share")
        XCTAssertEqual(HistorySessionDetail.share(nil, max: 10), 0)
        XCTAssertEqual(HistorySessionDetail.share(20, max: 10), 1, "clamped to 1")
    }
}
