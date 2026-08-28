import XCTest
@testable import Omelette

/// Fixture logs mimic what the Grok CLI writes to
/// `~/.grok/sessions/<percent-encoded-cwd>/<session-uuid>/updates.jsonl`.
///
/// Dollars are asserted against `costUsdTicks`, the CLI's own figure, so nothing here
/// depends on a price table or on the network: `ModelsDevPricing` never runs in this
/// target, which is also why the un-ticked turn below must come out at $0.
final class GrokUsageAggregatorTests: XCTestCase {
    private var root: URL!
    private let now = Date()

    /// Deliberately outside the tester's home directory: `ProjectName` strips a home
    /// prefix, and a fixture whose display name moved with whoever ran the suite
    /// would be untestable.
    private let alphaDir = "%2Ftmp%2FGrok%20Fixtures%2Falpha%20app"
    private let betaDir = "%2Ftmp%2FGrok%20Fixtures%2Fbeta"
    private let alphaName = "Grok Fixtures / alpha app"
    private let betaName = "Grok Fixtures / beta"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrokUsageAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture writing

    private struct ModelFixture {
        let model: String
        let input: Int
        let output: Int
        let cachedRead: Int
        let ticks: Int?

        init(_ model: String, input: Int, output: Int, cachedRead: Int = 0, ticks: Int?) {
            self.model = model
            self.input = input
            self.output = output
            self.cachedRead = cachedRead
            self.ticks = ticks
        }

        var counters: String {
            var s = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(input + output),"
            s += "\"cachedReadTokens\":\(cachedRead),\"cacheCreationTokens\":0,\"reasoningTokens\":0,"
            s += "\"modelCalls\":1,\"apiDurationMs\":100"
            if let ticks { s += ",\"costUsdTicks\":\(ticks)" }
            return s
        }

        var json: String { "\"\(model)\":{\(counters)}" }
    }

