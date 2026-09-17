import XCTest
@testable import Omelette

/// Independent verification of `GrokUsageAggregator`'s half of the year-retention
/// design: the 366-day `mtimeWindow` and the separate `dayRetention` constant. Written
/// from the spec and the diff, with its own fixtures — never the executor's test file.
///
/// Fixture shape copied from `GrokUsageAggregatorTests.swift`: a `turn_completed`
/// JSON-RPC notification under `<percent-encoded-cwd>/<session-uuid>/updates.jsonl`,
/// priced from the CLI's own `costUsdTicks` (USD x 1e10).
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Facts, § Retention, § Codex and Grok, § Tests.
final class GrokYearRetentionVerificationTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    private let alphaDir = "%2Ftmp%2FGrokRetentionVerification%2Falpha%20app"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokYearRetentionVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Fixture writing

    private struct ModelFixture {
        let model: String
        let input: Int
        let output: Int
        let ticks: Int?

        init(_ model: String, input: Int, output: Int, ticks: Int?) {
            self.model = model
            self.input = input
            self.output = output
            self.ticks = ticks
        }

        var counters: String {
            var s = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(input + output),"
            s += "\"cachedReadTokens\":0,\"cacheCreationTokens\":0,\"reasoningTokens\":0,"
            s += "\"modelCalls\":1,\"apiDurationMs\":100"
            if let ticks { s += ",\"costUsdTicks\":\(ticks)" }
            return s
        }

        var json: String { "\"\(model)\":{\(counters)}" }
    }

    private func turnLine(
        eventID: String, secondsAgo: Double, ticks: Int?, models: [ModelFixture],
        session: String = "01a04037-5a18-7133-b080-1d52b67ec4a3"
    ) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        let input = models.reduce(0) { $0 + $1.input }
        let output = models.reduce(0) { $0 + $1.output }
        var usage = "\"inputTokens\":\(input),\"outputTokens\":\(output),"
        usage += "\"totalTokens\":\(input + output),"
        usage += "\"cachedReadTokens\":0,\"cacheCreationTokens\":0,\"reasoningTokens\":0,"
        usage += "\"modelCalls\":\(models.count),\"apiDurationMs\":100"
        if let ticks { usage += ",\"costUsdTicks\":\(ticks)" }
        usage += ",\"modelUsage\":{\(models.map(\.json).joined(separator: ","))},\"numTurns\":1"
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"\(session)",\
        "update":{"sessionUpdate":"turn_completed","prompt_id":"p","stop_reason":"end_turn",\
        "usage":{\(usage)}},"_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    private func write(_ lines: [String], project: String, session: String = "session-uuid") throws {
        let dir = root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
    }

    private func updatesURL(project: String, session: String = "session-uuid") -> URL {
        root
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("updates.jsonl")
    }

    private func loaded() async -> GrokUsageAggregator {
        let aggregator = GrokUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    // MARK: - Retention: a year of day totals

    /// The session log's mtime is ~300 days old — untouched since the CLI moved on to
    /// a fresh session. `mtimeWindow` is 366 days, so the first scan must still parse
    /// it, and its day must reach `daily`.
    func testASessionLogAboutTenMonthsOldReachesTheDailyTotals() async throws {
        let old: Double = 300 * 24 * 3600
        try write([turnLine(
            eventID: "e300", secondsAgo: old, ticks: 300_000_000,
            models: [ModelFixture("grok-4.6-build", input: 1_000, output: 10, ticks: 300_000_000)]
        )], project: alphaDir)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-old)],
            ofItemAtPath: updatesURL(project: alphaDir).path
        )

        let breakdown = await loaded().breakdown()
        let expectedDay = Calendar.current.startOfDay(for: now.addingTimeInterval(-old))

        XCTAssertEqual(breakdown.daily.map(\.day), [expectedDay])
        XCTAssertEqual(breakdown.daily.first?.totalCost ?? 0, 0.03, accuracy: 1e-9, "300,000,000 ticks = $0.03")
    }

    /// The mirror case: ~400 days old, past the 366-day `mtimeWindow`. The first scan
    /// must skip it forever rather than parse and discard it, so its day never
    /// reaches `daily`.
    func testASessionLogAboutThirteenMonthsOldNeverReachesTheDailyTotals() async throws {
        let old: Double = 400 * 24 * 3600
        try write([turnLine(
            eventID: "e400", secondsAgo: old, ticks: 400_000_000,
            models: [ModelFixture("grok-4.6-build", input: 1_000, output: 10, ticks: 400_000_000)]
        )], project: alphaDir)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-old)],
            ofItemAtPath: updatesURL(project: alphaDir).path
        )

        let breakdown = await loaded().breakdown()

        XCTAssertTrue(breakdown.daily.isEmpty, "past the 366-day mtime window the log must never be parsed")
    }
}
