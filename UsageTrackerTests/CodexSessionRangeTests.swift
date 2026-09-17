import XCTest
@testable import Omelette

/// § 1's range contract for Codex: day-granularity clipping, a sub-day range widening
/// to its own day, days taken from the record timestamp rather than the rollout's
/// directory, and the 92-day retention that outlives the 31-day `recentTurns` window.
final class CodexSessionRangeTests: XCTestCase {
    private var root: URL!
    private var tree: CodexTree!
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    private var now: Date!

    private let cwd = "/tmp/Codex Fixtures/alpha app"
    private let model = "gpt-5.6-terra"
    private let sessionID = "01a066c7-43c2-7d40-9ff7-895659fc5345"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionRangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tree = try CodexTree(under: root)
        let real = Date()
        // At least six hours into the UTC day: `now − 1 day` has to be a different UTC
        // day, and the History tab's 5h range (`now − 5h`, below) has to stay inside
        // today — an hour's clamp let that range cross midnight whenever the suite ran
        // before 05:00 and the "today only" assertion failed.
        // Truncated to a whole second so a fixture timestamp, which is written with
        // millisecond precision, survives the format/parse round trip unchanged.
        now = Date(timeIntervalSince1970:
            max(real, calendar.startOfDay(for: real).addingTimeInterval(6 * 3600))
                .timeIntervalSince1970.rounded(.down))
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
    private func daysAgo(_ n: Double) -> Date { at(n * 24 * 3600) }

    private func loaded() async -> CodexUsageAggregator {
        let aggregator = tree.aggregator(calendar: calendar)
        await aggregator.refresh()
        return aggregator
    }

    /// Three responses on three consecutive UTC days: 1_100, 2_200 and 3_300 tokens,
    /// oldest first. All in one file, as a resumed chat would be.
    private func writeThreeDays() throws {
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, cwd: cwd, at: daysAgo(2)),
            CodexRollout.turnContext(model: model, effort: "high", cwd: cwd, at: daysAgo(2)),
            CodexRollout.record(at: daysAgo(2), threadID: sessionID, responseID: "resp_1",
                                input: 3_000, cached: 1_500, output: 300, reasoning: 60),
            CodexRollout.record(at: daysAgo(1), threadID: sessionID, responseID: "resp_2",
                                input: 2_000, cached: 1_000, output: 200, reasoning: 50),
            CodexRollout.record(at: daysAgo(0), threadID: sessionID, responseID: "resp_3",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-08T10-00-00-\(sessionID).jsonl")
    }

