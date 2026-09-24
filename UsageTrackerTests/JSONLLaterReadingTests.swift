import XCTest
@testable import Omelette

/// The rule that decides which of a message id's records a turn keeps, as the pure
/// function both paths share: a recent turn revised in place, and an old turn held
/// back until its transcript is read. Spec
/// `docs/superpowers/specs/2026-09-24-2.6.5-review-fixes.md` § Design #10 ("same
/// rule as `replaceIfLater`").
final class JSONLLaterReadingTests: XCTestCase {
    private let sonnet = "claude-sonnet-4-5"
    private let firstLineAt = Date(timeIntervalSince1970: 1_786_000_000)

    /// A sub-agent reply's first line as Claude Code 2.1.280 logs it: the provisional
    /// output of 7, no thinking figure yet.
    private func provisionalRecord() -> CLITurn {
        CLITurn(
            id: "msg_01TestReplyA000000000000",
            timestamp: firstLineAt,
            model: sonnet,
            tokens: TokenBreakdown(input: 2, output: 7, cacheWrite5m: 16_805).priced(model: sonnet),
            projectSlug: "-Users-tester-Projects-alpha",
            sessionID: "d5dff4f0-3038-4ed6-81d6-ddccee879027",
            agentID: "a0f3c9e1b7d24a615",
            agentKind: "planner",
            effort: "xhigh"
        )
    }

    /// The same reply's final line, 1.4 s later: 208 output, 43 of them thinking. Every
    /// field but the counters is deliberately different, so the test can tell which
    /// record each field of the result came from.
    private func finalRecord() -> CLITurn {
        CLITurn(
            id: "msg_01TestReplyA000000000000",
            timestamp: firstLineAt.addingTimeInterval(1.424),
            model: "claude-opus-4-5",
            tokens: TokenBreakdown(input: 2, output: 208, cacheWrite5m: 16_805, thinking: 43)
                .priced(model: sonnet),
            projectSlug: "-Users-tester-Projects-beta",
            sessionID: "90a2e89b-86f7-438b-bbb1-d0b5735809e3",
            agentID: nil,
            agentKind: nil,
            effort: "low"
        )
    }

    func testALaterReadingTakesTheBiggerRecordsCountersAndNothingElse() throws {
        let stored = provisionalRecord()
        let record = finalRecord()

        let revised = try XCTUnwrap(JSONLAggregator.laterReading(record, over: stored))

        XCTAssertEqual(revised.tokens, record.tokens, "the counters, dollars included, are the bigger record's")
        XCTAssertEqual(revised.id, stored.id)
        XCTAssertEqual(revised.timestamp, stored.timestamp, "the time is the first line's")
        XCTAssertEqual(revised.model, stored.model)
        XCTAssertEqual(revised.projectSlug, stored.projectSlug)
        XCTAssertEqual(revised.sessionID, stored.sessionID)
        XCTAssertEqual(revised.agentID, stored.agentID)
        XCTAssertEqual(revised.agentKind, stored.agentKind)
        XCTAssertEqual(revised.effort, stored.effort)
    }

    func testAnEqualOrSmallerOutputIsNotALaterReading() {
        let stored = finalRecord()
        XCTAssertNil(
            JSONLAggregator.laterReading(provisionalRecord(), over: stored),
            "a provisional line replayed after the final one must not shrink the turn"
        )

        let sameOutput = CLITurn(
            id: stored.id,
            timestamp: stored.timestamp,
            model: stored.model,
            tokens: TokenBreakdown(input: 999_999, output: 208).priced(model: sonnet),
            projectSlug: stored.projectSlug
        )
        XCTAssertNil(
            JSONLAggregator.laterReading(sameOutput, over: stored),
            "equal output keeps what is stored, whatever else the record says"
        )
    }
}
