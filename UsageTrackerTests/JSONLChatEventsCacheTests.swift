import XCTest
@testable import Omelette

/// Claude chat events across a relaunch: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5, and
/// § Packages 3 ("needs the aggregators to keep compaction times … and first prompts").
/// The cost cache spares a relaunch the gigabytes of transcripts already read, so what
/// they said about compactions and prompts has to live in it too.
final class JSONLChatEventsCacheTests: XCTestCase {
    private var root: URL!
    /// Whole seconds, so a timestamp survives the fixture's format/parse round trip.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private let chatA = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let chatOld = "4c1f7e2a-9b3d-4e8f-a6c5-2d7b9e0f1a34"
    private let alphaSlug = "-Users-tester-Projects-alpha"
    private let agentID = "a06ceeae2762ca204"

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
            .appendingPathComponent("JSONLChatEventsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Beside the log root, never inside it, and never in the real Application Support.
    private var cacheURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-cost-cache.json")
    }

    private func aggregator() -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: calendar)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: - Fixture records (Claude Code 2.1.257 to 2.1.263, scrubbed)

    private func mainTurn(id: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":1000,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,"output_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "service_tier":"standard"}},"apiBlockIndex":0,\
        "requestId":"req_011CenRuxq86v1VeS6TBkZqi","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"high",\
        "session_id":"\(session)","userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session)","version":"2.1.263",\
        "gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    private func agentTurn(id: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"fc25257c-8b20-4d7f-995c-a082de57c332","isSidechain":true,\
        "agentId":"\(agentID)","apiBlockIndex":0,\
        "requestId":"req_011CeqhfbvWNe5EU6Yax6z9r","attributionAgent":"planner",\
        "type":"assistant","uuid":"86cfaef2-b622-4253-9e15-3e2a1548f357",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.263","gitBranch":"main",\
        "slug":"lovely-questing-crown",\
        "message":{"model":"claude-opus-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"…"}],\
        "usage":{"input_tokens":1000,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":0,\
        "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},\
        "output_tokens":0,"service_tier":"standard"}}}
        """
    }

    private func compaction(at date: Date, session: String) -> String {
        """
        {"parentUuid":null,"logicalParentUuid":"d1b77e27-5917-462f-8c04-4163d9c86dd9",\
        "isSidechain":false,"type":"system","subtype":"compact_boundary",\
        "content":"Conversation compacted","level":"info",\
        "compactMetadata":{"trigger":"manual","preTokens":926842,"postTokens":25865},\
        "uuid":"250ddee4-8119-47db-a7a0-ad2d86929b99","timestamp":"\(Self.iso.string(from: date))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.257","gitBranch":"main","slug":"keen-meandering-nest"}
        """
    }

    private func humanPrompt(_ text: String, at date: Date, session: String) -> String {
        """
        {"parentUuid":"519b6ce1-10d7-413d-b739-2966581c1e7b","isSidechain":false,\
        "promptId":"d1736237-53b5-43b6-a162-4aa2c485ae0b","type":"user",\
        "message":{"role":"user","content":"\(text)"},\
        "uuid":"80134f9a-bd14-4dbd-a4a0-fb6f4b43d0b1",\
        "timestamp":"\(Self.iso.string(from: date))","permissionMode":"auto",\
        "origin":{"kind":"human"},"promptSource":"typed","userType":"external",\
        "entrypoint":"cli","cwd":"~/Projects/alpha","sessionId":"\(session)",\
        "version":"2.1.263","gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    // MARK: - Fixture files

    /// A main transcript; `modified` sets the file's modification date, for one Claude
    /// Code has not written to since.
    private func writeMain(_ lines: [String], session: String, modified: Date? = nil) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func writeSubagent(_ lines: [String], session: String) throws {
        let dir = root
            .appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    // MARK: - Tests

    func testCompactionsAndPromptsSurviveARelaunch() async throws {
        try writeMain([
            humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            humanPrompt("Now the changelog", at: minutesAgo(50), session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(45), session: chatA),
        ], session: chatA)
        await aggregator().refresh()

        let relaunched = aggregator()
        await relaunched.refresh()
        let log = await relaunched.turnCosts(from: minutesAgo(200), to: now)

        let reopened = await relaunched.filesParsedInLastScan
        XCTAssertEqual(reopened, 0, "nothing new was written: the cache answers")
        XCTAssertEqual(log.compactions, [chatA: [minutesAgo(60)]])
        XCTAssertEqual(log.prompts[chatA], [
            ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test"),
            ChatPrompt(at: minutesAgo(50), text: "Now the changelog"),
        ])
    }

    func testACacheFromBeforeTheseEventsGetsThemBackWithoutCountingATurnTwice() async throws {
        try writeMain([
            humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(45), session: chatA),
        ], session: chatA)
        try writeSubagent([agentTurn(id: "msg_agent", at: minutesAgo(50), session: chatA)], session: chatA)
        // A chat of 40 days ago whose transcript nobody has written to since.
        let fortyDaysAgo = now.addingTimeInterval(-40 * 86_400)
        try writeMain([mainTurn(id: "msg_old", at: fortyDaysAgo, session: chatOld)], session: chatOld, modified: fortyDaysAgo)

        let first = aggregator()
        await first.refresh()
        let before = await first.turnCosts(from: now.addingTimeInterval(-31 * 86_400), to: now)
        let daysBefore = await first.breakdown().daily.map(\.totalCost)

        // More cached message ids than `refresh()` keeps, so the set that tells a known turn
        // is emptied on load.
        try makeCacheFromBeforeChatEvents(extraIDs: 500_001)

        let relaunched = aggregator()
        await relaunched.refresh()
        let reopened = await relaunched.filesParsedInLastScan
        let readBack = await relaunched.chatEventsReadBack
        await readBack?.value
        let after = await relaunched.turnCosts(from: now.addingTimeInterval(-31 * 86_400), to: now)
        let daysAfter = await relaunched.breakdown().daily.map(\.totalCost)

        XCTAssertEqual(reopened, 0, "the scan reopens no transcript: the events are read back beside it")
        XCTAssertNotNil(readBack, "a cache without events starts the read-back")
        XCTAssertEqual(after.turns.count, 3, "msg_a1, msg_a2 and the sub-agent's turn, once each")
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(daysAfter, daysBefore)
        XCTAssertEqual(after.compactions, [chatA: [minutesAgo(60)]])
        XCTAssertEqual(after.prompts[chatA], [ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test")])
    }

    func testATranscriptTheReadBackCouldNotOpenIsReadBackOnALaterLaunch() async throws {
        try writeMain([
            humanPrompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            mainTurn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            mainTurn(id: "msg_a2", at: minutesAgo(45), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        // The transcript cannot be opened while the read-back runs. Its size and
        // modification date stay as they were, so the scan has no reason to open it.
        let transcript = root.appendingPathComponent(alphaSlug).appendingPathComponent("\(chatA).jsonl").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript) }
        let blocked = aggregator()
        await blocked.refresh()
        let firstTry = await blocked.chatEventsReadBack
        await firstTry?.value
        await blocked.flushCache()
        let missed = await blocked.turnCosts(from: minutesAgo(200), to: now)
        XCTAssertEqual(missed.compactions, [:], "nothing could be read")
        XCTAssertEqual(missed.turns.count, 2, "the turns were never in question")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript)
        let relaunched = aggregator()
        await relaunched.refresh()
        let secondTry = await relaunched.chatEventsReadBack
        XCTAssertNotNil(secondTry, "the transcript is still owed")
        await secondTry?.value
        let after = await relaunched.turnCosts(from: minutesAgo(200), to: now)
        let reopened = await relaunched.filesParsedInLastScan
        XCTAssertEqual(reopened, 0)
        XCTAssertEqual(after.compactions, [chatA: [minutesAgo(60)]])
        XCTAssertEqual(after.prompts[chatA], [ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test")])
    }

    /// The cache as a build from before chats' compactions and prompts were kept left it:
    /// those under keys this build does not read, and `extraIDs` more cached message ids.
    /// Edited as text: the cached ids are 64-bit hashes a JSON round trip through doubles
    /// would not keep.
    private func makeCacheFromBeforeChatEvents(extraIDs: Int = 0) throws {
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""compactions":"#))
        XCTAssertTrue(text.contains(#""prompts":"#))
        XCTAssertTrue(text.contains(#""seenMessageIDs":["#), "the turns' ids are cached")
        var edited = text
            .replacingOccurrences(of: #""compactions":"#, with: #""compactionsBefore":"#)
            .replacingOccurrences(of: #""prompts":"#, with: #""promptsBefore":"#)
        if extraIDs > 0 {
            let ids = (1...extraIDs).map(String.init).joined(separator: ",")
            edited = edited.replacingOccurrences(of: #""seenMessageIDs":["#, with: #""seenMessageIDs":["# + ids + ",")
        }
        try edited.write(to: cacheURL, atomically: true, encoding: .utf8)
    }
}
