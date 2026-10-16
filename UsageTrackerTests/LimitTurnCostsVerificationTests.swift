import XCTest
@testable import Omelette

/// Verification of the turn query behind the Limits tab (spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design "Turns" and § Packages 1,
/// `turnCosts(from:to:)` for Claude and Codex), from JSONL in the shapes real logs have:
/// - range edges are inclusive on both ends;
/// - a chat only its sub-agents ran in during the range is still that chat;
/// - a chat that straddles the range start brings only the turns inside it;
/// - turns past the 31-day horizon are not turns any more, but the day totals still hold them
///   (the "Earlier this month" source);
/// - a second `refresh()` never doubles a turn, and an appended final record replaces its
///   provisional one.
/// Dates are relative to the real clock, because the aggregators decide "recent" by `Date()`.
final class LimitTurnCostsVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private let chatA = "5b1c0a52-7a40-4d65-9a38-0e5c1b6f2d11"
    private let chatB = "c3d2e9a7-4b0f-4c1d-8e6a-91f5b7a0d822"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let betaSlug = "-Users-tester-Projects-beta"
    private let agentID = "a1b2c3d4e5f607182"

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LimitTurnCostsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            ),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    // MARK: - Claude fixtures

    private func claudeTurn(
        id: String, at date: Date, input: Int = 0, output: Int = 0, session: String, agent: Bool = false
    ) -> String {
        let sidechain = agent ? "true" : "false"
        let agentField = agent ? "\"agentId\":\"\(agentID)\",\"attributionAgent\":\"planner\"," : ""
        return """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":\(sidechain),\(agentField)\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":\(output),\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "service_tier":"standard"}},"requestId":"req_\(id)","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session)","version":"2.1.263","gitBranch":"main"}
        """
    }

    private func claudeTitle(_ title: String, session: String) -> String {
        "{\"type\":\"ai-title\",\"aiTitle\":\"\(title)\",\"sessionId\":\"\(session)\"}"
    }

    @discardableResult
    private func writeClaudeMain(_ lines: [String], session: String, project: String) throws -> URL {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeClaudeAgent(_ lines: [String], session: String, project: String) throws {
        let dir = root.appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    private func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private func claude() -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: nil, saveInterval: 0, calendar: utc)
    }

    // MARK: - Claude

    func testClaudeRangeEdgesAreInclusiveOnBothEnds() async throws {
        try writeClaudeMain([
            claudeTurn(id: "msg_1", at: minutesAgo(90), input: 1_000_000, session: chatA),
            claudeTurn(id: "msg_2", at: minutesAgo(60), input: 1_000_000, session: chatA),
            claudeTurn(id: "msg_3", at: minutesAgo(30), input: 1_000_000, session: chatA),
            claudeTurn(id: "msg_4", at: minutesAgo(10), input: 1_000_000, session: chatA),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: minutesAgo(60), to: minutesAgo(30))
        XCTAssertEqual(log.turns.map(\.timestamp), [minutesAgo(60), minutesAgo(30)])
    }

    func testClaudeAnInvertedRangeAnswersNothing() async throws {
        try writeClaudeMain([claudeTurn(id: "msg_1", at: minutesAgo(30), input: 1_000, session: chatA)], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(10), to: minutesAgo(50))
        XCTAssertEqual(log, .empty)
    }

    func testClaudeAChatOnlyItsSubAgentRanInDuringTheRangeIsStillThatChatAndIsNamed() async throws {
        try writeClaudeMain([
            claudeTurn(id: "msg_old", at: minutesAgo(600), input: 1_000, session: chatA),
            claudeTitle("Planner chat", session: chatA),
        ], session: chatA, project: alphaSlug)
        try writeClaudeAgent([
            claudeTurn(id: "msg_agent", at: minutesAgo(40), input: 1_000_000, session: chatA, agent: true),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: minutesAgo(120), to: now)
        XCTAssertEqual(log.turns.count, 1)
        XCTAssertEqual(log.turns.first?.chatID, chatA)
        XCTAssertEqual(log.turns.first?.isMainThread, false)
        XCTAssertEqual(log.turns.first?.projectSlug, alphaSlug)
        XCTAssertEqual(log.titles, [chatA: "Planner chat"])
    }

    func testClaudeAChatStraddlingTheRangeStartBringsOnlyItsTurnsInsideTheRange() async throws {
        try writeClaudeMain([
            claudeTurn(id: "msg_before", at: minutesAgo(100), input: 5_000_000, session: chatA),
            claudeTurn(id: "msg_inside", at: minutesAgo(40), input: 1_000_000, session: chatA),
            claudeTitle("Straddler", session: chatA),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(log.turns.map(\.timestamp), [minutesAgo(40)])
        XCTAssertEqual(log.turns.first?.cost ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(log.titles, [chatA: "Straddler"])
    }

    func testClaudeATurnPastTheThirtyOneDayHorizonIsNotATurnButStaysInTheDayTotals() async throws {
        try writeClaudeMain([
            claudeTurn(id: "msg_far", at: daysAgo(40), input: 1_000_000, session: chatA),
            claudeTurn(id: "msg_near", at: daysAgo(5), input: 1_000_000, session: chatA),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: daysAgo(60), to: now)
        XCTAssertEqual(log.turns.map(\.timestamp), [daysAgo(5)], "the 40-day-old turn is folded into its day")

        let days = await aggregator.breakdown().daily
        let farDay = utc.startOfDay(for: daysAgo(40))
        let window = LimitWindow(start: farDay.addingTimeInterval(-3_600), end: farDay.addingTimeInterval(86_400 + 3_600))
        XCTAssertEqual(
            LimitShareRules.localSpend(days: days, in: window), 3, accuracy: 1e-9,
            "the day totals still hold the folded turn's $3, which is what 'Earlier this month' reads"
        )
    }

    func testClaudeASecondRefreshNeverDoublesATurn() async throws {
        try writeClaudeMain([
            claudeTurn(id: "msg_1", at: minutesAgo(30), input: 1_000_000, session: chatA),
        ], session: chatA, project: alphaSlug)
        try writeClaudeAgent([
            claudeTurn(id: "msg_a", at: minutesAgo(20), input: 1_000_000, session: chatA, agent: true),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()
        let first = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        await aggregator.refresh()
        let second = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(first.turns.count, 2)
        XCTAssertEqual(second, first)
    }

    func testClaudeAFinalRecordAppendedLaterReplacesItsProvisionalOne() async throws {
        let url = try writeClaudeMain([
            claudeTurn(id: "msg_1", at: minutesAgo(30), output: 2, session: chatA),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()
        let provisional = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(provisional.turns.first?.tokens.output, 2)

        try append([claudeTurn(id: "msg_1", at: minutesAgo(30), output: 100_000, session: chatA)], to: url)
        await aggregator.refresh()
        let final = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(final.turns.count, 1)
        XCTAssertEqual(final.turns.first?.tokens.output, 100_000)
        XCTAssertEqual(final.turns.first?.cost ?? -1, 1.5, accuracy: 1e-9)
    }

    func testClaudeATurnAppendedAfterTheFirstRefreshIsPickedUp() async throws {
        let url = try writeClaudeMain([
            claudeTurn(id: "msg_1", at: minutesAgo(30), input: 1_000_000, session: chatA),
        ], session: chatA, project: alphaSlug)
        let aggregator = claude()
        await aggregator.refresh()
        try append([claudeTurn(id: "msg_2", at: minutesAgo(5), input: 1_000_000, session: chatA)], to: url)
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(log.turns.map(\.timestamp), [minutesAgo(30), minutesAgo(5)])
    }

    func testClaudeTwoChatsInTwoProjectsKeepTheirOwnProject() async throws {
        try writeClaudeMain([claudeTurn(id: "msg_a", at: minutesAgo(30), input: 1_000, session: chatA)], session: chatA, project: alphaSlug)
        try writeClaudeMain([claudeTurn(id: "msg_b", at: minutesAgo(20), input: 1_000, session: chatB)], session: chatB, project: betaSlug)
        let aggregator = claude()
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(log.turns.map(\.chatID), [chatA, chatB])
        XCTAssertEqual(log.turns.map(\.projectSlug), [alphaSlug, betaSlug])
    }

    // MARK: - Codex fixtures

    private let model = "gpt-5.6-terra"
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let parent = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agent = "01a073d5-72f2-7020-8904-65c6d733aca7"

    private func codexTree() throws -> CodexTree { try CodexTree(under: root) }

    private func codexParent(at times: [Date], named name: String? = nil) -> [String] {
        var lines = [
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: cwd, originator: "codex-tui", at: times[0].addingTimeInterval(-20)),
            CodexRollout.turnContext(turnID: "turn-p", model: model, effort: "high", cwd: cwd, at: times[0].addingTimeInterval(-10)),
        ]
        for (index, time) in times.enumerated() {
            lines.append(CodexRollout.record(
                at: time, threadID: parent, sessionID: parent, turnID: "turn-p", responseID: "resp_p\(index)",
                input: 1_000, cached: 0, output: 0, reasoning: 0
            ))
        }
        return lines
    }

    func testCodexRangeEdgesAreInclusiveOnBothEnds() async throws {
        let tree = try codexTree()
        try tree.writeRollout(
            codexParent(at: [minutesAgo(90), minutesAgo(60), minutesAgo(30), minutesAgo(10)]),
            named: "rollout-2026-09-06T10-00-00-\(parent).jsonl"
        )
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(60), to: minutesAgo(30))
        XCTAssertEqual(log.turns.map(\.timestamp), [minutesAgo(60), minutesAgo(30)])
        XCTAssertEqual(log.turns.map(\.chatID), [parent, parent])
    }

    func testCodexAChatStraddlingTheRangeStartBringsOnlyItsTurnsInsideTheRange() async throws {
        let tree = try codexTree()
        try tree.writeRollout(
            codexParent(at: [minutesAgo(100), minutesAgo(40)]),
            named: "rollout-2026-09-06T10-00-00-\(parent).jsonl"
        )
        try tree.writeIndex([CodexRollout.indexLine(id: parent, name: "Straddler", updatedAt: "2026-09-06T10:00:05.000Z")])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(log.turns.map(\.timestamp), [minutesAgo(40)])
        XCTAssertEqual(log.titles, [parent: "Straddler"])
    }

    func testCodexAChatOnlyItsSubAgentRanInDuringTheRangeIsStillThatChat() async throws {
        let tree = try codexTree()
        try tree.writeRollout(
            codexParent(at: [minutesAgo(600)]),
            day: "2026/09/05",
            named: "rollout-2026-09-05T10-00-00-\(parent).jsonl"
        )
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: parent, threadID: agent, parentThreadID: parent,
                                      nickname: "Bacon", agentPath: "/root/review", cwd: cwd, at: minutesAgo(50)),
            CodexRollout.turnContext(turnID: "turn-a", model: model, cwd: cwd, at: minutesAgo(49)),
            CodexRollout.record(at: minutesAgo(40), threadID: agent, sessionID: parent, turnID: "turn-a",
                                responseID: "resp_a", input: 2_000, cached: 0, output: 0, reasoning: 0),
        ], named: "rollout-2026-09-06T11-00-00-\(agent).jsonl")
        try tree.writeIndex([CodexRollout.indexLine(id: parent, name: "Parent chat", updatedAt: "2026-09-06T10:00:05.000Z")])
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()

        let log = await aggregator.turnCosts(from: minutesAgo(120), to: now)
        XCTAssertEqual(log.turns.count, 1)
        XCTAssertEqual(log.turns.first?.chatID, parent)
        XCTAssertEqual(log.turns.first?.isMainThread, false)
        XCTAssertEqual(log.titles, [parent: "Parent chat"])
    }

    func testCodexASecondRefreshNeverDoublesATurnAndAnAppendedResponseIsPickedUp() async throws {
        let tree = try codexTree()
        let url = try tree.writeRollout(
            codexParent(at: [minutesAgo(30)]),
            named: "rollout-2026-09-06T10-00-00-\(parent).jsonl"
        )
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        await aggregator.refresh()
        let first = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(first.turns.count, 1)

        try append([
            CodexRollout.record(at: minutesAgo(5), threadID: parent, sessionID: parent, turnID: "turn-p",
                                responseID: "resp_late", input: 1_000, cached: 0, output: 0, reasoning: 0),
        ], to: url)
        await aggregator.refresh()
        let second = await aggregator.turnCosts(from: minutesAgo(60), to: now)
        XCTAssertEqual(second.turns.map(\.timestamp), [minutesAgo(30), minutesAgo(5)])
    }

    func testCodexAnInvertedRangeAnswersNothing() async throws {
        let tree = try codexTree()
        try tree.writeRollout(codexParent(at: [minutesAgo(30)]), named: "rollout-2026-09-06T10-00-00-\(parent).jsonl")
        let aggregator = tree.aggregator(calendar: utc)
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(10), to: minutesAgo(50))
        XCTAssertEqual(log, .empty)
    }
}
