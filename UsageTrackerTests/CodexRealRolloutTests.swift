import XCTest
@testable import Omelette

/// Spec § 6. Four real rollout shapes in one tree: a record-then-count pair with its
/// compaction (09-06 17:25), a sub-agent rollout whose line 2 copies its parent's meta
/// (09-06 02:09), a counters-only 0.146.0 rollout, and a `session_index.jsonl` that
/// names one of them twice. Counters are copied from those files; cwds and ids are
/// scrubbed.
final class CodexRealRolloutTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// Four hours into the local day: the oldest fixture stamp is two hours back, and a
    /// suite that ran just after midnight would otherwise file it under yesterday.
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(4 * 3600))
    }()

    private let alphaCwd = "/tmp/Codex Fixtures/alpha app"
    private let betaCwd = "/tmp/Codex Fixtures/beta"
    private let model = "gpt-5.6-terra"

    private let compactionSession = "01a0771c-8238-75f0-bb53-0191ef8f612e"
    private let agentSession = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agentThread = "01a073d5-72f2-7020-8904-65c6d733aca7"
    private let countersSession = "01a061ac-98a5-7933-b626-c67610327f53"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRealRolloutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            )
        ])
        try writeTree()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private func writeTree() throws {
        // 1. The compaction pair. The top-level record for the compaction response is
        //    the bill; the `compacted` line that follows repeats it verbatim.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: compactionSession, cwd: alphaCwd,
                                     originator: "codex_exec", at: at(700)),
            CodexRollout.turnContext(turnID: "01a0771c-8295-71f2-bbc4-ad1782a795d9",
                                     model: model, effort: "xhigh", cwd: alphaCwd, at: at(690)),
            CodexRollout.record(at: at(600), threadID: compactionSession,
                                turnID: "01a0771c-8295-71f2-bbc4-ad1782a795d9",
                                responseID: "resp_0b178d37555a99c7016a9d77f28eb487d2a8907bcd7e8b79c3",
                                input: 18_064, cached: 12_160, output: 219, reasoning: 0),
            CodexRollout.tokenCount(at: at(590), input: 18_064, cached: 12_160,
                                    output: 219, reasoning: 0),
            CodexRollout.record(at: at(510), threadID: compactionSession,
                                turnID: "01a0771c-8295-71f2-bbc4-ad1782a795d9",
                                responseID: "resp_0b178d37555a99c7016a9d7ab63b7887d2b1f79e63e1157e6b",
                                input: 252_258, cached: 244_608, output: 7_987, reasoning: 0),
            CodexRollout.compacted(at: at(505), threadID: compactionSession,
                                   turnID: "01a0771c-8295-71f2-bbc4-ad1782a795d9",
                                   responseID: "resp_0b178d37555a99c7016a9d7ab63b7887d2b1f79e63e1157e6b",
                                   input: 252_258, cached: 244_608, output: 7_987, reasoning: 0),
            // The counter never grew for the compaction call.
            CodexRollout.tokenCount(at: at(500), input: 18_064, cached: 12_160,
                                    output: 219, reasoning: 0),
        ], named: "rollout-2026-09-06T17-25-52-\(compactionSession).jsonl")

        // 2. The parent of the sub-agent pair, with the prompt that names the chat.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: agentSession, cwd: alphaCwd,
                                     originator: "codex_exec", at: at(3_100)),
            CodexRollout.turnContext(turnID: "01a073d4-eba5-7031-b061-43262ae8cb3a",
                                     model: model, effort: "high", cwd: alphaCwd, at: at(3_090)),
            CodexRollout.userMessage(at: at(3_080), text: "# AGENTS.md instructions",
                                     kinds: ["agents_md.instructions",
                                             "environments.environment_context"]),
            CodexRollout.userMessage(at: at(3_070), text: "Проверь установщик",
                                     kinds: ["user.text"]),
            CodexRollout.record(at: at(3_000), threadID: agentSession,
                                turnID: "01a073d4-eba5-7031-b061-43262ae8cb3a",
                                responseID: "resp_parent",
                                input: 10_000, cached: 4_000, output: 500, reasoning: 100),
        ], named: "rollout-2026-09-06T02-08-48-\(agentSession).jsonl")

        // 3. The sub-agent. Line 2 copies the parent's meta; the first `turn_context`
        //    names the PARENT's root turn, so the record's own turn is matched by the
        //    second one.
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: agentSession, threadID: agentThread,
                                      parentThreadID: agentSession, nickname: "Bacon",
                                      agentPath: "/root/installer_review", cwd: alphaCwd,
                                      at: at(2_960)),
            CodexRollout.sessionMeta(sessionID: agentSession, cwd: alphaCwd,
                                     originator: "codex_exec", at: at(3_100)),
            CodexRollout.turnContext(turnID: "01a073d4-eba5-7031-b061-43262ae8cb3a",
                                     model: model, effort: "high", cwd: alphaCwd, at: at(2_950)),
            CodexRollout.turnContext(turnID: "01a073d5-731b-7943-93a8-0c86ab325a14",
                                     model: model, effort: "high", cwd: alphaCwd, at: at(2_940)),
            CodexRollout.userMessage(at: at(2_930), text: "Review the installer diff",
                                     kinds: ["user.text"]),
            CodexRollout.record(at: at(2_900), threadID: agentThread, sessionID: agentSession,
                                turnID: "01a073d5-731b-7943-93a8-0c86ab325a14",
                                responseID: "resp_07a32db798649765016a9ca12582c087d2906d70677f4405c2",
                                input: 19_442, cached: 11_904, output: 81, reasoning: 0),
        ], named: "rollout-2026-09-06T02-09-23-\(agentThread).jsonl")

        // 4. A 0.146.0 rollout: three cumulative readings and not one record.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: countersSession, cwd: betaCwd,
                                     originator: "codex_exec", cliVersion: "0.146.0",
                                     at: at(7_300)),
            CodexRollout.turnContext(turnID: "01a061ac-995e-7650-8ea5-346e62ed73d0",
                                     model: model, effort: "low", cwd: betaCwd, at: at(7_290)),
            CodexRollout.tokenCount(at: at(7_200), input: 19_391, cached: 6_912,
                                    output: 163, reasoning: 86),
            CodexRollout.tokenCount(at: at(7_100), input: 38_994, cached: 26_112,
                                    output: 226, reasoning: 103),
            CodexRollout.tokenCount(at: at(7_000), input: 60_835, cached: 45_312,
                                    output: 236, reasoning: 103),
        ], day: "2026/09/02", named: "rollout-2026-09-02T13-31-36-\(countersSession).jsonl")

        // 5. Two names for one id, three seconds apart.
        try tree.writeIndex([
            CodexRollout.indexLine(id: countersSession, name: "Привет! Сделай это) В ~/.codex/confi",
                                   updatedAt: "2026-09-06T09:13:00.682594Z"),
            CodexRollout.indexLine(id: countersSession, name: "Включить экспериментальный режим",
                                   updatedAt: "2026-09-06T09:13:03.739149Z"),
        ])
    }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        return aggregator
    }

    func testTheThreeChatsComeBackNewestFirstWithTheirOwnNames() async throws {
        let sessions = await loaded().sessions(from: at(3 * 24 * 3600), to: now)
        XCTAssertEqual(sessions.map(\.id), [compactionSession, agentSession, countersSession])
        XCTAssertEqual(sessions.map(\.title), [
            nil,
            "Проверь установщик",
            "Включить экспериментальный режим",
        ])
        XCTAssertEqual(sessions.map(\.origin), ["codex_exec", "codex_exec", "codex_exec"])
        XCTAssertEqual(sessions.map(\.providerID), ["codex", "codex", "codex"])
    }

    func testTheCompactionChatCountsTheCallTheCounterNeverSaw() async throws {
        let sessions = await loaded().sessions(from: at(3 * 24 * 3600), to: now)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.tokens.input, 13_554, "5_904 + 7_650")
        XCTAssertEqual(s.tokens.cacheRead, 256_768)
        XCTAssertEqual(s.tokens.output, 8_206)
        XCTAssertEqual(s.tokens.total, 278_528, "18_283 + 260_245")
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.1310985, accuracy: 1e-9)
        XCTAssertEqual(s.mainTokens, s.tokens)
        XCTAssertTrue(s.agents.isEmpty)
        XCTAssertEqual(s.projectSlug, "%2Ftmp%2FCodex%20Fixtures%2Falpha%20app")
    }

    func testTheSubAgentChatSplitsItsTokensBetweenTheMainThreadAndBacon() async throws {
        let sessions = await loaded().sessions(from: at(3 * 24 * 3600), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == agentSession })
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.mainTokens.total, 10_500)
        XCTAssertEqual(s.tokens.total, 30_023, "10_500 + 19_523")
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.0247205, accuracy: 1e-9)

        let agent = try XCTUnwrap(s.agents.first)
        XCTAssertEqual(s.agents.count, 1)
        XCTAssertEqual(agent.id, agentThread)
        XCTAssertEqual(agent.kind, "Bacon")
        XCTAssertEqual(agent.model, model)
        XCTAssertEqual(agent.effort, "high")
        XCTAssertEqual(agent.turns, 1)
        XCTAssertEqual(agent.tokens.total, 19_523)
        XCTAssertEqual(agent.tokens.input, 7_538)
        XCTAssertEqual(agent.tokens.cacheRead, 11_904)
    }

    func testTheCountersOnlyChatIsBilledFromItsDeltasExactlyAsBefore() async throws {
        let sessions = await loaded().sessions(from: at(3 * 24 * 3600), to: now)
        let s = try XCTUnwrap(sessions.first { $0.id == countersSession })
        XCTAssertEqual(s.turns, 3)
        XCTAssertEqual(s.tokens.input, 15_523)
        XCTAssertEqual(s.tokens.cacheRead, 45_312)
        XCTAssertEqual(s.tokens.output, 236)
        XCTAssertEqual(s.tokens.thinking, 103)
        XCTAssertEqual(s.tokens.total, 61_071, "and the file's last cumulative reading is 61_071")
        XCTAssertEqual(s.tokens.cost?.total ?? -1, 0.02742775, accuracy: 1e-9)
        XCTAssertEqual(s.projectSlug, "%2Ftmp%2FCodex%20Fixtures%2Fbeta")
    }

    func testTheDashboardTotalsAndTheSessionTotalsAreTheSameDollars() async throws {
        let aggregator = await loaded()
        let sessions = await aggregator.sessions(from: at(3 * 24 * 3600), to: now)
        let breakdown = await aggregator.breakdown()

        XCTAssertEqual(breakdown.todayTurns, 7)
        XCTAssertEqual(breakdown.todayTokens, 369_622)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.turns }, breakdown.todayTurns)
        XCTAssertEqual(
            sessions.reduce(0.0) { $0 + ($1.tokens.cost?.total ?? 0) },
            breakdown.todayCost,
            accuracy: 1e-9
        )
        XCTAssertEqual(breakdown.weekCost, 0.18324675, accuracy: 1e-9)
    }

    func testARelaunchRereadsTheRolloutsAndBillsEachResponseExactlyOnce() async throws {
        // § 3 asks for "cost cache version bumped". This aggregator has no cache to
        // version: it holds its parse state in memory only, so a relaunch re-reads the
        // tree under whatever rule the build carries and can never serve a figure
        // computed under an older one. The two instances below are that relaunch.
        let first = await loaded()
        let firstSessions = await first.sessions(from: at(3 * 24 * 3600), to: now)
        let firstBreakdown = await first.breakdown()

        let second = tree.aggregator()
        await second.refresh()
        let secondSessions = await second.sessions(from: at(3 * 24 * 3600), to: now)
        let secondBreakdown = await second.breakdown()

        XCTAssertEqual(firstSessions, secondSessions, "a relaunch reads the same chats")
        XCTAssertEqual(firstBreakdown.todayCost, secondBreakdown.todayCost, accuracy: 1e-12)
        XCTAssertEqual(firstBreakdown.todayTurns, secondBreakdown.todayTurns)

        // And a second poll on a live instance changes nothing: the dedupe is per file
        // and per response id, and the tail offset has not moved.
        await first.refresh()
        let repolled = await first.sessions(from: at(3 * 24 * 3600), to: now)
        XCTAssertEqual(repolled, firstSessions)
        let repolledBreakdown = await first.breakdown()
        XCTAssertEqual(repolledBreakdown.todayTurns, firstBreakdown.todayTurns)
    }
}
