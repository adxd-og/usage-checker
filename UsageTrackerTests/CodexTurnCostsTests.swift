import XCTest
@testable import Omelette

/// Limit analytics' turn query, the Codex half: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Turns, and
/// § Packages 1. The rollouts are `CodexRollout` lines, the shapes of this Mac's
/// rollouts:
/// - a parent thread;
/// - a sub-agent rollout whose `session_id` is the parent's and whose second line is
///   a copy of the parent's meta;
/// - a second chat Codex never named;
/// - a chat from a day ago.
///
/// `gpt-5.6` is priced at $1.25 input, $0.125 cached input and $10 output per million.
/// Dates are relative to the real clock, because the aggregator decides "recent" by
/// `Date()`.
final class CodexTurnCostsTests: XCTestCase {
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
    private let betaCWD = "/tmp/Codex Fixtures/beta"
    private let alphaSlug = "%2Ftmp%2FCodex%20Fixtures%2Falpha%20app"
    private let betaSlug = "%2Ftmp%2FCodex%20Fixtures%2Fbeta"
    private let parent = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"
    private let agent = "01a073d5-72f2-7020-8904-65c6d733aca7"
    private let other = "01a073d6-1b2c-7d3e-8f40-5a6b7c8d9e0f"
    private let old = "01a073d7-2c3d-7e4f-8a51-6b7c8d9e0f1a"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTurnCostsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
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

    private func at(_ secondsAgo: Double) -> Date { now.addingTimeInterval(-secondsAgo) }

    /// The parent's response an hour ago: 1,000 input, 400 of it cached, and 100 output.
    /// That is 600 × $1.25/M + 400 × $0.125/M + 100 × $10/M = $0.0018.
    ///
    /// Its sub-agent's response half an hour ago: 2,000 input, 1,000 cached, and 200
    /// output. That is $0.003375.
    ///
    /// The second chat's response 15 minutes ago: 1,000 fresh input, $0.00125. A chat
    /// from a day ago completes the set.
    private func writeRollouts() throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: alphaCWD,
                                     originator: "codex-tui", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-p", model: model, effort: "high",
                                     cwd: alphaCWD, at: at(3_690)),
            CodexRollout.userMessage(at: at(3_680), text: "Review the installer", kinds: ["user.text"]),
            CodexRollout.record(at: at(3_600), threadID: parent, sessionID: parent,
                                turnID: "turn-p", responseID: "resp_p",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-06T10-00-00-\(parent).jsonl")
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: parent, threadID: agent, parentThreadID: parent,
                                      nickname: "Bacon", agentPath: "/root/installer_review",
                                      cwd: alphaCWD, at: at(1_900)),
            CodexRollout.sessionMeta(sessionID: parent, threadID: parent, cwd: alphaCWD,
                                     originator: "codex-tui", at: at(3_700)),
            CodexRollout.turnContext(turnID: "turn-a", model: model, effort: "low",
                                     cwd: alphaCWD, at: at(1_890)),
            CodexRollout.record(at: at(1_800), threadID: agent, sessionID: parent,
                                turnID: "turn-a", responseID: "resp_a",
                                input: 2_000, cached: 1_000, output: 200, reasoning: 50),
        ], named: "rollout-2026-09-06T10-30-00-\(agent).jsonl")
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: other, threadID: other, cwd: betaCWD, at: at(1_000)),
            CodexRollout.turnContext(turnID: "turn-q", model: model, cwd: betaCWD, at: at(995)),
            CodexRollout.userMessage(at: at(990), text: "Bump the appcast", kinds: ["user.text"]),
            CodexRollout.record(at: at(900), threadID: other, sessionID: other,
                                turnID: "turn-q", responseID: "resp_q",
                                input: 1_000, cached: 0, output: 0, reasoning: 0),
        ], named: "rollout-2026-09-06T11-00-00-\(other).jsonl")
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: old, threadID: old, cwd: alphaCWD, at: at(90_000)),
            CodexRollout.turnContext(turnID: "turn-o", model: model, cwd: alphaCWD, at: at(89_990)),
            CodexRollout.record(at: at(86_400), threadID: old, sessionID: old,
                                turnID: "turn-o", responseID: "resp_o",
                                input: 5_000, cached: 0, output: 500, reasoning: 0),
        ], day: "2026/09/05", named: "rollout-2026-09-05T10-00-00-\(old).jsonl")
        try tree.writeIndex([
            CodexRollout.indexLine(id: parent, name: "Installer review", updatedAt: "2026-09-06T10:00:05.000Z"),
        ])
    }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        return aggregator
    }

    func testEveryResponseInTheRangeComesBackOldestFirstWithItsChatProjectAndPrice() async throws {
        try writeRollouts()
        let log = await loaded().turnCosts(from: at(7_200), to: now)

        XCTAssertEqual(
            log.turns.map(\.timestamp), [at(3_600), at(1_800), at(900)],
            "oldest first; the chat from a day ago is outside the range"
        )
        XCTAssertEqual(log.turns.map(\.chatID), [parent, parent, other])
        XCTAssertEqual(log.turns.map(\.projectSlug), [alphaSlug, alphaSlug, betaSlug])
        XCTAssertEqual(log.turns.map(\.model), [model, model, model])
        guard log.turns.count == 3 else { return XCTFail("expected 3 turns, got \(log.turns.count)") }
        XCTAssertEqual(log.turns[0].tokens.input, 600, "fresh input: input − cached − cache write")
        XCTAssertEqual(log.turns[0].tokens.cacheRead, 400)
        XCTAssertEqual(log.turns[0].cost, 0.0018, accuracy: 1e-12)
        XCTAssertEqual(log.turns[1].cost, 0.003375, accuracy: 1e-12)
        XCTAssertEqual(log.turns[2].cost, 0.00125, accuracy: 1e-12)
        XCTAssertEqual(log.turns[2].tokens.total, 1_000)
    }

    func testASubAgentsResponseBelongsToTheChatThatLaunchedIt() async throws {
        try writeRollouts()
        let log = await loaded().turnCosts(from: at(7_200), to: now)

        XCTAssertEqual(log.turns.map(\.isMainThread), [true, false, true])
        XCTAssertEqual(
            Set(log.turns.map(\.chatID)), [parent, other],
            "the agent's own thread id is never a chat of its own"
        )
    }

    func testEachChatInTheRangeIsNamedByTheIndexOrItsFirstPrompt() async throws {
        try writeRollouts()
        let log = await loaded().turnCosts(from: at(7_200), to: now)

        XCTAssertEqual(
            log.titles, [parent: "Installer review", other: "Bump the appcast"],
            "the index's thread name wins over the prompt; a chat outside the range is not named"
        )
    }

    func testTheQueryAnswersThroughTheCostLogProtocol() async throws {
        try writeRollouts()
        let aggregator = await loaded()
        let erased: any CostLogAggregating = aggregator

        let direct = await aggregator.turnCosts(from: at(7_200), to: now)
        let viaProtocol = await erased.turnCosts(from: at(7_200), to: now)

        XCTAssertEqual(viaProtocol, direct)
        XCTAssertEqual(viaProtocol.turns.count, 3)
    }
}
