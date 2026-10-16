import XCTest
@testable import Omelette

/// From a Claude Code transcript to the stretches the Limits tab shows: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5. The chat is
/// cut at its compaction and at a cold start (a main-thread turn reading under 5 % of
/// its prompt from cache while writing at least 10,000 tokens), a sub-agent's turns count
/// in the stretch they ran in, and each stretch is named by the prompt typed for it.
/// Lines have the shapes Claude Code 2.1.257 to 2.1.263 writes (ids, names and paths
/// scrubbed); times are relative to the real clock because the aggregator's horizon is.
final class LimitStretchesFromTranscriptsVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    private let chat = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let slug = "-Users-tester-Projects-alpha"
    private let agentID = "a7f80c42893fb9281"
    private let calendar: Calendar = {
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
            .appendingPathComponent("LimitStretchesFromTranscriptsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func turn(
        _ id: String, _ minutes: Double, input: Int, read: Int, write1h: Int, sidechain: Bool = false
    ) -> String {
        let agent = sidechain ? "\"agentId\":\"\(agentID)\"," : ""
        return """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":\(sidechain),\(agent)\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write1h),\
        "cache_read_input_tokens":\(read),"output_tokens":500,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\(write1h)},\
        "service_tier":"standard"}},"apiBlockIndex":0,\
        "requestId":"req_011CenRuxq86v1VeS6TBkZqi","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: minutesAgo(minutes)))","effort":"high",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(chat)","version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    private func typed(_ text: String, _ minutes: Double) -> String {
        """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":"\(text)"},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: minutesAgo(minutes)))","permissionMode":"auto",\
        "origin":{"kind":"human"},"promptSource":"typed","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(chat)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    private func compaction(_ minutes: Double) -> String {
        """
        {"parentUuid":null,"logicalParentUuid":"d1b77e27-5917-462f-8c04-4163d9c86dd9",\
        "isSidechain":false,"type":"system","subtype":"compact_boundary",\
        "content":"Conversation compacted","level":"info",\
        "compactMetadata":{"trigger":"manual","preTokens":926842,"postTokens":25865},\
        "uuid":"250ddee4-8119-47db-a7a0-ad2d86929b99","timestamp":"\(Self.iso.string(from: minutesAgo(minutes)))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(chat)","version":"2.1.257","gitBranch":"main","slug":"keen-meandering-nest"}
        """
    }

    func testATranscriptIsCutAtItsCompactionAndItsColdStartAndNamedByThePromptsTypedForThem() async throws {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        let sub = dir.appendingPathComponent(chat, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try ([
            typed("Fix the flaky reset test", 300),
            turn("msg_1", 295, input: 3, read: 0, write1h: 40_000),       // the chat's first turn writes its context
            turn("msg_2", 285, input: 5, read: 40_000, write1h: 800),     // warm
            turn("msg_3", 270, input: 5, read: 40_800, write1h: 600),     // warm
            compaction(200),
            typed("Now the changelog", 198),
            turn("msg_4", 195, input: 3, read: 0, write1h: 30_000),       // the compacted context written again
            turn("msg_5", 190, input: 5, read: 30_000, write1h: 500),     // warm
            typed("After lunch: the appcast", 60),
            turn("msg_6", 55, input: 4, read: 0, write1h: 35_000),        // the cache expired over lunch
            turn("msg_7", 50, input: 5, read: 35_000, write1h: 400),      // warm
        ].joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(chat).jsonl"), atomically: true, encoding: .utf8
        )
        try (turn("msg_agent", 52, input: 5, read: 0, write1h: 15_000, sidechain: true) + "\n").write(
            to: sub.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )

        let aggregator = JSONLAggregator(rootURL: root, cacheURL: nil, saveInterval: 0, calendar: calendar)
        await aggregator.refresh()
        let log = await aggregator.turnCosts(from: minutesAgo(400), to: now)
        XCTAssertEqual(log.turns.count, 8, "seven main-thread turns and the sub-agent's")

        let share = LimitShareRules.share(
            window: LimitWindow(start: minutesAgo(400), end: now),
            series: [
                LimitReading(time: minutesAgo(250), percent: 3),
                LimitReading(time: minutesAgo(180), percent: 6),
                LimitReading(time: minutesAgo(40), percent: 12),
            ],
            log: log
        )
        let result = try XCTUnwrap(LimitShareRules.stretches(of: share, log: log, serviceID: "claude")[chat])
        XCTAssertEqual(result.map(\.opening), [.firstTurn, .compaction, .coldStart])
        XCTAssertEqual(result.map(\.prompt), ["Fix the flaky reset test", "Now the changelog", "After lunch: the appcast"])
        XCTAssertEqual(result.map(\.firstAt), [minutesAgo(295), minutesAgo(195), minutesAgo(55)])
        XCTAssertEqual(result[2].lastAt, minutesAgo(50), "the sub-agent's turn at 52 ran inside it")
        XCTAssertEqual(result.reduce(0) { $0 + $1.points }, try XCTUnwrap(share.chats.first).points, accuracy: 1e-9)
        XCTAssertEqual(result.reduce(0) { $0 + $1.cost }, share.cost, accuracy: 1e-9)

        // Sonnet's list prices: $3/M fresh input, $6/M one-hour cache writes.
        XCTAssertEqual(result[0].coldStartCost, 0, accuracy: 1e-9, "the first turn builds the chat's context; it does not rebuild it")
        XCTAssertEqual(result[2].coldStartCost, Double(35_000 * 6 + 4 * 3) / 1_000_000, accuracy: 1e-6,
                       "the sub-agent's 15,000-token write is not the chat's cold start")
        XCTAssertGreaterThan(result[1].coldStartCost, 0, "msg_4 rebuilt the context after the compaction")
    }
}
