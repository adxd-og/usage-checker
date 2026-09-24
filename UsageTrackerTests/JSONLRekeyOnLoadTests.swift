import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Time zone: "folded days are re-keyed on load by day components". The cost cache
/// saves each folded day — and each chat's day totals — as the midnight of the zone it
/// was binned in. Relaunched in another zone, those keys named no day of the new
/// calendar: Activity squares went blank while the cards still summed them, and a chat
/// fell outside the History range asking for its date (report B #3). The record is the
/// shape Claude Code 2.1.280 writes (see `JSONLDeferredFoldTests`), ids and paths scrubbed.
final class JSONLRekeyOnLoadTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let sessionID = "5b0e3c1a-7d42-4f96-a8e1-2c9d6b4f0a37"
    private let alphaSlug = "-Users-tester-Projects-alpha"

    private static func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { Self.calendar(secondsFromGMT: 0) }
    private var plus3: Calendar { Self.calendar(secondsFromGMT: 3 * 3600) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLRekeyOnLoadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: cacheURL)
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

    /// Noon UTC forty days back: folded (past the 31-day window), inside the chats' 92,
    /// and the same date at UTC+3.
    private var turnAt: Date {
        let cal = utc
        return cal.date(
            byAdding: .hour, value: 12,
            to: cal.startOfDay(for: now.addingTimeInterval(-40 * 86_400))
        )!
    }

    /// One final `type: assistant` line of a sub-agent-free chat.
    private func record(at date: Date) -> String {
        """
        {"parentUuid":"4c1d7e2a-9b3f-4e8a-b6d0-1f2e3a4b5c6d","isSidechain":false,\
        "message":{"model":"claude-sonnet-4-5","id":"msg_01RekeyA0000000000000000","type":"message",\
        "role":"assistant","content":[{"type":"text","text":"…"}],"container":null,\
        "stop_reason":"end_turn","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,\
        "cache_creation_input_tokens":16805,"cache_read_input_tokens":0,\
        "output_tokens":208,"output_tokens_details":{"thinking_tokens":43},"service_tier":"standard",\
        "cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":16805},\
        "inference_geo":"not_available"},"input_transformations":[],"diagnostics":null,\
        "context_management":null},"apiBlockIndex":0,"requestId":"req_011CfTestRequest0000000000",\
        "type":"assistant","uuid":"8e2f4a6c-1b3d-4f5e-a7c9-0d2e4f6a8b1c",\
        "timestamp":"\(Self.iso.string(from: date))","effort":"xhigh","perTurnEffort":"xhigh",\
        "userType":"external","entrypoint":"cli","cwd":"~/Projects/alpha",\
        "sessionId":"\(sessionID)","version":"2.1.280","gitBranch":"main",\
        "slug":"lovely-questing-crown"}
        """
    }

    /// Folds the turn with a UTC calendar and saves the cache — the way a run in UTC
    /// leaves it for the next launch.
    private func saveInUTC() async throws {
        let dir = root.appendingPathComponent(alphaSlug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (record(at: turnAt) + "\n")
            .write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)

        let first = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: utc)
        await first.refresh()
        await first.flushCache()
        let saved = await first.breakdown().daily.map(\.day)
        XCTAssertEqual(saved, [utc.startOfDay(for: turnAt)], "precondition: saved under UTC's midnight")
    }

    func testAFoldedDayIsFiledUnderItsDateAfterARelaunchInAnotherZone() async throws {
        try await saveInUTC()
        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: plus3)
        await relaunched.refresh()

        let parsed = await relaunched.filesParsedInLastScan
        XCTAssertEqual(parsed, 0, "the day comes from the cache, not from reading the transcript again")
        let days = await relaunched.breakdown().daily.map(\.day)
        XCTAssertEqual(days, [plus3.startOfDay(for: turnAt)])
    }

    func testAChatDayIsInsideTheRangeThatAsksForItsDateAfterARelaunchInAnotherZone() async throws {
        try await saveInUTC()
        let relaunched = JSONLAggregator(rootURL: root, cacheURL: cacheURL, saveInterval: 0, calendar: plus3)
        await relaunched.refresh()

        let chats = await relaunched.sessions(from: turnAt, to: turnAt)
        XCTAssertEqual(chats.map(\.id), [sessionID])
        XCTAssertEqual(chats.first?.days.map(\.day), [plus3.startOfDay(for: turnAt)])
        XCTAssertEqual(chats.first?.turns, 1)
    }

    func testTheRuleKeepsTheDateTheSavedMidnightNamed() {
        let utcMidnight = Date(timeIntervalSince1970: 1_787_788_800)    // 2026-08-27 00:00 UTC
        let plus3Midnight = Date(timeIntervalSince1970: 1_787_778_000)  // 2026-08-27 00:00 +03:00
        let minus5Midnight = Date(timeIntervalSince1970: 1_787_806_800) // 2026-08-27 00:00 -05:00

        XCTAssertEqual(DayRekey.midpoint(utcMidnight, calendar: plus3), plus3Midnight)
        XCTAssertEqual(
            DayRekey.midpoint(utcMidnight, calendar: Self.calendar(secondsFromGMT: -5 * 3600)),
            minus5Midnight
        )
        XCTAssertEqual(DayRekey.midpoint(plus3Midnight, calendar: utc), utcMidnight)
        XCTAssertEqual(DayRekey.midpoint(utcMidnight, calendar: utc), utcMidnight, "a day saved in this zone stays put")
    }
}
