import XCTest
@testable import Omelette

/// Spec § 3 and § Facts: a chat's name is Codex's own `thread_name` when it has one,
/// and the first thing the user actually typed when it does not. The index fixture is
/// the shape of this Mac's `~/.codex/session_index.jsonl`, including the two-names-for
/// -one-id case Codex writes when it renames a thread three seconds after opening it.
final class CodexSessionNamesTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let sessionID = "01a066cb-03db-7df0-b2da-077f9731adfd"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionNamesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        ModelPricing.updateDynamic([
            "gpt-5.6": ModelPrice(
                inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125,
                cacheCreate5mPerM: 1.5625, cacheCreate1hPerM: 2.5
            )
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator()
        await aggregator.refresh()
        return aggregator
    }

    private func sessions(_ aggregator: CodexUsageAggregator) async -> [SessionSummary] {
        await aggregator.sessions(from: at(2 * 24 * 3600), to: now)
    }

    /// A chat with one response and, optionally, some user-role records before it.
    private func writeChat(id: String = "01a066cb-03db-7df0-b2da-077f9731adfd",
                           prompts: [String] = []) throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: id, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
        ] + prompts + [
            CodexRollout.record(at: at(600), threadID: id, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-03T13-23-00-\(id).jsonl")
    }

    // MARK: - The index

    func testTheLatestUpdatedAtWinsWhenAnIDIsNamedTwice() {
        let data = Data((
            CodexRollout.indexLine(id: "a", name: "Привет!",
                                   updatedAt: "2026-09-03T10:23:19.280344Z") + "\n" +
            CodexRollout.indexLine(id: "a", name: "Ответить на приветствие",
                                   updatedAt: "2026-09-03T10:23:22.428869Z") + "\n" +
            CodexRollout.indexLine(id: "b", name: "Weekly market recap",
                                   updatedAt: "2026-08-06T11:30:23.87649Z") + "\n"
        ).utf8)

        let names = CodexUsageAggregator.parseIndex(data)
        XCTAssertEqual(names["a"], "Ответить на приветствие")
        XCTAssertEqual(names["b"], "Weekly market recap", "five fractional digits parse too")
        XCTAssertNil(names["c"])
    }

    func testAnOlderLineAfterANewerOneDoesNotWin() {
        let data = Data((
            CodexRollout.indexLine(id: "a", name: "New", updatedAt: "2026-09-03T10:23:22.428869Z") + "\n" +
            CodexRollout.indexLine(id: "a", name: "Old", updatedAt: "2026-09-03T10:23:19.280344Z") + "\n"
        ).utf8)
        XCTAssertEqual(CodexUsageAggregator.parseIndex(data)["a"], "New")
    }

    func testAnUnreadableOrEmptyIndexNamesNothing() {
        XCTAssertTrue(CodexUsageAggregator.parseIndex(nil).isEmpty)
        XCTAssertTrue(CodexUsageAggregator.parseIndex(Data()).isEmpty)
        XCTAssertTrue(CodexUsageAggregator.parseIndex(Data("not json\n".utf8)).isEmpty)
    }

    func testTheIndexNamesTheChat() async throws {
        try writeChat()
        try tree.writeIndex([
            CodexRollout.indexLine(id: sessionID, name: "Привет!",
                                   updatedAt: "2026-09-03T10:23:19.280344Z"),
            CodexRollout.indexLine(id: sessionID, name: "Ответить на приветствие",
                                   updatedAt: "2026-09-03T10:23:22.428869Z"),
        ])

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.title, "Ответить на приветствие")
    }

    func testTheIndexIsNotRereadWhileItsSizeAndMtimeAreUnchanged() async throws {
        try writeChat()
        // A whole-second timestamp, stamped on both writes rather than read back and
        // restored: the file system keeps an mtime to the nanosecond, and a `Date` that
        // has been through it once does not necessarily land on the same nanosecond
        // when it is written back — which the gate, comparing exactly, would read as a
        // change.
        let pinned = Date(timeIntervalSince1970: 1_788_700_000)
        try tree.writeIndex([
            CodexRollout.indexLine(id: sessionID, name: "Alpha",
                                   updatedAt: "2026-09-03T10:23:19.280344Z"),
        ])
        try FileManager.default.setAttributes([.modificationDate: pinned],
                                              ofItemAtPath: tree.index.path)
        let aggregator = await loaded()
        var found = await sessions(aggregator)
        XCTAssertEqual(found.first?.title, "Alpha")

        // Same byte length, same timestamp: nothing the gate can see has moved.
        try tree.writeIndex([
            CodexRollout.indexLine(id: sessionID, name: "Bravo",
                                   updatedAt: "2026-09-03T10:23:19.280344Z"),
        ])
        try FileManager.default.setAttributes([.modificationDate: pinned],
                                              ofItemAtPath: tree.index.path)
        await aggregator.refresh()
        found = await sessions(aggregator)
        XCTAssertEqual(found.first?.title, "Alpha", "not re-read")

        // Touch it and the new name arrives.
        try FileManager.default.setAttributes([.modificationDate: pinned.addingTimeInterval(60)],
                                              ofItemAtPath: tree.index.path)
        await aggregator.refresh()
        found = await sessions(aggregator)
        XCTAssertEqual(found.first?.title, "Bravo")
    }

    // MARK: - The first-prompt fallback

    func testAChatMissingFromTheIndexIsNamedByItsFirstUserMessage() async throws {
        // `codex exec` sessions are never in the index.
        try writeChat(prompts: [
            CodexRollout.userMessage(at: at(880), text: "# AGENTS.md instructions\n<INSTRUCTIONS>",
                                     kinds: ["agents_md.instructions", "environments.environment_context"]),
            CodexRollout.userMessage(at: at(870), text: "Привет! Сделай это)", kinds: ["user.text"]),
            CodexRollout.userMessage(at: at(860), text: "Это для всего теперь?", kinds: ["user.text"]),
        ])

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.title, "Привет! Сделай это)", "the FIRST user.text, not the last")
    }

    func testTheIndexBeatsTheFirstPrompt() async throws {
        try writeChat(prompts: [
            CodexRollout.userMessage(at: at(870), text: "Привет! Сделай это)", kinds: ["user.text"]),
        ])
        try tree.writeIndex([
            CodexRollout.indexLine(id: sessionID, name: "Включить экспериментальный режим",
                                   updatedAt: "2026-09-06T09:13:03.739149Z"),
        ])

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.title, "Включить экспериментальный режим")
    }

    func testAUserRecordWithNoKindsIsSkippedWhenItOpensWithAngleBracketOrHash() async throws {
        try writeChat(prompts: [
            CodexRollout.userMessage(at: at(884), text: "<environment_context>cwd</environment_context>",
                                     kinds: nil),
            CodexRollout.userMessage(at: at(882), text: "# AGENTS.md instructions", kinds: nil),
            CodexRollout.userMessage(at: at(880), text: "Fix the installer", kinds: nil),
        ])

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertEqual(s.title, "Fix the installer")
    }

    func testAChatWithNothingToNameItKeepsANilTitle() async throws {
        try writeChat()

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertNil(s.title, "the UI falls back to project + date")
    }

    func testASubAgentsTaskPromptNeverNamesTheChat() async throws {
        // A sub-agent's own log opens with the task it was handed. That is not what the
        // user typed, and the parent's name — or nothing — is the honest answer.
        let agentThread = "01a066c9-44b9-72a1-9320-46f72a29c716"
        try writeChat()
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: sessionID, threadID: agentThread,
                                      parentThreadID: sessionID, nickname: "Bacon",
                                      agentPath: "/root/installer_review", cwd: cwd, at: at(800)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(790)),
            CodexRollout.userMessage(at: at(780), text: "Review the installer diff",
                                     kinds: ["user.text"]),
            CodexRollout.record(at: at(700), threadID: agentThread, sessionID: sessionID,
                                responseID: "resp_b",
                                input: 500, cached: 0, output: 50, reasoning: 0),
        ], named: "rollout-2026-09-03T13-24-00-\(agentThread).jsonl")

        let found = await sessions(loaded())
        let s = try XCTUnwrap(found.first)
        XCTAssertNil(s.title)
        XCTAssertEqual(s.agents.count, 1)
    }

    func testAPromptIsWhitespaceCollapsedAndCutAtEightyCharacters() {
        XCTAssertEqual(
            CodexUsageAggregator.promptTitle("  Fix\n\tthe   installer  "),
            "Fix the installer"
        )
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(
            CodexUsageAggregator.promptTitle(long),
            String(repeating: "a", count: 80) + "…"
        )
        XCTAssertNil(CodexUsageAggregator.promptTitle("   \n  "))
    }
}
