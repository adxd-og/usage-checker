import XCTest
@testable import Omelette

/// Spec § 3: "Scan `~/.codex/archived_sessions/` too, and never recount a file that
/// moved there (key files by `threadID`, not path)." The archive is a flat directory of
/// the same `rollout-<ts>-<thread uuid>.jsonl` files the dated tree holds.
final class CodexArchivedRolloutTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let now: Date = {
        let real = Date()
        return max(real, Calendar.current.startOfDay(for: real).addingTimeInterval(3600))
    }()
    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let threadID = "01a073d5-72f2-7020-8904-65c6d733aca7"

    private var fileName: String { "rollout-2026-09-06T02-09-23-\(threadID).jsonl" }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexArchivedRolloutTests-\(UUID().uuidString)", isDirectory: true)
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

    private func lines() -> [String] {
        [
            CodexRollout.sessionMeta(sessionID: threadID, cwd: cwd, at: at(900)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: at(890)),
            CodexRollout.record(at: at(600), threadID: threadID, responseID: "resp_a",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ]
    }

    private func lastHour(_ aggregator: CodexUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    func testARolloutInTheArchiveIsCounted() async throws {
        try tree.writeArchived(lines(), named: fileName)

        let aggregator = tree.aggregator()
        await aggregator.refresh()
        let usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1, "the archive is spend like any other rollout")
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testARolloutThatMovesIntoTheArchiveIsNotCountedTwice() async throws {
        let live = try tree.writeRollout(lines(), named: fileName)

        let aggregator = tree.aggregator()
        await aggregator.refresh()
        var usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1)

        try FileManager.default.createDirectory(at: tree.archived, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: live, to: tree.archived.appendingPathComponent(fileName))
        await aggregator.refresh()

        usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 1, "the same thread, at a new path, is the same file")
        XCTAssertEqual(usage.tokens, 1_100)
        XCTAssertEqual(usage.cost, 0.0018, accuracy: 1e-12)
    }

    func testAnArchivedRolloutStillHasATailRead() async throws {
        // The archive is not frozen: `codex resume` can append to a file that has
        // already been archived, and the appended turn must arrive exactly once.
        try tree.writeArchived(lines(), named: fileName)
        let aggregator = tree.aggregator()
        await aggregator.refresh()

        try tree.writeArchived(lines() + [
            CodexRollout.record(at: at(300), threadID: threadID, responseID: "resp_b",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: fileName)
        await aggregator.refresh()

        let usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.tokens, 2_200)
    }

    func testTheFileKeyIsTheThreadUUIDTheFileNameEndsWith() {
        let url = URL(fileURLWithPath: "/tmp/x/2026/09/06/rollout-2026-09-06T02-09-23-\(threadID).jsonl")
        XCTAssertEqual(CodexUsageAggregator.fileKey(for: url), threadID)

        // Nothing UUID-shaped to key on: the path is the only identity there is.
        let odd = URL(fileURLWithPath: "/tmp/x/notes.jsonl")
        XCTAssertEqual(CodexUsageAggregator.fileKey(for: odd), "/tmp/x/notes.jsonl")

        // Right length, wrong alphabet.
        let bogus = URL(fileURLWithPath: "/tmp/x/rollout-zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz.jsonl")
        XCTAssertEqual(CodexUsageAggregator.fileKey(for: bogus), bogus.path)
    }

    func testTheArchiveAndTheIndexAreDerivedOnlyFromARootNamedSessions() {
        let real = URL(fileURLWithPath: "/Users/tester/.codex/sessions", isDirectory: true)
        XCTAssertEqual(
            CodexUsageAggregator.sibling(of: real, named: "archived_sessions")?.path,
            "/Users/tester/.codex/archived_sessions"
        )
        XCTAssertEqual(
            CodexUsageAggregator.sibling(of: real, named: "session_index.jsonl")?.path,
            "/Users/tester/.codex/session_index.jsonl"
        )
        // A test root is not a Codex home, so a suite that injects one reads neither
        // the archive nor the index — whatever happens to sit next to it.
        let temp = URL(fileURLWithPath: "/tmp/CodexUsageAggregatorTests-1234", isDirectory: true)
        XCTAssertNil(CodexUsageAggregator.sibling(of: temp, named: "archived_sessions"))
        XCTAssertNil(CodexUsageAggregator.sibling(of: temp, named: "session_index.jsonl"))
    }
}
