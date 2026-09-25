import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "History · Session expanded" (`Dashboard-History-Chats`):
/// an open chat's cost bar by token type, By model and By day with a share bar per row,
/// and its sub-agents under a "Main thread" row. Figures from the mockup's chat.
final class HistorySessionDetailTests: XCTestCase {
    private let calendar = SessionFixture.calendar
    private let locale = SessionFixture.locale

    private func build(_ session: SessionSummary) -> HistorySessionDetail {
        HistorySessionDetail.build(
            session: session, allAgents: false, allDays: false, allModels: false,
            now: SessionFixture.now, calendar: calendar, locale: locale
        )
    }

    private func day(_ daysBefore: Int) -> String {
        ISO8601DateFormatter().string(from: SessionFixture.startOfDay(daysBefore: daysBefore))
    }

    func testTheMoneySplitNamesEachTypeWithItsTokensAndDollars() {
        let tokens = SessionFixture.tokens(
            input: 9_200, output: 436_800, cacheRead: 340_800_000, cacheWrite5m: 9_700_000,
            thinking: 157_200,
            cost: SessionFixture.cost(input: 0.07, output: 19.22, cacheRead: 72.11, cacheWrite: 66.47)
        )
        let split = HistoryMoneySplit.build(tokens)
        XCTAssertEqual(split.title, "Where the money went")
        XCTAssertEqual(split.total, "$157.87")
        XCTAssertEqual(split.segments.map(\.category), [.input, .output, .cacheRead, .cacheWrite])
        XCTAssertEqual(split.segments.map(\.tokens), ["9.2k", "436.8k", "340.8M", "9.7M"])
        XCTAssertEqual(split.segments.map(\.cost), ["$0.07", "$19.22", "$72.11", "$66.47"])
        XCTAssertEqual(split.thinking, "157.2k")
    }

    func testEachSegmentIsItsTypesShareOfTheDollars() {
        let split = HistoryMoneySplit.build(
            SessionFixture.tokens(input: 100, output: 100, cost: SessionFixture.cost(input: 1, output: 3))
        )
        XCTAssertEqual(split.segments.map(\.share), [0.25, 0.75])
    }

    func testAnUnpricedChatShowsItsTokensAndNoBar() {
        let split = HistoryMoneySplit.build(SessionFixture.tokens(input: 1_000, output: 200))
        XCTAssertEqual(split.title, "Tokens by type")
        XCTAssertNil(split.total)
        XCTAssertEqual(split.segments.map(\.cost), [nil, nil])
        XCTAssertEqual(split.segments.map(\.share), [0, 0])
        XCTAssertNil(split.thinking)
    }

    func testTheBarGivesEveryTypeItsMinimumAndFillsTheWidthLessTheGaps() {
        let widths = HistoryMoneySplit.widths(
            shares: [0.0004, 0.1217, 0.4568, 0.4210], in: 600, minimum: 3, gap: 2
        )
        XCTAssertEqual(widths.count, 4)
        XCTAssertEqual(widths.reduce(0, +), 594, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 >= 3 })
        XCTAssertGreaterThan(widths[2], widths[3])
    }

    func testATooNarrowBarNeverGoesNegative() {
        let widths = HistoryMoneySplit.widths(shares: [0.5, 0.5], in: 4, minimum: 3, gap: 2)
        XCTAssertEqual(widths.reduce(0, +), 2, accuracy: 1e-9)
        XCTAssertTrue(widths.allSatisfy { $0 >= 0 })
    }

    func testModelRowsCarryTheirShareOfTheMostExpensiveModel() {
        let detail = build(SessionFixture.session(id: "a", models: [
            SessionFixture.model(model: "claude-opus-4-5", effort: "xhigh",
                                 tokens: SessionFixture.tokens(input: 1, cost: SessionFixture.cost(input: 4))),
            SessionFixture.model(model: "claude-sonnet-4-5", effort: "high",
                                 tokens: SessionFixture.tokens(input: 1, cost: SessionFixture.cost(input: 1))),
        ]))
        XCTAssertEqual(detail.modelRows.map(\.id), ["claude-opus-4-5|xhigh", "claude-sonnet-4-5|high"])
        XCTAssertEqual(detail.modelShares["claude-opus-4-5|xhigh"], 1)
        XCTAssertEqual(detail.modelShares["claude-sonnet-4-5|high"], 0.25)
    }

    func testDayRowsCarryTheirShareAndTodayIsMarked() {
        let detail = build(SessionFixture.session(id: "a", days: [
            SessionFixture.day(daysBefore: 2, tokens: SessionFixture.tokens(input: 1, cost: SessionFixture.cost(input: 1))),
            SessionFixture.day(daysBefore: 0, tokens: SessionFixture.tokens(input: 1, cost: SessionFixture.cost(input: 4))),
        ]))
        XCTAssertEqual(detail.dayRows.map(\.id), [day(2), day(0)])
        XCTAssertEqual(detail.dayShares[day(0)], 1)
        XCTAssertEqual(detail.dayShares[day(2)], 0.25)
        XCTAssertEqual(detail.todayDayID, day(0))
    }

    func testAChatThatDidNotRunTodayMarksNoDay() {
        let detail = build(SessionFixture.session(id: "a", days: [
            SessionFixture.day(daysBefore: 3), SessionFixture.day(daysBefore: 2),
        ]))
        XCTAssertNil(detail.todayDayID)
    }

    func testTheTablesAreTheRowsSessionDetailDraws() {
        let session = SessionFixture.session(
            id: "a",
            agents: (1...10).map { SessionFixture.agent(id: "x\($0)") },
            days: (0..<16).map { SessionFixture.day(daysBefore: $0) },
            models: [SessionFixture.model(effort: "xhigh"), SessionFixture.model(model: "claude-sonnet-4-5")]
        )
        let base = SessionDetail.build(
            session: session, allAgents: false, allDays: false, allModels: false,
            calendar: calendar, locale: locale
        )
        let detail = build(session)
        XCTAssertEqual(detail.modelRows, base.modelRows)
        XCTAssertEqual(detail.dayRows, base.dayRows)
        XCTAssertEqual(detail.agentRows.map(\.id), base.agentRows.map(\.id))
        XCTAssertEqual(detail.hiddenAgents, base.hiddenAgents)
        XCTAssertEqual(detail.hiddenDays, base.hiddenDays)
        XCTAssertEqual(detail.totalAgents, 10)
    }

    func testTheMainThreadRowLeavesModelAndEffortBlank() {
        let detail = build(SessionFixture.session(
            id: "a", turns: 30, agents: [SessionFixture.agent(id: "x1", kind: "planner", turns: 10)]
        ))
        XCTAssertEqual(detail.agentRows.map(\.name), ["Main thread", "planner"])
        XCTAssertEqual(detail.agentRows[0].model, "")
        XCTAssertEqual(detail.agentRows[0].effort, "")
        XCTAssertEqual(detail.agentRows[0].turns, "20")
        XCTAssertTrue(detail.agentRows[0].isMain)
        XCTAssertEqual(detail.agentRows[1].effort, "xhigh")
        XCTAssertFalse(detail.agentRows[1].isMain)
    }

    func testAShareOfNothingIsZeroAndNeverPastFull() {
        XCTAssertEqual(HistorySessionDetail.share(5, max: 0), 0)
        XCTAssertEqual(HistorySessionDetail.share(nil, max: 10), 0)
        XCTAssertEqual(HistorySessionDetail.share(12, max: 10), 1)
        XCTAssertEqual(HistorySessionDetail.share(5, max: 10), 0.5)
    }
}
