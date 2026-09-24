import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Pricing: "Claude marks fallback-priced turns and re-prices those". A model neither
/// models.dev nor the offline table names is priced at its family's newest member — a
/// guess the cost cache kept across relaunches (report B #1). It is priced again once
/// the live table names the model; a turn the table named when it was read keeps its
/// dollars. The records are the shape Claude Code 2.1.280 writes on this Mac (see
/// `JSONLDeferredFoldTests`), ids and paths scrubbed.
final class JSONLFallbackRepricingTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let sessionID = "9e41c2b7-3a58-4d0f-b6e2-8c17a5d93f04"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    /// No table names it; "opus" in the id prices it at claude-opus-4-8's $5 / $25.
    private let unnamedModel = "claude-opus-9"
    private let liveRate = ModelPrice(
        inputPerM: 6, outputPerM: 30, cacheReadPerM: 0.6,
        cacheCreate5mPerM: 7.5, cacheCreate1hPerM: 12
    )

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLFallbackRepricingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ModelPricing.updateDynamic([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
        ModelPricing.updateDynamic([:])
    }

    /// Beside the log root, never inside it, and never in the real Application Support.
    private var cacheURL: URL {
        root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-cost-cache.json")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// One final `type: assistant` line: a million tokens in, a million out, no cache.
    private func record(id: String, model: String, minutesAgo: Double) -> String {
        let at = Self.iso.string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"\(model)","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"container":null,"stop_reason":"end_turn",\
        "stop_sequence":null,"stop_details":null,"usage":{"input_tokens":1000000,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0,\
        "output_tokens":1000000,"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfTestRequest0000000000",\
        "type":"assistant","uuid":"8e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(at)","effort":"xhigh","perTurnEffort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// `<root>/<project>/<sessionId>.jsonl`, where Claude Code keeps a chat's main transcript.
    private func writeTranscript(_ lines: [String]) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    private func lastHour(_ aggregator: JSONLAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - A running aggregator

    func testAGuessedTurnTakesTheLiveRateOnceTheTableNamesItsModel() async throws {
        try writeTranscript([record(id: "msg_01GuessA", model: unnamedModel, minutesAgo: 10)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        let guessed = await lastHour(aggregator)
        XCTAssertEqual(guessed.cost, 30, accuracy: 1e-9, "$5 in + $25 out at the Opus family's rate")

        ModelPricing.updateDynamic([unnamedModel: liveRate])
        await aggregator.refresh()

        let priced = await lastHour(aggregator)
        XCTAssertEqual(priced.cost, 36, accuracy: 1e-9, "$6 in + $30 out, the model's own rate")
        XCTAssertEqual(try XCTUnwrap(priced.breakdown.cost).total, 36, accuracy: 1e-9)
    }

    func testATurnTheTableNamedKeepsItsDollars() async throws {
        try writeTranscript([record(id: "msg_01NamedA", model: "claude-sonnet-5", minutesAgo: 10)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()

        ModelPricing.updateDynamic([
            "claude-sonnet-5": ModelPrice(
                inputPerM: 999, outputPerM: 999, cacheReadPerM: 999,
                cacheCreate5mPerM: 999, cacheCreate1hPerM: 999
            )
        ])
        await aggregator.refresh()

        let usage = await lastHour(aggregator)
        XCTAssertEqual(usage.cost, 12, accuracy: 1e-9, "$2 + $10 at its own row, stored with the turn")
    }

    func testTheChatTakesTheRepricedDollars() async throws {
        try writeTranscript([record(id: "msg_01GuessB", model: unnamedModel, minutesAgo: 10)])
        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, calendar: utc)
        await aggregator.refresh()
        ModelPricing.updateDynamic([unnamedModel: liveRate])
        await aggregator.refresh()

        let chats = await aggregator.sessions(from: now.addingTimeInterval(-3600), to: now)
        let chat = try XCTUnwrap(chats.first)
        XCTAssertEqual(chat.turns, 1)
        XCTAssertEqual(try XCTUnwrap(chat.tokens.cost).total, 36, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chat.models.first?.tokens.cost).total, 36, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(chat.days.first?.tokens.cost).total, 36, accuracy: 1e-9)
    }

    // MARK: - Across a relaunch

    func testAGuessSavedByAnEarlierRunIsRepricedAfterTheRelaunch() async throws {
        try writeTranscript([record(id: "msg_01GuessC", model: unnamedModel, minutesAgo: 10)])
        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()

        ModelPricing.updateDynamic([unnamedModel: liveRate])
        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await relaunched.refresh()

        let parsed = await relaunched.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the turn came back from the cache, not from reading the transcript again")
        let usage = await lastHour(relaunched)
        XCTAssertEqual(usage.cost, 36, accuracy: 1e-9)
    }

    private func decodedTurn(model: String, extra: String = "") throws -> CLITurn {
        let json = """
        {"id":"msg_01Saved","timestamp":"2026-09-06T12:00:00Z","model":"\(model)",\
        "tokens":{"input":1,"output":1,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0,"thinking":0},\
        "projectSlug":"-Users-tester-Projects-alpha"\(extra)}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CLITurn.self, from: Data(json.utf8))
    }

    /// A 2.6.x cache holds turns saved before the mark existed. The ones whose model the
    /// offline table has no row for were live-priced or guessed; treating them as
    /// guesses prices them once at the table that is live now.
    func testASavedTurnWithoutTheMarkIsAGuessExactlyWhenNoTableRowNamesItsModel() throws {
        XCTAssertTrue(try decodedTurn(model: "claude-opus-9").pricedByFallback)
        XCTAssertFalse(try decodedTurn(model: "claude-sonnet-5").pricedByFallback)
        XCTAssertFalse(
            try decodedTurn(model: "claude-haiku-4-5-20251001").pricedByFallback,
            "a dated id normalizes onto its row"
        )
    }

    func testTheSavedMarkWinsOverTheInference() throws {
        XCTAssertTrue(try decodedTurn(model: "claude-sonnet-5", extra: #","pricedByFallback":true"#).pricedByFallback)
        XCTAssertFalse(try decodedTurn(model: "claude-opus-9", extra: #","pricedByFallback":false"#).pricedByFallback)
    }
}
