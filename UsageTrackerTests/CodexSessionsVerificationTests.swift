import XCTest
@testable import Omelette

/// Independent verification of `CodexUsageAggregator` (package P2) against
/// docs/superpowers/specs/2026-09-10-sessions-history-design.md § Facts (Codex), § 1
/// (the `SessionSummary` contract and clipping rules) and § 3 (the Codex aggregator).
///
/// Every fixture line below is built from scratch with `JSONSerialization` rather than
/// through `CodexRolloutFixtures.swift` (the executor's helper), so a bug hiding behind
/// that helper's own assumptions cannot hide behind mine too. Shapes are taken from this
/// Mac's own `~/.codex/sessions` rollouts and `~/.codex/session_index.jsonl`
/// (2026-09-10), ids and paths scrubbed.
final class CodexSessionsVerificationTests: XCTestCase {
    private var root: URL!
    /// UTC so a day boundary means the same thing wherever the suite runs.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date!

    private let cwd = "/tmp/Codex Verify/app"
    private let model = "gpt-5.6-terra"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let real = Date()
        // Anchored an hour into the day and truncated to a whole second, the same way
        // as the existing suite, so a fixture timestamp survives the ISO8601 round trip.
        now = Date(timeIntervalSince1970:
            max(real, calendar.startOfDay(for: real).addingTimeInterval(3600))
                .timeIntervalSince1970.rounded(.down))
        ModelPricing.updateDynamic([
            "gpt-5.6-terra": ModelPrice(inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                                        cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5),
            "model-a": ModelPrice(inputPerM: 1, outputPerM: 1, cacheReadPerM: 1,
                                  cacheCreate5mPerM: 1, cacheCreate1hPerM: 1),
            "model-b": ModelPrice(inputPerM: 2, outputPerM: 2, cacheReadPerM: 2,
                                  cacheCreate5mPerM: 2, cacheCreate1hPerM: 2),
            "gpt-5.6-quad": ModelPrice(inputPerM: 4, outputPerM: 20, cacheReadPerM: 0.4,
                                       cacheCreate5mPerM: 5, cacheCreate1hPerM: 8),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Tree layout (independent of CodexRolloutFixtures.swift)

    private var codexHome: URL { root.appendingPathComponent("codex-home", isDirectory: true) }
    private var sessionsDir: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }
    private var archivedDir: URL { codexHome.appendingPathComponent("archived_sessions", isDirectory: true) }
    private var indexFile: URL { codexHome.appendingPathComponent("session_index.jsonl") }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private func aggregator() -> CodexUsageAggregator {
        CodexUsageAggregator(rootURL: sessionsDir, calendar: calendar)
    }

    private func loaded() async -> CodexUsageAggregator {
        let a = aggregator()
        await a.refresh()
        return a
    }

    @discardableResult
    private func rollout(_ lines: [String], day: String = "2026/09/06", named name: String) throws -> URL {
        let dir = sessionsDir.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeIndex(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: indexFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Fixture line builders (own implementation, own JSON shapes)

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func stamp(_ date: Date) -> String { Self.iso.string(from: date) }

    private func jsonLine(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return String(data: data, encoding: .utf8)!
    }

    private func metaLine(
        sessionID: String, threadID: String? = nil, cwd: String,
        originator: String = "codex_exec", at date: Date
    ) -> String {
        jsonLine([
            "type": "session_meta", "timestamp": stamp(date),
            "payload": [
                "session_id": sessionID, "id": threadID ?? sessionID,
                "timestamp": stamp(date), "cwd": cwd, "originator": originator,
                "cli_version": "0.153.4", "source": "exec", "thread_source": "user",
                "model_provider": "openai",
                "parent_thread_id": NSNull(), "agent_nickname": NSNull(), "agent_path": NSNull(),
            ],
        ])
    }

    private func subagentMetaLine(
        sessionID: String, threadID: String, parentThreadID: String,
        nickname: String?, path: String?, cwd: String,
        originator: String = "codex_exec", at date: Date
    ) -> String {
        let nicknameValue: Any = nickname ?? NSNull()
        let pathValue: Any = path ?? NSNull()
        let threadSpawn: [String: Any] = [
            "parent_thread_id": parentThreadID, "depth": 1,
            "agent_path": pathValue, "agent_nickname": nicknameValue,
            "agent_role": NSNull(),
        ]
        let source: [String: Any] = ["subagent": ["thread_spawn": threadSpawn]]
        let payload: [String: Any] = [
            "session_id": sessionID, "id": threadID, "timestamp": stamp(date),
            "cwd": cwd, "originator": originator, "cli_version": "0.153.4",
            "source": source,
            "thread_source": "subagent",
            "parent_thread_id": parentThreadID,
            "agent_nickname": nicknameValue, "agent_path": pathValue,
            "model_provider": "openai",
        ]
        return jsonLine(["type": "session_meta", "timestamp": stamp(date), "payload": payload])
    }

    private func turnContextLine(
        turnID: String, model: String?, effort: String? = nil, cwd: String? = nil, at date: Date
    ) -> String {
        var payload: [String: Any] = ["turn_id": turnID, "root_turn_id": turnID]
        if let model { payload["model"] = model }
        if let effort { payload["effort"] = effort }
        if let cwd { payload["cwd"] = cwd }
        return jsonLine(["type": "turn_context", "timestamp": stamp(date), "payload": payload])
    }

    private func recordPayload(
        threadID: String, sessionID: String, turnID: String, responseID: String,
        input: Int, cached: Int = 0, cacheWrite: Int = 0, output: Int, reasoning: Int = 0
    ) -> [String: Any] {
        let usage: [String: Any] = [
            "input_tokens": input, "cached_input_tokens": cached,
            "cache_write_input_tokens": cacheWrite, "output_tokens": output,
            "reasoning_output_tokens": reasoning, "total_tokens": input + output,
        ]
        return [
            "thread_id": threadID, "session_id": sessionID, "turn_id": turnID,
            "response_id": responseID, "usage": usage, "thread_token_usage": usage,
        ]
    }

    private func recordLine(
        threadID: String, sessionID: String, turnID: String, responseID: String,
        input: Int, cached: Int = 0, cacheWrite: Int = 0, output: Int, reasoning: Int = 0, at date: Date
    ) -> String {
        jsonLine([
            "type": "token_usage_record", "timestamp": stamp(date),
            "payload": recordPayload(
                threadID: threadID, sessionID: sessionID, turnID: turnID, responseID: responseID,
                input: input, cached: cached, cacheWrite: cacheWrite, output: output, reasoning: reasoning
            ),
        ])
    }

    private func compactedLine(nested: [String: Any], at date: Date) -> String {
        jsonLine([
            "type": "compacted", "timestamp": stamp(date),
            "payload": ["message": "", "latest_token_usage_record": nested],
        ])
    }

    private func tokenCountLine(
        input: Int, cached: Int = 0, cacheWrite: Int = 0, output: Int, reasoning: Int = 0, at date: Date
    ) -> String {
        jsonLine([
            "type": "event_msg", "timestamp": stamp(date),
            "payload": [
                "type": "token_count",
                "info": ["total_token_usage": [
                    "input_tokens": input, "cached_input_tokens": cached,
                    "cache_write_input_tokens": cacheWrite, "output_tokens": output,
                    "reasoning_output_tokens": reasoning, "total_tokens": input + output,
                ]],
            ],
        ])
    }

    private func tokenCountNullInfoLine(at date: Date) -> String {
        jsonLine([
            "type": "event_msg", "timestamp": stamp(date),
            "payload": ["type": "token_count", "info": NSNull()],
        ])
    }

    private func userPromptLine(text: String, kinds: [String]?, at date: Date) -> String {
        var payload: [String: Any] = ["role": "user", "content": [["type": "input_text", "text": text]]]
        if let kinds { payload["internal_chat_message_metadata_passthrough"] = ["content_item_kinds": kinds] }
        return jsonLine(["type": "response_item", "timestamp": stamp(date), "payload": payload])
    }

    private func indexLine(id: String, name: String, updatedAt: Date) -> String {
        jsonLine(["id": id, "thread_name": name, "updated_at": stamp(updatedAt)])
    }

    private func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }

    // MARK: - § 3 billing rule: record-then-count

    /// § 3: "bill `usage` as one turn attributed to the model/effort of the
    /// `turn_context`... On `token_count`: always update the stored cumulative
    /// counters..., bill the delta only when `!sawRecord`."
    func testARecordThenARestatingTokenCountBillsTheResponseOnce() async throws {
        let session = "verify-record-then-count"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, effort: "high", cwd: cwd, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "resp1",
                       input: 1_000, cached: 200, output: 300, reasoning: 50, at: at(3_580)),
            tokenCountLine(input: 1_000, cached: 200, output: 300, reasoning: 50, at: at(3_579)),
        ], named: "rollout-record-then-count.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1, "the record bills once; the restating token_count adds nothing")
        XCTAssertEqual(s.tokens.total, 1_300)
        XCTAssertEqual(s.tokens.cacheRead, 200)
        XCTAssertEqual(s.tokens.thinking, 50)
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.004025, accuracy: 1e-9)
    }

    /// § 3 worth-testing list: "a duplicated `token_usage_record` (same thread_id +
    /// response_id re-emitted) billed once."
    func testADuplicatedTokenUsageRecordIsBilledOnce() async throws {
        let session = "verify-duplicated-record"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "respA",
                       input: 500, output: 100, at: at(3_580)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "respA",
                       input: 500, output: 100, at: at(3_575)),
        ], named: "rollout-duplicated-record.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1, "the same (thread_id, response_id) must not bill twice")
        XCTAssertEqual(s.tokens.total, 600)
    }

    /// § 3: "bill `usage` as one turn attributed to the model/effort of the
    /// `turn_context` with the same `turn_id` (fallback: the latest `turn_context`)."
    /// Distinguishes exact turn_id matching from simply using the file's current model.
    func testARecordUsesTheContextItsTurnIdNamesEvenAfterANewerContextArrives() async throws {
        let session = "verify-context-lookup"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "tA", model: "model-a", effort: "low", at: at(3_590)),
            turnContextLine(turnID: "tB", model: "model-b", effort: "high", at: at(3_580)),
            // Named turn_id "tA": must use model-a's context although "tB" (model-b) is
            // now the latest context and state.currentModel.
            recordLine(threadID: session, sessionID: session, turnID: "tA", responseID: "respA",
                       input: 400, output: 50, at: at(3_570)),
            // Unknown turn_id "tZ": falls back to the latest context, model-b.
            recordLine(threadID: session, sessionID: session, turnID: "tZ", responseID: "respZ",
                       input: 1_000, output: 200, at: at(3_560)),
        ], named: "rollout-context-lookup.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 2)
        // model-a (rate 1) on 450 tokens = 0.00045; model-b (rate 2) on 1_200 = 0.0024.
        // If both were priced at the (wrong) latest context alone the total would be
        // 0.0033; if both used the (wrong) exact-match-only path the second would be
        // unattributed. Only the spec's rule produces 0.00285.
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.00285, accuracy: 1e-9)
    }

    // MARK: - § 3: compaction never double counts

    /// § Facts / § 3: "A `compacted` record embeds a copy under
    /// `payload.latest_token_usage_record` — never count the nested one."
    func testTheNestedLatestTokenUsageRecordInsideCompactedIsNeverBilled() async throws {
        let session = "verify-compaction"
        let ghost = recordPayload(
            threadID: session, sessionID: session, turnID: "t1", responseID: "respGhost",
            input: 99_999, cached: 0, output: 99_999
        )
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "respReal",
                       input: 1_000, output: 100, at: at(3_580)),
            // The nested copy names a DIFFERENT response_id that never appears as its
            // own top-level record — the strongest form of "never read": even a bug
            // that peeked inside `compacted` would show up here.
            compactedLine(nested: ghost, at: at(3_570)),
        ], named: "rollout-compaction.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1, "only the real top-level record is a turn")
        XCTAssertEqual(s.tokens.total, 1_100, "the ghost usage inside `compacted` must not be added")
    }

    // MARK: - § Facts: token_count with info: null

    /// § Facts / § 3: "A `token_count` with `info: null` is skipped."
    func testATokenCountWithNullInfoIsSkippedAndDoesNotDisturbTheNextDelta() async throws {
        let session = "verify-null-info"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            tokenCountLine(input: 1_000, output: 200, at: at(3_580)),
            tokenCountNullInfoLine(at: at(3_575)),
            tokenCountLine(input: 1_500, output: 250, at: at(3_570)),
        ], named: "rollout-null-info.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 2, "the null-info line must not itself become a turn")
        XCTAssertEqual(s.tokens.total, 1_750, "1_200 (first delta) + 550 (second delta from the SAME baseline)")
    }

    // MARK: - § Facts: negative delta, counters-only vs records file

    /// § Facts: "`token_count` is cumulative and... resets after long pauses / model
    /// switches... the existing 'negative delta = take the reading' rule covers it."
    func testANegativeDeltaInACountersOnlyFileTakesTheWholeReadingAsANewTurn() async throws {
        let session = "verify-negative-delta-counters"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            tokenCountLine(input: 2_000, output: 300, at: at(3_580)),
            // Reset: a much smaller cumulative reading than before.
            tokenCountLine(input: 500, output: 80, at: at(3_570)),
        ], named: "rollout-negative-delta-counters.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 2, "a reset still produces a second turn, not zero")
        XCTAssertEqual(s.tokens.total, 2_300 + 580, "the second turn is the reading itself, not a clamped-to-zero diff")
    }

    /// § 3 worth-testing list: "a negative delta... in a counters-only file (reading
    /// taken)" versus a records file, where § 3 says `token_count` "always update[s]
    /// the stored cumulative counters... bill the delta only when `!sawRecord`" — so a
    /// records file must never bill from `token_count` regardless of the delta's sign.
    func testANegativeDeltaAfterARecordHasBeenSeenNeverBillsFromTheCounter() async throws {
        let session = "verify-negative-delta-records"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "resp1",
                       input: 1_000, output: 100, at: at(3_580)),
            tokenCountLine(input: 2_000, output: 300, at: at(3_575)),
            // Would be a large negative delta against the reading just above.
            tokenCountLine(input: 500, output: 50, at: at(3_570)),
        ], named: "rollout-negative-delta-records.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1, "once a record has billed the file, no token_count may bill, whatever its sign")
        XCTAssertEqual(s.tokens.total, 1_100)
    }

    // MARK: - § 3 worth-testing list: mid-file switch from counters to records

    func testAFileThatSwitchesFromCountersToRecordsBillsEachResponseExactlyOnce() async throws {
        let session = "verify-mid-file-switch"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            tokenCountLine(input: 1_000, output: 100, at: at(3_580)),
            tokenCountLine(input: 1_800, output: 180, at: at(3_570)),
            // The CLI switches to writing records. This response's usage is independent
            // of the cumulative counters above.
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "respSwitch",
                       input: 500, output: 50, at: at(3_560)),
            // Numerically coincides with what the naive delta would have been, so a bug
            // that kept billing from token_count after the switch would not be caught
            // by a numeric-total check alone unless we also assert the turn count.
            tokenCountLine(input: 2_300, output: 230, at: at(3_550)),
        ], named: "rollout-mid-file-switch.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 3, "two counter deltas, then exactly one record — never a fourth turn")
        XCTAssertEqual(s.tokens.total, 1_100 + 880 + 550)
    }

    // MARK: - § Facts / § 3: sub-agent identity

    /// § Facts: "`session_id` equal to the parent's... its own id is `id`."
    /// § 3: "`agentKind = agent_nickname ?? agent_path`" (both missing → "sub-agent",
    /// per the plan's ambiguity #3) and "the session's `projectSlug` is the parent's."
    func testSubAgentIdentityAndTheAgentKindFallbackChain() async throws {
        let session = "verify-subagents"
        let mainCwd = "/tmp/Codex Verify/main-app"
        let agentCwd = "/tmp/Codex Verify/agent-app"

        try rollout([
            metaLine(sessionID: session, cwd: mainCwd, originator: "codex_exec", at: at(3_600)),
            turnContextLine(turnID: "tm", model: model, effort: "high", cwd: mainCwd, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "tm", responseID: "respMain",
                       input: 300, output: 60, at: at(3_580)),
        ], named: "rollout-main.jsonl")

        try rollout([
            subagentMetaLine(sessionID: session, threadID: "agentA-thread", parentThreadID: session,
                              nickname: "Bacon", path: "/root/x", cwd: agentCwd, at: at(3_550)),
            turnContextLine(turnID: "ta", model: model, effort: "low", cwd: agentCwd, at: at(3_540)),
            recordLine(threadID: "agentA-thread", sessionID: session, turnID: "ta", responseID: "respA",
                       input: 100, output: 20, at: at(3_530)),
        ], named: "rollout-agent-a.jsonl")

        try rollout([
            subagentMetaLine(sessionID: session, threadID: "agentB-thread", parentThreadID: session,
                              nickname: nil, path: "/root/y", cwd: agentCwd, at: at(3_520)),
            turnContextLine(turnID: "tb", model: model, cwd: agentCwd, at: at(3_510)),
            recordLine(threadID: "agentB-thread", sessionID: session, turnID: "tb", responseID: "respB",
                       input: 150, output: 30, at: at(3_500)),
        ], named: "rollout-agent-b.jsonl")

        try rollout([
            subagentMetaLine(sessionID: session, threadID: "agentC-thread", parentThreadID: session,
                              nickname: nil, path: nil, cwd: agentCwd, at: at(3_490)),
            turnContextLine(turnID: "tc", model: model, cwd: agentCwd, at: at(3_480)),
            recordLine(threadID: "agentC-thread", sessionID: session, turnID: "tc", responseID: "respC",
                       input: 80, output: 10, at: at(3_470)),
        ], named: "rollout-agent-c.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })

        XCTAssertEqual(s.projectSlug, encoded(mainCwd), "the session's project is the main thread's, not an agent's")
        XCTAssertEqual(s.origin, "codex_exec")
        XCTAssertEqual(s.mainTokens.total, 360)
        XCTAssertEqual(s.agents.count, 3)
        XCTAssertEqual(s.tokens.total, 360 + 120 + 180 + 90)

        let agentA = try XCTUnwrap(s.agents.first { $0.id == "agentA-thread" })
        XCTAssertEqual(agentA.kind, "Bacon")
        XCTAssertEqual(agentA.tokens.total, 120)

        let agentB = try XCTUnwrap(s.agents.first { $0.id == "agentB-thread" })
        XCTAssertEqual(agentB.kind, "/root/y", "nickname missing falls back to agent_path")
        XCTAssertEqual(agentB.tokens.total, 180)

        let agentC = try XCTUnwrap(s.agents.first { $0.id == "agentC-thread" })
        XCTAssertEqual(agentC.kind, "sub-agent", "both nickname and path missing")
        XCTAssertEqual(agentC.tokens.total, 90)
    }

    /// § Facts: "Only the FIRST `session_meta` in a file is the file's identity: a
    /// sub-agent file's second line is a copy of the parent's meta."
    func testASubAgentRolloutsSecondLineCopiedParentMetaIsIgnored() async throws {
        let agentSession = "verify-subagent-own-session"
        let parentSession = "verify-subagent-parent-session"
        let agentCwd = "/tmp/Codex Verify/agent-only"
        let parentCwd = "/tmp/Codex Verify/parent-only"

        try rollout([
            subagentMetaLine(sessionID: agentSession, threadID: "agentX-thread", parentThreadID: parentSession,
                              nickname: "Nick", path: "/p", cwd: agentCwd, at: at(3_600)),
            // A verbatim copy of the parent's own session_meta, as line 2.
            metaLine(sessionID: parentSession, threadID: parentSession, cwd: parentCwd, at: at(3_599)),
            turnContextLine(turnID: "t1", model: model, cwd: agentCwd, at: at(3_590)),
            recordLine(threadID: "agentX-thread", sessionID: parentSession, turnID: "t1", responseID: "r1",
                       input: 50, output: 10, at: at(3_580)),
        ], named: "rollout-copied-meta.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        XCTAssertFalse(sessions.contains { $0.id == parentSession },
                        "the copied line-2 meta must never create a second identity")
        let s = try XCTUnwrap(sessions.first { $0.id == agentSession })
        XCTAssertEqual(s.projectSlug, encoded(agentCwd), "line 1's cwd, not line 2's")
        XCTAssertEqual(s.agents.first?.id, "agentX-thread", "the agent id is line 1's `id`, not line 2's `session_id`")
    }

    // MARK: - § Facts: names

    /// § Facts: "several [lines] per id, take the latest `updated_at`."
    func testTwoIndexLinesForOneIdTakeTheLatestUpdatedAt() async throws {
        let session = "verify-name-latest-wins"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 10, output: 5, at: at(3_580)),
        ], named: "rollout-name.jsonl")
        // Written out of chronological order to prove the code compares timestamps
        // rather than trusting line order.
        try writeIndex([
            indexLine(id: session, name: "New name", updatedAt: at(100)),
            indexLine(id: session, name: "Old name", updatedAt: at(200)),
        ])

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.title, "New name")
    }

    /// § Facts: "Fallback: the first `response_item` user message whose
    /// `internal_chat_message_metadata_passthrough.content_item_kinds` contains
    /// `user.text`; if none, the first user `input_text` that does not start with `<`
    /// or `#`... the earlier user-role records are AGENTS.md and environment."
    func testANamelessSessionFallsBackToTheFirstUserTextPromptNotAnAgentsStyleRecord() async throws {
        let session = "verify-first-prompt"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            userPromptLine(text: "<system-reminder>environment content</system-reminder>",
                           kinds: nil, at: at(3_595)),
            userPromptLine(text: "# AGENTS.md\nProject conventions.", kinds: nil, at: at(3_590)),
            userPromptLine(text: "Please refactor the pricing module", kinds: ["user.text"], at: at(3_585)),
            turnContextLine(turnID: "t1", model: model, at: at(3_580)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 10, output: 5, at: at(3_575)),
        ], named: "rollout-first-prompt.jsonl")
        // No session_index.jsonl at all — the fallback must still work.

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.title, "Please refactor the pricing module")
    }

    // MARK: - § 1: clipping at local-day granularity, and the 5h widening

    /// § 1: "each summary clipped to the range at day granularity"; "A range shorter
    /// than a day (5h) is widened to the local day it falls in." Exercised as the pure
    /// rule directly, so day boundaries are exact and independent of file parsing.
    func testASessionSpanningTwoLocalDaysClipsAndAFiveHourRangeWidensToTheDay() throws {
        let day1 = calendar.startOfDay(for: now)
        let day2 = calendar.date(byAdding: .day, value: 1, to: day1)!
        let tokensDay1 = TokenBreakdown(input: 1_000, output: 100)
        let tokensDay2 = TokenBreakdown(input: 2_000, output: 300)

        var agg = CodexUsageAggregator.SessionAgg(
            projectSlug: "proj", origin: "codex_exec",
            firstAt: day1.addingTimeInterval(3_600), lastAt: day2.addingTimeInterval(7_200)
        )
        agg.turns = 7
        agg.tokens = tokensDay1 + tokensDay2
        agg.mainTokens = agg.tokens
        agg.byDay = [
            day1: CodexUsageAggregator.DaySlice(turns: 3, tokens: tokensDay1, mainTokens: tokensDay1),
            day2: CodexUsageAggregator.DaySlice(turns: 4, tokens: tokensDay2, mainTokens: tokensDay2),
        ]
        agg.agents = ["agentDay2": CodexUsageAggregator.AgentAgg(
            kind: "Bacon", model: model, effort: "high",
            firstAt: day2.addingTimeInterval(3_600), lastAt: day2.addingTimeInterval(5_400),
            turns: 2, tokens: TokenBreakdown(input: 50, output: 5)
        )]

        // Range fully inside day 1: day 2 (and its agent) must not appear.
        let onlyDay1 = try XCTUnwrap(CodexUsageAggregator.summary(
            sessionID: "S", agg: agg, title: nil,
            from: day1.addingTimeInterval(1_800), to: day1.addingTimeInterval(36_000),
            calendar: calendar
        ))
        XCTAssertEqual(onlyDay1.days.map(\.day), [day1])
        XCTAssertEqual(onlyDay1.turns, 3)
        XCTAssertEqual(onlyDay1.tokens, tokensDay1)
        XCTAssertTrue(onlyDay1.agents.isEmpty, "the day-2-only agent must not leak into a day-1 clip")
        XCTAssertEqual(onlyDay1.firstAt, agg.firstAt, "firstAt/lastAt stay the chat's own span, unclipped")
        XCTAssertEqual(onlyDay1.lastAt, agg.lastAt)

        // A 5h window late in day 1 still returns the whole local day.
        let widened = try XCTUnwrap(CodexUsageAggregator.summary(
            sessionID: "S", agg: agg, title: nil,
            from: day1.addingTimeInterval(3_600 * 19), to: day1.addingTimeInterval(3_600 * 24 - 1),
            calendar: calendar
        ))
        XCTAssertEqual(widened.days.map(\.day), [day1], "a 5h range widens to the whole local day it falls in")
        XCTAssertEqual(widened.turns, 3)

        // Range covering both days: both slices, re-summed, and the day-2 agent included.
        let bothDays = try XCTUnwrap(CodexUsageAggregator.summary(
            sessionID: "S", agg: agg, title: nil,
            from: day1, to: day2.addingTimeInterval(3_600),
            calendar: calendar
        ))
        XCTAssertEqual(bothDays.days.map(\.day), [day1, day2])
        XCTAssertEqual(bothDays.turns, 7)
        XCTAssertEqual(bothDays.tokens, tokensDay1 + tokensDay2)
        XCTAssertEqual(bothDays.agents.map(\.id), ["agentDay2"])

        // A range entirely before the chat: no summary at all.
        XCTAssertNil(CodexUsageAggregator.summary(
            sessionID: "S", agg: agg, title: nil,
            from: day1.addingTimeInterval(-10 * 86_400), to: day1.addingTimeInterval(-9 * 86_400),
            calendar: calendar
        ))
    }

    // MARK: - § 3: 92-day retention

    /// § 3 / § 2 (adopted): "a session whose `lastAt` is older than 92 days is dropped
    /// at fold time." `pruneAndFold` measures against the real wall clock, not the
    /// injected `calendar`, so the offsets below are anchored to `now` (itself within
    /// about an hour of `Date()`), with a full day of margin on each side of the
    /// boundary to absorb that skew.
    func testASessionOlderThanNinetyTwoDaysIsPrunedAtFoldTime() async throws {
        let kept = "verify-retention-kept"
        let dropped = "verify-retention-dropped"
        try rollout([
            metaLine(sessionID: kept, cwd: cwd, at: at(91 * 86_400)),
            turnContextLine(turnID: "t1", model: model, at: at(91 * 86_400 - 5)),
            recordLine(threadID: kept, sessionID: kept, turnID: "t1", responseID: "r1",
                       input: 100, output: 10, at: at(91 * 86_400 - 10)),
        ], named: "rollout-kept.jsonl")
        try rollout([
            metaLine(sessionID: dropped, cwd: cwd, at: at(93 * 86_400)),
            turnContextLine(turnID: "t1", model: model, at: at(93 * 86_400 - 5)),
            recordLine(threadID: dropped, sessionID: dropped, turnID: "t1", responseID: "r1",
                       input: 100, output: 10, at: at(93 * 86_400 - 10)),
        ], named: "rollout-dropped.jsonl")

        let sessions = await loaded().sessions(from: at(200 * 86_400), to: now)
        XCTAssertTrue(sessions.contains { $0.id == kept }, "91 days old is still inside the 92-day window")
        XCTAssertFalse(sessions.contains { $0.id == dropped }, "93 days old must be pruned at fold time")
    }

    // MARK: - § 3: archived_sessions, keyed by thread id

    /// § 3: "Scan `~/.codex/archived_sessions/` too, and never recount a file that
    /// moved there (key files by `threadID`, not path)."
    func testARolloutMovedIntoArchivedSessionsIsNotCountedTwiceAndKeepsTailingAfterTheMove() async throws {
        let session = "verify-archived-move"
        let uuid = "01a075fd-c1dd-7b11-90d5-ad4bff47b670"
        let name = "rollout-2026-09-06T10-00-00-\(uuid).jsonl"
        let url = try rollout([
            metaLine(sessionID: session, threadID: uuid, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, at: at(3_590)),
            recordLine(threadID: uuid, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 100, output: 20, at: at(3_580)),
        ], named: name)

        let aggregator = self.aggregator()
        await aggregator.refresh()
        var sessions = await aggregator.sessions(from: at(4_000), to: now)
        var s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1)
        XCTAssertEqual(s.tokens.total, 120)

        // "Move" the rollout: create it under archived_sessions/ with the same name,
        // delete the sessions/ copy.
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        let archivedURL = archivedDir.appendingPathComponent(name)
        let contents = try String(contentsOf: url, encoding: .utf8)
        try contents.write(to: archivedURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)

        await aggregator.refresh()
        sessions = await aggregator.sessions(from: at(4_000), to: now)
        s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 1, "the moved file must not be counted a second time")
        XCTAssertEqual(s.tokens.total, 120)

        // Append a new response after the move: incremental tailing must still work,
        // keyed by thread id rather than the (now different) path.
        let appended = contents + recordLine(
            threadID: uuid, sessionID: session, turnID: "t1", responseID: "r2",
            input: 50, output: 5, at: at(10)
        ) + "\n"
        try appended.write(to: archivedURL, atomically: true, encoding: .utf8)

        await aggregator.refresh()
        sessions = await aggregator.sessions(from: at(4_000), to: now)
        s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.turns, 2, "the appended response after the move must still be picked up")
        XCTAssertEqual(s.tokens.total, 120 + 55)
    }

    // MARK: - Relaunch equivalence

    /// A fresh aggregator over the same tree must answer `sessions(from:to:)`
    /// identically — the "no cache to go stale" guarantee § 3 substitutes for a
    /// cost-cache version bump.
    func testAFreshAggregatorOverTheSameTreeProducesIdenticalSessions() async throws {
        let session = "verify-relaunch"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: model, effort: "high", at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 700, cached: 100, output: 90, reasoning: 20, at: at(3_580)),
        ], named: "rollout-relaunch.jsonl")

        let first = await loaded().sessions(from: at(4_000), to: now)
        let second = await loaded().sessions(from: at(4_000), to: now)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
    }

    // MARK: - § Facts: usage → TokenBreakdown mapping

    /// § Facts: "`cache_write_input_tokens` billed 1.25× input on GPT-5.6+... `output`
    /// already includes [`reasoning_output_tokens`], the total does not double count."
    func testCacheWriteBillingAndReasoningNeverDoubleCountsTheTotal() async throws {
        let session = "verify-cache-write"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: "gpt-5.6-quad", at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 10_000, cached: 3_000, cacheWrite: 1_000, output: 2_000, reasoning: 500,
                       at: at(3_580)),
        ], named: "rollout-cache-write.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.tokens.input, 6_000, "10_000 − 3_000 cached − 1_000 cache write")
        XCTAssertEqual(s.tokens.cacheRead, 3_000)
        XCTAssertEqual(s.tokens.cacheWrite, 1_000)
        XCTAssertEqual(s.tokens.output, 2_000)
        XCTAssertEqual(s.tokens.thinking, 500)
        XCTAssertEqual(s.tokens.total, 12_000, "not 12_500 — thinking is a subset of output, not additive")
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.0702, accuracy: 1e-9)
    }

    // MARK: - Mixed priced / unpriced model (documented behaviour, not a P2 spec failure)

    /// § 1: "`TokenBreakdown` already carries per-category dollars... so 'cost of this
    /// chat' is `tokens.cost?.total`." The spec does not say what happens when a chat
    /// mixes a priced and an unpriced model; this records the inherited `TokenBreakdown`
    /// `+` behaviour (shared code, not part of this diff): the combined cost is nil,
    /// even though one of the two turns was priced. Tokens are still counted.
    func testAMixedPricedAndUnpricedModelChatsCombinedCostIsUnknown() async throws {
        let session = "verify-mixed-pricing"
        try rollout([
            metaLine(sessionID: session, cwd: cwd, at: at(3_600)),
            turnContextLine(turnID: "t1", model: "gpt-5.6-quad", at: at(3_590)),
            recordLine(threadID: session, sessionID: session, turnID: "t1", responseID: "r1",
                       input: 1_000, output: 100, at: at(3_580)),
            turnContextLine(turnID: "t2", model: "totally-unknown-zzz", at: at(3_570)),
            recordLine(threadID: session, sessionID: session, turnID: "t2", responseID: "r2",
                       input: 500, output: 50, at: at(3_560)),
        ], named: "rollout-mixed-pricing.jsonl")

        let sessions = await loaded().sessions(from: at(4_000), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == session })
        XCTAssertEqual(s.tokens.total, 1_650, "tokens are counted regardless of pricing")
        XCTAssertNil(s.tokens.cost, "documented: mixing a priced and an unpriced turn yields an unknown combined cost")
    }
}