    func testTheWholeRangeKeepsEveryDay() async throws {
        try writeThreeDays()

        let sessions = await loaded().sessions(from: daysAgo(3), to: now)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.days.count, 3)
        XCTAssertEqual(s.days.map(\.day), s.days.map(\.day).sorted(), "ascending")
        XCTAssertEqual(s.days.map(\.turns), [1, 1, 1])
        XCTAssertEqual(s.days.map(\.tokens.total), [3_300, 2_200, 1_100])
        XCTAssertEqual(s.turns, 3)
        XCTAssertEqual(s.tokens.total, 6_600)
        XCTAssertEqual(s.mainTokens.total, 6_600)
    }

    func testARangeOfOneDayKeepsTwoLocalDaysAndReSumsTheTotals() async throws {
        // 24h spans two local days; § 1 clips at day granularity, so the day the range
        // starts in is kept whole and the day before it is dropped.
        try writeThreeDays()

        let sessions = await loaded().sessions(from: daysAgo(1), to: now)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.days.count, 2)
        XCTAssertEqual(s.turns, 2)
        XCTAssertEqual(s.tokens.total, 3_300, "2_200 + 1_100")
        XCTAssertEqual(s.mainTokens.total, 3_300)
        XCTAssertEqual(s.firstAt, daysAgo(2), "the chat's own span, not the range's")
        XCTAssertEqual(s.lastAt, daysAgo(0))
    }

    func testARangeShorterThanADayWidensToTheDayItFallsIn() async throws {
        // The History tab's 5h range. Everything today counts; nothing from yesterday.
        try writeThreeDays()

        let sessions = await loaded().sessions(from: at(5 * 3600), to: now)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.days.count, 1)
        XCTAssertEqual(s.turns, 1)
        XCTAssertEqual(s.tokens.total, 1_100, "today's response, though it fell outside the 5h")
    }

    func testASessionWithNoDayInTheRangeIsNotReturnedAtAll() async throws {
        try writeThreeDays()

        let sessions = await loaded().sessions(from: daysAgo(9), to: daysAgo(5))
        XCTAssertTrue(sessions.isEmpty)
    }

    func testTheDayComesFromTheRecordTimestampNotTheRolloutDirectory() async throws {
        // Codex files a resumed chat under the directory of the day it STARTED. Reading
        // the day off the path would put today's spend on a day in January.
        try tree.writeRollout([
            CodexRollout.sessionMeta(sessionID: sessionID, cwd: cwd, at: daysAgo(0)),
            CodexRollout.turnContext(model: model, cwd: cwd, at: daysAgo(0)),
            CodexRollout.record(at: daysAgo(0), threadID: sessionID, responseID: "resp_1",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], day: "2026/01/02", named: "rollout-2026-01-02T10-00-00-\(sessionID).jsonl")

        let sessions = await loaded().sessions(from: daysAgo(1), to: now)
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.days.map(\.day), [calendar.startOfDay(for: now)])
    }

    func testAnAgentThatRanOnlyOnADroppedDayIsNotInTheClippedSummary() async throws {
        let agentThread = "01a066c9-1614-7f60-9a78-5d7d6a6c7f9d"
        try writeThreeDays()
        try tree.writeRollout([
            CodexRollout.subagentMeta(sessionID: sessionID, threadID: agentThread,
                                      parentThreadID: sessionID, nickname: "Bacon",
                                      agentPath: "/root/installer_review", cwd: cwd,
                                      at: daysAgo(2)),
            CodexRollout.turnContext(model: model, effort: "low", cwd: cwd, at: daysAgo(2)),
            CodexRollout.record(at: daysAgo(2), threadID: agentThread, sessionID: sessionID,
                                responseID: "resp_agent",
                                input: 1_000, cached: 400, output: 100, reasoning: 30),
        ], named: "rollout-2026-09-08T10-05-00-\(agentThread).jsonl")

        let fullSessions = await loaded().sessions(from: daysAgo(3), to: now)
        let full = try XCTUnwrap(fullSessions.first)
        XCTAssertEqual(full.agents.map(\.kind), ["Bacon"])

        let clippedSessions = await loaded().sessions(from: daysAgo(1), to: now)
        let clipped = try XCTUnwrap(clippedSessions.first)
        XCTAssertTrue(clipped.agents.isEmpty, "its whole span is before the range")
        XCTAssertEqual(clipped.turns, 2, "and its turn is not in the re-summed days either")
    }

    // MARK: - Retention

    func testAChatOlderThanNinetyTwoDaysIsDroppedAndAnEightyDayOldOneIsNot() async throws {
        // Both files are touched now — otherwise the 90-day mtime window would skip
        // them and the retention rule would never be exercised.
        let old = "019f4b9d-262c-7173-b61f-1b9934fcec88"
        let older = "019f508c-1bf5-7501-b374-2c6f787bfbaa"
        for (id, age) in [(old, 80.0), (older, 100.0)] {
            let url = try tree.writeRollout([
                CodexRollout.sessionMeta(sessionID: id, cwd: cwd, at: daysAgo(age)),
                CodexRollout.turnContext(model: model, cwd: cwd, at: daysAgo(age)),
                CodexRollout.record(at: daysAgo(age), threadID: id, responseID: "resp_1",
                                    input: 1_000, cached: 400, output: 100, reasoning: 30),
            ], day: "2026/06/20", named: "rollout-2026-06-20T10-00-00-\(id).jsonl")
            try FileManager.default.setAttributes(
                [.modificationDate: now!], ofItemAtPath: url.path
            )
        }

        let sessions = await loaded().sessions(from: daysAgo(120), to: now)
        XCTAssertEqual(sessions.map(\.id), [old], "92 days of chats, and not a day more")
    }
}
