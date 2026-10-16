import XCTest
@testable import Omelette

/// Codex's chat events and cold starts, from rollout lines to the Limits tab's stretches:
/// spec `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5. Codex
/// keeps `compacted` lines (never billed) and every typed prompt inside the 31-day horizon;
/// a Codex cold start is a turn with cache reads under 5 % of an input of at least 10,000
/// tokens. Codex's `input_tokens` already include the cached and cache-written tokens.
///
/// Dates are relative to the real clock: the aggregator keeps what is younger than its
/// horizon by `Date()`.
final class CodexChatEventsVerificationTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private let model = "gpt-5.6-terra"
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let chat = "01a073d4-eb4a-7250-a222-e48c7b5bd8df"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexChatEventsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func head(_ minutes: Double) -> [String] {
        [
            CodexRollout.sessionMeta(sessionID: chat, threadID: chat, cwd: cwd, originator: "codex-tui", at: minutesAgo(minutes)),
            CodexRollout.turnContext(turnID: "turn-1", model: model, effort: "high", cwd: cwd, at: minutesAgo(minutes - 0.1)),
        ]
    }

    private func response(
        _ minutes: Double, id: String, input: Int, cached: Int, cacheWrite: Int = 0, output: Int = 200
    ) -> String {
        CodexRollout.record(
            at: minutesAgo(minutes), threadID: chat, sessionID: chat, turnID: "turn-1", responseID: id,
            input: input, cached: cached, cacheWrite: cacheWrite, output: output, reasoning: 0
        )
    }

    private func turnLog() async -> TurnCostLog {
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        return await aggregator.turnCosts(from: now.addingTimeInterval(-32 * 86_400), to: now)
    }

    // MARK: - Cold starts, from the rollout's counters

    func testACodexTurnIsAColdStartAtTenThousandTokensAndUnderFivePercentRead() async throws {
        // `input_tokens` hold the cached tokens: 20,000 with 1,000 cached is 5 % read.
        let cases: [(input: Int, cached: Int, cacheWrite: Int, cold: Bool, why: String)] = [
            (10_000, 0, 0, true, "exactly 10,000, nothing read"),
            (9_999, 0, 0, false, "one token under 10,000"),
            (20_000, 1_000, 0, false, "exactly 5 % read is not under 5 %"),
            (20_000, 999, 0, true, "just under 5 % read"),
            (20_000, 0, 20_000, true, "a prompt written to cache is read from none"),
            (30_000, 29_000, 0, false, "97 % read"),
        ]
        var lines = head(100)
        for (index, item) in cases.enumerated() {
            lines.append(response(90 - Double(index) * 10, id: "resp_\(index)", input: item.input, cached: item.cached,
                                  cacheWrite: item.cacheWrite))
        }
        try tree.writeRollout(lines, named: "rollout-2026-09-06T10-00-00-\(chat).jsonl")
        let log = await turnLog()
        XCTAssertEqual(log.turns.count, cases.count)
        for (index, item) in cases.enumerated() {
            let turn = log.turns[index]
            XCTAssertEqual(
                LimitShareRules.isColdStart(turn, serviceID: "codex"), item.cold,
                "\(item.why): input \(item.input), cached \(item.cached), written \(item.cacheWrite)"
            )
        }
    }

    // MARK: - Compactions and prompts

    func testEventsOlderThanTheHorizonAreNotKept() async throws {
        let old = minutesAgo(40 * 24 * 60)
        let inside = minutesAgo(30 * 24 * 60)
        let lines = head(100) + [
            CodexRollout.userMessage(at: old, text: "An old prompt", kinds: ["user.text"]),
            CodexRollout.compacted(at: old.addingTimeInterval(60), threadID: chat, responseID: "resp_old",
                                   input: 90_000, cached: 80_000, output: 300, reasoning: 0),
            CodexRollout.userMessage(at: inside, text: "A prompt still inside", kinds: ["user.text"]),
            CodexRollout.compacted(at: inside.addingTimeInterval(60), threadID: chat, responseID: "resp_in",
                                   input: 90_000, cached: 80_000, output: 300, reasoning: 0),
            response(90, id: "resp_1", input: 12_000, cached: 0),
        ]
        try tree.writeRollout(lines, named: "rollout-2026-09-06T10-00-00-\(chat).jsonl")
        let log = await turnLog()
        XCTAssertEqual(log.compactions[chat], [inside.addingTimeInterval(60)])
        XCTAssertEqual(log.prompts[chat], [ChatPrompt(at: inside, text: "A prompt still inside")])
        XCTAssertEqual(log.turns.count, 1, "a compaction's copy of a usage record is never billed")
    }

    func testACompactedLineBillsNothingAndPromptsFromTwoChatsStaySeparate() async throws {
        let other = "01a073d9-1111-7250-a222-e48c7b5bd8df"
        try tree.writeRollout(head(100) + [
            CodexRollout.userMessage(at: minutesAgo(99), text: "Review the installer", kinds: ["user.text"]),
            response(95, id: "resp_a", input: 12_000, cached: 0),
            CodexRollout.compacted(at: minutesAgo(60), threadID: chat, responseID: "resp_c",
                                   input: 252_258, cached: 244_608, output: 900, reasoning: 0),
        ], named: "rollout-2026-09-06T10-00-00-\(chat).jsonl")
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: other, threadID: other, cwd: cwd, originator: "codex-tui", at: minutesAgo(80)),
            CodexRollout.turnContext(turnID: "turn-2", model: model, effort: "high", cwd: cwd, at: minutesAgo(79.9)),
            CodexRollout.userMessage(at: minutesAgo(79), text: "Bump the appcast", kinds: ["user.text"]),
            CodexRollout.record(at: minutesAgo(70), threadID: other, sessionID: other, turnID: "turn-2",
                                responseID: "resp_b", input: 5_000, cached: 0, output: 100, reasoning: 0),
        ], named: "rollout-2026-09-06T11-00-00-\(other).jsonl")
        let log = await turnLog()
        XCTAssertEqual(log.turns.count, 2)
        XCTAssertEqual(log.compactions, [chat: [minutesAgo(60)]])
        XCTAssertEqual(log.prompts[chat]?.map(\.text), ["Review the installer"])
        XCTAssertEqual(log.prompts[other]?.map(\.text), ["Bump the appcast"])
    }

    // MARK: - From a rollout to stretches

    func testARolloutBecomesStretchesAtItsCompactionNamedByTheirPrompts() async throws {
        try tree.writeRollout(head(200) + [
            CodexRollout.userMessage(at: minutesAgo(199), text: "Review the installer", kinds: ["user.text"]),
            response(190, id: "resp_1", input: 15_000, cached: 0),
            response(150, id: "resp_2", input: 30_000, cached: 29_000),
            CodexRollout.compacted(at: minutesAgo(100), threadID: chat, responseID: "resp_c",
                                   input: 252_258, cached: 244_608, output: 900, reasoning: 0),
            CodexRollout.userMessage(at: minutesAgo(99), text: "Now bump the appcast", kinds: ["user.text"]),
            response(95, id: "resp_3", input: 20_000, cached: 0),
            response(60, id: "resp_4", input: 40_000, cached: 39_000),
        ], named: "rollout-2026-09-06T10-00-00-\(chat).jsonl")
        let log = await turnLog()
        let window = LimitWindow(start: minutesAgo(210), end: now)
        let share = LimitShareRules.share(
            window: window,
            series: [
                LimitReading(time: minutesAgo(180), percent: 2),
                LimitReading(time: minutesAgo(30), percent: 5),
            ],
            log: log
        )
        let stretches = try XCTUnwrap(LimitShareRules.stretches(of: share, log: log, serviceID: "codex")[chat])
        XCTAssertEqual(stretches.map(\.opening), [.firstTurn, .compaction])
        XCTAssertEqual(stretches.map(\.prompt), ["Review the installer", "Now bump the appcast"])
        XCTAssertEqual(stretches.map(\.firstAt), [minutesAgo(190), minutesAgo(95)])
        let rebuilt = try XCTUnwrap(log.turns.first { $0.timestamp == minutesAgo(95) })
        XCTAssertTrue(LimitShareRules.isColdStart(rebuilt, serviceID: "codex"), "resp_3 rebuilt the context 5 minutes after the compaction")
        XCTAssertEqual(stretches.reduce(0) { $0 + $1.points }, try XCTUnwrap(share.chats.first).points, accuracy: 1e-9)
    }
}