    private func turnLine(
        eventID: String,
        secondsAgo: Double,
        ticks: Int?,
        models: [ModelFixture],
        session: String = "01a04037-5a18-7133-b080-1d52b67ec4a3"
    ) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        let input = models.reduce(0) { $0 + $1.input }
        let output = models.reduce(0) { $0 + $1.output }
        let cached = models.reduce(0) { $0 + $1.cachedRead }
        var usage = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(input + output),"
        usage += "\"cachedReadTokens\":\(cached),\"cacheCreationTokens\":0,\"reasoningTokens\":0,"
        usage += "\"modelCalls\":\(models.count),\"apiDurationMs\":100"
        if let ticks { usage += ",\"costUsdTicks\":\(ticks)" }
        usage += ",\"modelUsage\":{\(models.map(\.json).joined(separator: ","))},\"numTurns\":1"
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"\(session)",\
        "update":{"sessionUpdate":"turn_completed","prompt_id":"p","stop_reason":"end_turn",\
        "usage":{\(usage)}},"_meta":{"eventId":"\(eventID)","agentTimestampMs":\(ts * 1000)}}}
        """
    }

    /// A streamed chunk — the overwhelming majority of the log. The word
    /// "turn_completed" sits in its text on purpose: skipping these has to be decided
    /// by `sessionUpdate`, not by whether the marker appears somewhere in the line.
    private func noiseLine(secondsAgo: Double) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        return """
        {"timestamp":\(ts),"method":"session/update","params":{"sessionId":"s",\
        "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text",\
        "text":"about to log turn_completed with usage"}},"_meta":{"eventId":"noise-\(Int(secondsAgo))"}}}
        """
    }

    /// A recap event that both names `turn_completed` and restates its usage. It is the
    /// one shape that gets past the byte prefilter without being a billable turn, and
    /// counting it would bill the same tokens twice — `sessionUpdate` decides, not the
    /// presence of the word or of a `usage` block.
    private func recapLine(secondsAgo: Double) -> String {
        let ts = Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970)
        return """
        {"timestamp":\(ts),"method":"_x.ai/session/update","params":{"sessionId":"s",\
        "update":{"sessionUpdate":"session_recap","lastEvent":"turn_completed",\
        "usage":{"inputTokens":500,"outputTokens":5,"totalTokens":505,\
        "cachedReadTokens":0,"cacheCreationTokens":0,"costUsdTicks":500000000,\
        "modelUsage":{"grok-4.6-build":{"inputTokens":500,"outputTokens":5,\
        "totalTokens":505,"costUsdTicks":500000000}},"numTurns":1}},\
        "_meta":{"eventId":"recap-\(Int(secondsAgo))","agentTimestampMs":\(ts * 1000)}}}
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

    private func loaded() async -> GrokUsageAggregator {
        let aggregator = GrokUsageAggregator(rootURL: root)
        await aggregator.refresh()
        return aggregator
    }

    private func lastHour(_ aggregator: GrokUsageAggregator) async -> WindowUsage {
        await aggregator.usage(from: now.addingTimeInterval(-3600), to: now)
    }

    // MARK: - Cost

    func testCostTicksBecomeDollars() async throws {
        // The worked example from the CLI: 8790 in + 37 out on grok-4.6 = $0.017802.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 178_020_000,
            models: [ModelFixture("grok-4.6-build", input: 8790, output: 37, ticks: 178_020_000)]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.cost, 0.017802, accuracy: 1e-9)
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.tokens, 8827)
    }

    func testPerModelSplitComesFromModelUsage() async throws {
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 300_000_000,
            models: [
                ModelFixture("grok-4.6-build", input: 1_000, output: 10, ticks: 200_000_000),
                ModelFixture("grok-4.3", input: 500, output: 5, ticks: 100_000_000),
            ]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.models.map { $0.model }, ["Grok 4.6", "Grok 4.3"])
        XCTAssertEqual(usage.models[0].cost, 0.02, accuracy: 1e-9)
        XCTAssertEqual(usage.models[0].tokens, 1_010)
        XCTAssertEqual(usage.models[1].cost, 0.01, accuracy: 1e-9)
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
        // One prompt, two models — one turn, not two.
        XCTAssertEqual(usage.turns, 1)
    }

    func testAModelRowWithoutTicksInheritsTheTurnTotal() async throws {
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 500_000_000,
            models: [ModelFixture("grok-4.6-build", input: 1_000, output: 10, ticks: nil)]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.cost, 0.05, accuracy: 1e-9)
        XCTAssertEqual(usage.models.first?.cost ?? 0, 0.05, accuracy: 1e-9)
    }

    func testATurnWithNoTicksAnywhereStillCountsItsTokens() async throws {
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: nil,
            models: [ModelFixture("grok-4.6-build", input: 1_000, output: 10, ticks: nil)]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1, "an unpriceable turn is still activity")
        XCTAssertEqual(usage.tokens, 1_010)
        // models.dev pricing never loads in this target, so there is no rate to fall
        // back to — $0 is the honest answer, dropping the turn would not be.
        XCTAssertEqual(usage.cost, 0, accuracy: 1e-12)
    }

    // MARK: - Line selection and dedup

    func testNoiseLinesAndDuplicateEventIDsAreIgnored() async throws {
        let e1 = turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 100_000_000,
            models: [ModelFixture("grok-4.6-build", input: 100, output: 1, ticks: 100_000_000)]
        )
        try write([
            noiseLine(secondsAgo: 700),
            recapLine(secondsAgo: 650),
            e1,
            e1, // a resumed session replays its own lines; the event counts once
            turnLine(
                eventID: "e2",
                secondsAgo: 500,
                ticks: 200_000_000,
                models: [ModelFixture("grok-4.6-build", input: 200, output: 2, ticks: 200_000_000)]
            ),
        ], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2)
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
        XCTAssertEqual(usage.tokens, 303)
    }

    func testOnlyTheAppendedTailIsParsedOnASecondRefresh() async throws {
        let head = turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 100_000_000,
            models: [ModelFixture("grok-4.6-build", input: 100, output: 1, ticks: 100_000_000)]
        )
        try write([head], project: alphaDir)
        let aggregator = await loaded()

        // Byte-for-byte the same length, different event id: a re-read of the whole
        // file would count it as a third turn. An incremental parse never sees it.
        let rewrittenHead = turnLine(
            eventID: "eX",
            secondsAgo: 600,
            ticks: 100_000_000,
            models: [ModelFixture("grok-4.6-build", input: 100, output: 1, ticks: 100_000_000)]
        )
        XCTAssertEqual(rewrittenHead.utf8.count, head.utf8.count, "the rewrite must not shift any offset")
        try write([
            rewrittenHead,
            turnLine(
                eventID: "e2",
                secondsAgo: 500,
                ticks: 200_000_000,
                models: [ModelFixture("grok-4.6-build", input: 200, output: 2, ticks: 200_000_000)]
            ),
        ], project: alphaDir)
        await aggregator.refresh()

        let usage = await lastHour(aggregator)
        XCTAssertEqual(usage.turns, 2, "the rewritten head must not be parsed a second time")
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
    }

    // MARK: - Windows and projects

    func testWindowSumsOnlyTheTurnsInsideIt() async throws {
        try write([
            turnLine(
                eventID: "recent",
                secondsAgo: 600,
                ticks: 100_000_000,
                models: [ModelFixture("grok-4.6-build", input: 100, output: 1, ticks: 100_000_000)]
            ),
            turnLine(
                eventID: "old",
                secondsAgo: 3 * 3600,
                ticks: 900_000_000,
                models: [ModelFixture("grok-4.6-build", input: 900, output: 9, ticks: 900_000_000)]
            ),
        ], project: alphaDir)
        let aggregator = await loaded()

        let inside = await lastHour(aggregator)
        XCTAssertEqual(inside.turns, 1)
        XCTAssertEqual(inside.cost, 0.01, accuracy: 1e-9)

        let outside = await aggregator.usage(
            from: now.addingTimeInterval(-2 * 3600),
            to: now.addingTimeInterval(-3600)
        )
        XCTAssertTrue(outside.isEmpty)
        XCTAssertEqual(outside.cost, 0)
    }

    func testProjectNameComesFromThePercentDecodedDirectory() async throws {
        try write([turnLine(
            eventID: "a1",
            secondsAgo: 600,
            ticks: 300_000_000,
            models: [ModelFixture("grok-4.6-build", input: 300, output: 3, ticks: 300_000_000)]
        )], project: alphaDir)
        try write([turnLine(
            eventID: "b1",
            secondsAgo: 500,
            ticks: 100_000_000,
            models: [ModelFixture("grok-4.6-build", input: 100, output: 1, ticks: 100_000_000)]
        )], project: betaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.projects.map(\.displayName), [alphaName, betaName])
        XCTAssertEqual(usage.projects[0].totalCost, 0.03, accuracy: 1e-9)
        XCTAssertEqual(usage.projects[1].totalCost, 0.01, accuracy: 1e-9)
    }

    // MARK: - breakdown()

    func testBreakdownFillsTheShapeTheDashboardRenders() async throws {
        try write([turnLine(
            eventID: "a1",
            secondsAgo: 600,
            ticks: 300_000_000,
            models: [ModelFixture("grok-4.6-build", input: 300, output: 3, ticks: 300_000_000)]
        )], project: alphaDir)
        try write([turnLine(
            eventID: "b1",
            secondsAgo: 2 * 24 * 3600,
            ticks: 100_000_000,
            models: [ModelFixture("grok-4.3", input: 100, output: 1, ticks: 100_000_000)]
        )], project: betaDir)

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.weekCost, 0.04, accuracy: 1e-9)
        XCTAssertEqual(breakdown.monthCost, 0.04, accuracy: 1e-9)
        XCTAssertEqual(breakdown.todayCost, 0.03, accuracy: 1e-9)
        XCTAssertEqual(breakdown.todayTurns, 1)
        XCTAssertEqual(breakdown.byModelToday.map { $0.model }, ["Grok 4.6"])
        XCTAssertEqual(breakdown.projectsWeek.map(\.displayName), [alphaName, betaName])
        // Two calendar days, each with its own family bucket.
        XCTAssertEqual(breakdown.daily.count, 2)
        XCTAssertEqual(breakdown.daily.last?.byFamily["grok-4.6"] ?? 0, 0.03, accuracy: 1e-9)
    }

    func testWeekCostMatchesTheBreakdown() async throws {
        try write([turnLine(
            eventID: "a1",
            secondsAgo: 600,
            ticks: 250_000_000,
            models: [ModelFixture("grok-4.6-build", input: 250, output: 2, ticks: 250_000_000)]
        )], project: alphaDir)

        let aggregator = await loaded()
        let week = await aggregator.weekCost(now: now)
        let breakdown = await aggregator.breakdown()
        XCTAssertEqual(week, 0.025, accuracy: 1e-9)
        XCTAssertEqual(week, breakdown.weekCost, accuracy: 1e-9)
    }

    func testAnEmptyLogRootProducesNothing() async throws {
        let aggregator = await loaded()
        let breakdown = await aggregator.breakdown()
        let usage = await lastHour(aggregator)

        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertTrue(breakdown.projectsWeek.isEmpty)
        XCTAssertTrue(usage.isEmpty)
    }
}
