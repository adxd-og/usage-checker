import XCTest
@testable import Omelette

/// Claude's chat events on their way to the Limits tab's stretches, checked against spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5 and § Packages 3:
/// compactions (not sidechain) and typed prompts inside the 31-day horizon, once each, in the
/// cost cache; a cache from before reads them back from the transcripts, only up to each
/// file's mark, and never counts a turn twice.
///
/// Lines are the shapes Claude Code 2.1.257 to 2.1.263 writes (ids, names and paths
/// scrubbed). Dates are relative to the real clock because the aggregator keeps what is
/// younger than its horizon by `Date()`.
final class JSONLChatEventsVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private let chatA = "d5dff4f0-3038-4ed6-81d6-ddccee879027"
    private let chatB = "90a2e89b-86f7-438b-bbb1-d0b5735809e3"
    private let alphaSlug = "-Users-tester-Projects-alpha"
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
            .appendingPathComponent("JSONLChatEventsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private var cacheURL: URL {
        root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-cost-cache.json")
    }

    private func aggregator() -> JSONLAggregator {
        JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: calendar)
    }

    private func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: - Fixture records

    private func turn(
        id: String, at date: Date, session: String, sidechain: Bool = false,
        input: Int = 1000, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0, output: Int = 10,
        text: String = "…"
    ) -> String {
        let agent = sidechain ? "\"agentId\":\"\(agentID)\"," : ""
        return """
        {"parentUuid":"a52e981d-5284-41fc-980c-1ebad5d261d6","isSidechain":\(sidechain),\(agent)\
        "message":{"model":"claude-sonnet-4-5","id":"\(id)","type":"message","role":"assistant",\
        "content":[{"type":"text","text":"\(text)"}],"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(write5m + write1h),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "cache_creation":{"ephemeral_5m_input_tokens":\(write5m),"ephemeral_1h_input_tokens":\(write1h)},\
        "service_tier":"standard"}},"apiBlockIndex":0,\
        "requestId":"req_011CenRuxq86v1VeS6TBkZqi","type":"assistant",\
        "uuid":"06c89072-80fe-4536-969d-70eeaafb33ca",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"high",\
        "userType":"external","entrypoint":"cli",\
        "cwd":"~/Projects/alpha","sessionId":"\(session)","version":"2.1.263",\
        "gitBranch":"main","slug":"lovely-questing-crown"}
        """
    }

    private func compaction(at date: Date, session: String, sidechain: Bool = false) -> String {
        let agent = sidechain ? "\"agentId\":\"\(agentID)\"," : ""
        return """
        {"parentUuid":null,"logicalParentUuid":"d1b77e27-5917-462f-8c04-4163d9c86dd9",\
        "isSidechain":\(sidechain),\(agent)"type":"system","subtype":"compact_boundary",\
        "content":"Conversation compacted","level":"info",\
        "compactMetadata":{"trigger":"manual","preTokens":926842,"postTokens":25865},\
        "uuid":"250ddee4-8119-47db-a7a0-ad2d86929b99","timestamp":"\(Self.iso.string(from: date))",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(session)","version":"2.1.257","gitBranch":"main","slug":"keen-meandering-nest"}
        """
    }

    private func prompt(_ text: String, at date: Date, session: String) -> String {
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

    private func writeMain(_ lines: [String], session: String, append: Bool = false, modified: Date? = nil) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        let text = lines.joined(separator: "\n") + "\n"
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func writeSubagent(_ lines: [String], session: String) throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("agent-\(agentID).jsonl"), atomically: true, encoding: .utf8
        )
    }

    /// The cache as a build from before chats' events were kept left it.
    private func makeCacheFromBeforeChatEvents() throws {
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""compactions":"#))
        XCTAssertTrue(text.contains(#""prompts":"#))
        try text
            .replacingOccurrences(of: #""compactions":"#, with: #""compactionsBefore":"#)
            .replacingOccurrences(of: #""prompts":"#, with: #""promptsBefore":"#)
            .write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    private func readBack(_ aggregator: JSONLAggregator) async {
        let task = await aggregator.chatEventsReadBack
        await task?.value
    }

    // MARK: - Read-back beside a transcript that grew

    func testATranscriptThatGrewSinceTheOldCacheKeepsEveryEventAndEveryTurnOnce() async throws {
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            turn(id: "msg_a2", at: minutesAgo(45), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        // Claude Code goes on writing between two launches.
        try writeMain([
            prompt("Now the changelog", at: minutesAgo(30), session: chatA),
            compaction(at: minutesAgo(20), session: chatA),
            turn(id: "msg_a3", at: minutesAgo(10), session: chatA),
        ], session: chatA, append: true)

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        let log = await relaunched.turnCosts(from: minutesAgo(300), to: now)

        XCTAssertEqual(log.turns.count, 3, "msg_a1, msg_a2 and msg_a3, once each")
        XCTAssertEqual(log.compactions[chatA], [minutesAgo(60), minutesAgo(20)])
        XCTAssertEqual(log.prompts[chatA], [
            ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test"),
            ChatPrompt(at: minutesAgo(30), text: "Now the changelog"),
        ])
    }

    func testAReadBackThatFinishedLeavesNothingOwedAndEachEventOnce() async throws {
        // The cache's mark is the file's size, so the scan reads nothing and the read-back
        // takes it all; a launch after that must not take a second copy.
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(45), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let second = aggregator()
        await second.refresh()
        await readBack(second)
        await second.flushCache()

        let third = aggregator()
        await third.refresh()
        let readBackOnThird = await third.chatEventsReadBack
        XCTAssertNil(readBackOnThird, "everything owed was read; nothing is owed any more")
        let log = await third.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.compactions[chatA], [minutesAgo(60)])
        XCTAssertEqual(log.prompts[chatA]?.count, 1)
        XCTAssertEqual(log.turns.count, 1)
    }

    func testRefreshingTwiceDoesNotStartASecondReadBack() async throws {
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let relaunched = aggregator()
        await relaunched.refresh()
        let first = await relaunched.chatEventsReadBack
        await relaunched.refresh()
        let second = await relaunched.chatEventsReadBack
        await readBack(relaunched)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "one read-back per launch")
        let log = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.prompts[chatA]?.count, 1)
        XCTAssertEqual(log.turns.count, 1)
    }

    func testATranscriptDeletedBeforeTheReadBackIsNotOwedAgain() async throws {
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()
        try FileManager.default.removeItem(at: root.appendingPathComponent(alphaSlug))

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        await relaunched.flushCache()

        let third = aggregator()
        await third.refresh()
        let owed = await third.chatEventsReadBack
        XCTAssertNil(owed, "a transcript that is gone is nothing owed")
        let log = await third.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.turns.count, 1, "the cache still holds the turn it counted")
        XCTAssertEqual(log.prompts, [:])
    }

    // MARK: - What the read-back takes and leaves

    func testASubAgentsCompactionIsNotTheChatsEvenWhenItIsReadBack() async throws {
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
        ], session: chatA)
        try writeSubagent([
            turn(id: "msg_agent", at: minutesAgo(90), session: chatA, sidechain: true),
            compaction(at: minutesAgo(80), session: chatA, sidechain: true),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        let log = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.compactions, [:])
        XCTAssertEqual(log.turns.count, 2, "the sub-agent's turn counts once, under its parent chat")
    }

    func testAWordTheMarkersShareWithNormalLinesMakesNoEventAndAPromptNamingItIsOne() async throws {
        let typed = "How does Claude Code write a compact_boundary record?"
        try writeMain([
            prompt(typed, at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA,
                 text: "A compact_boundary record has subtype compact_boundary."),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        let log = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.compactions, [:], "an assistant line that says the word is no compaction")
        XCTAssertEqual(log.prompts[chatA], [ChatPrompt(at: minutesAgo(110), text: typed)],
                       "a line both markers find is one prompt")
    }

    func testOnlyEventsInsideTheHorizonAreReadBack() async throws {
        let fortyDaysAgo = now.addingTimeInterval(-40 * 86_400)
        let thirtyDaysAgo = now.addingTimeInterval(-30 * 86_400)
        try writeMain([
            prompt("An old prompt", at: fortyDaysAgo, session: chatA),
            compaction(at: fortyDaysAgo.addingTimeInterval(60), session: chatA),
            prompt("A prompt still inside", at: thirtyDaysAgo, session: chatA),
            compaction(at: thirtyDaysAgo.addingTimeInterval(60), session: chatA),
            turn(id: "msg_a1", at: thirtyDaysAgo.addingTimeInterval(120), session: chatA),
        ], session: chatA)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        let log = await relaunched.turnCosts(from: now.addingTimeInterval(-31 * 86_400), to: now)
        XCTAssertEqual(log.compactions[chatA], [thirtyDaysAgo.addingTimeInterval(60)])
        XCTAssertEqual(log.prompts[chatA], [ChatPrompt(at: thirtyDaysAgo, text: "A prompt still inside")])
    }

    func testEventsOfTwoChatsInOneProjectStayWithTheirOwnChat() async throws {
        try writeMain([
            prompt("Fix the flaky reset test", at: minutesAgo(110), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
            compaction(at: minutesAgo(60), session: chatA),
        ], session: chatA)
        try writeMain([
            prompt("Bump the appcast", at: minutesAgo(90), session: chatB),
            turn(id: "msg_b1", at: minutesAgo(80), session: chatB),
            compaction(at: minutesAgo(30), session: chatB),
        ], session: chatB)
        await aggregator().refresh()
        try makeCacheFromBeforeChatEvents()

        let relaunched = aggregator()
        await relaunched.refresh()
        await readBack(relaunched)
        let log = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(log.compactions, [chatA: [minutesAgo(60)], chatB: [minutesAgo(30)]])
        XCTAssertEqual(log.prompts[chatA]?.map(\.text), ["Fix the flaky reset test"])
        XCTAssertEqual(log.prompts[chatB]?.map(\.text), ["Bump the appcast"])
    }

    // MARK: - Times to the whole second

    func testEventsWithFractionsOfASecondAreKeptOnceAcrossARelaunchAndARereadOfTheFile() async throws {
        let fraction = 0.789
        let promptAt = minutesAgo(110).addingTimeInterval(fraction)
        let compactionAt = minutesAgo(60).addingTimeInterval(fraction)
        let lines = [
            prompt("Fix the flaky reset test", at: promptAt, session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100).addingTimeInterval(fraction), session: chatA),
            compaction(at: compactionAt, session: chatA),
            turn(id: "msg_a2", at: minutesAgo(45).addingTimeInterval(fraction), session: chatA),
        ]
        try writeMain(lines, session: chatA)
        await aggregator().refresh()

        let relaunched = aggregator()
        await relaunched.refresh()
        let afterRelaunch = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(afterRelaunch.compactions[chatA], [minutesAgo(60)], "to the whole second, as the cache keeps it")
        XCTAssertEqual(afterRelaunch.prompts[chatA], [ChatPrompt(at: minutesAgo(110), text: "Fix the flaky reset test")])

        // The file is rewritten shorter: it is read again from the top.
        try writeMain(Array(lines.dropLast()), session: chatA)
        let reread = aggregator()
        await reread.refresh()
        let afterReread = await reread.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(afterReread.compactions[chatA], [minutesAgo(60)])
        XCTAssertEqual(afterReread.prompts[chatA]?.count, 1)
        XCTAssertEqual(afterReread.turns.count, 2, "msg_a1 and msg_a2 were counted; the replay adds nothing")
    }

    func testTwoPromptsInTheSameSecondAreBothKeptInAStableOrder() async throws {
        let at = minutesAgo(110)
        try writeMain([
            prompt("Second thought", at: at.addingTimeInterval(0.2), session: chatA),
            prompt("First thought", at: at.addingTimeInterval(0.1), session: chatA),
            turn(id: "msg_a1", at: minutesAgo(100), session: chatA),
        ], session: chatA)
        let first = aggregator()
        await first.refresh()
        let relaunched = aggregator()
        await relaunched.refresh()
        let a = await first.turnCosts(from: minutesAgo(300), to: now)
        let b = await relaunched.turnCosts(from: minutesAgo(300), to: now)
        XCTAssertEqual(a.prompts[chatA]?.count, 2)
        XCTAssertEqual(a.prompts, b.prompts, "the same list before and after the cache")
    }
}
