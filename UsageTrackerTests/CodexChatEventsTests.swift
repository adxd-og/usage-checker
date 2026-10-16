import XCTest
@testable import Omelette

/// Codex's chat events for the Limits tab's stretches: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5, and § Packages 3.
/// The rollouts are `CodexRollout` lines, the shapes of this Mac's rollouts:
/// - `compacted` on the chat's own thread. On 2026-09-06 the first response after one read
///   69 % of its input from cache, so a compaction there is no cold start;
/// - typed prompts (`user.text`), and the AGENTS.md and environment preambles that arrive
///   under the user role and are not typed;
/// - a sub-agent rollout, whose brief and compactions are the agent's, not the chat's.
///
/// Dates are relative to the real clock: the aggregator keeps what is younger than its
/// 31-day turn horizon by `Date()`.
final class CodexChatEventsTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    /// Whole seconds, so a timestamp survives the fixture's format/parse round trip.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let model = "gpt-5.6-terra"
    private let alphaCWD = "/tmp/Codex Fixtures/alpha app"
    private let parent = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agent = "01a073d5-72f2-7020-8904-65c6d733aca7"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexChatEventsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private var parentName: String { "rollout-2026-09-06T10-00-00-\(parent).jsonl" }

    /// The chat's own thread: the preambles, a typed prompt and a response, a compaction,
    /// a second prompt and a response.
    private var parentLines: [String] {
        [
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: alphaCWD,
                                     originator: "codex-tui", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-p", model: model, effort: "high", cwd: alphaCWD, at: at(3_690)),
            CodexRollout.userMessage(at: at(3_685), text: "# AGENTS.md instructions for /tmp/Codex Fixtures/alpha app",
                                     kinds: nil),
            CodexRollout.userMessage(at: at(3_684), text: "<environment_context>\n  <cwd>/tmp</cwd>\n</environment_context>",
                                     kinds: nil),
            CodexRollout.userMessage(at: at(3_680), text: "Review the installer", kinds: ["user.text"]),
            CodexRollout.record(at: at(3_600), threadID: parent, sessionID: parent, turnID: "turn-p",
                                responseID: "resp_p1", input: 1_000, cached: 400, output: 100, reasoning: 0),
            CodexRollout.compacted(at: at(2_000), threadID: parent, responseID: "resp_c",
                                   input: 252_258, cached: 244_608, output: 900, reasoning: 0),
            CodexRollout.userMessage(at: at(1_900), text: "Now bump the appcast", kinds: ["user.text"]),
            CodexRollout.record(at: at(1_800), threadID: parent, sessionID: parent, turnID: "turn-p",
                                responseID: "resp_p2", input: 26_068, cached: 17_920, output: 200, reasoning: 0),
        ]
    }

    private func turnLog() async -> TurnCostLog {
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        return await aggregator.turnCosts(from: at(7_200), to: now)
    }

    func testACompactionOnTheChatsOwnThreadIsKept() async throws {
        try tree.writeRollout(parentLines, named: parentName)
        let log = await turnLog()
        XCTAssertEqual(log.turns.count, 2, "the compaction's copy of a usage record is never billed")
        XCTAssertEqual(log.compactions, [parent: [at(2_000)]])
    }

    func testEveryPromptTheUserTypedIsKeptInOrderAndThePreamblesAreNot() async throws {
        try tree.writeRollout(parentLines, named: parentName)
        let log = await turnLog()
        XCTAssertEqual(log.prompts[parent], [
            ChatPrompt(at: at(3_680), text: "Review the installer"),
            ChatPrompt(at: at(1_900), text: "Now bump the appcast"),
        ])
        XCTAssertEqual(log.titles[parent], "Review the installer", "the first prompt still names the chat")
    }

    func testASubAgentsBriefAndCompactionAreNotItsChats() async throws {
        try tree.writeRollout(parentLines, named: parentName)
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: parent, threadID: agent, parentThreadID: parent,
                                      nickname: "Bacon", agentPath: "/root/installer_review",
                                      cwd: alphaCWD, at: at(1_500)),
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: alphaCWD,
                                     originator: "codex-tui", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-a", model: model, effort: "low", cwd: alphaCWD, at: at(1_490)),
            CodexRollout.userMessage(at: at(1_480), text: "Check the installer's paths", kinds: ["user.text"]),
            CodexRollout.record(at: at(1_400), threadID: agent, sessionID: parent, turnID: "turn-a",
                                responseID: "resp_a", input: 2_000, cached: 1_000, output: 200, reasoning: 0),
            CodexRollout.compacted(at: at(1_300), threadID: agent, responseID: "resp_ac",
                                   input: 90_000, cached: 80_000, output: 300, reasoning: 0),
        ], named: "rollout-2026-09-06T10-30-00-\(agent).jsonl")
        let log = await turnLog()
        XCTAssertEqual(log.turns.count, 3)
        XCTAssertEqual(log.compactions, [parent: [at(2_000)]], "the agent's own compaction is not the chat's")
        XCTAssertEqual(log.prompts[parent]?.map(\.text), ["Review the installer", "Now bump the appcast"])
    }

    func testARolloutReadAgainKeepsEachEventOnce() async throws {
        let url = try tree.writeRollout(parentLines, named: parentName)
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        // Rewritten shorter: the aggregator reads it again from the top.
        try (parentLines.dropLast().joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: at(7_200), to: now)
        XCTAssertEqual(log.compactions, [parent: [at(2_000)]])
        XCTAssertEqual(log.prompts[parent]?.count, 2)
    }
}
