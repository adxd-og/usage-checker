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
        // `ModelPricing.dynamicTable` is process-global; a test that seeds it must not
        // leave rates behind for the next one.
        ModelPricing.updateDynamic([:])
    }

    // MARK: - Fixture writing

    private struct ModelFixture {
        let model: String
        let input: Int
        let output: Int
        let cachedRead: Int
        let cacheCreation: Int
        let ticks: Int?

        init(
            _ model: String, input: Int, output: Int, cachedRead: Int = 0,
            cacheCreation: Int = 0, ticks: Int?
        ) {
            self.model = model
            self.input = input
            self.output = output
            self.cachedRead = cachedRead
            self.cacheCreation = cacheCreation
            self.ticks = ticks
        }

        var counters: String {
            var s = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(input + output),"
            s += "\"cachedReadTokens\":\(cachedRead),\"cacheCreationTokens\":\(cacheCreation),\"reasoningTokens\":0,"
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
        let created = models.reduce(0) { $0 + $1.cacheCreation }
        var usage = "\"inputTokens\":\(input),\"outputTokens\":\(output),\"totalTokens\":\(input + output),"
        usage += "\"cachedReadTokens\":\(cached),\"cacheCreationTokens\":\(created),\"reasoningTokens\":0,"
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
        // One second ago, not ten minutes: a "today" turn placed ten minutes back falls
        // into yesterday whenever the suite runs between 00:00 and 00:10.
        try write([turnLine(
            eventID: "a1",
            secondsAgo: 1,
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

    // MARK: - Reconciling per-model and per-turn dollars

    func testAnUnpricedSplitIsSharedByTokenCount() async throws {
        // Neither row is priced, so the turn's own total is divided by token share:
        // 1000 of 1500 tokens takes two thirds of $0.03.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 300_000_000,
            models: [
                ModelFixture("grok-4.6-build", input: 1_000, output: 0, ticks: nil),
                ModelFixture("grok-4.3", input: 500, output: 0, ticks: nil),
            ]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.models.map { $0.model }, ["Grok 4.6", "Grok 4.3"])
        XCTAssertEqual(usage.models[0].cost, 0.02, accuracy: 1e-9)
        XCTAssertEqual(usage.models[1].cost, 0.01, accuracy: 1e-9)
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
    }

    func testAPricedSplitBeatsASmallerTurnTotal() async throws {
        // The per-model figures add up to more than the turn says. They are the more
        // specific number, so they stand — the turn total does not shrink them.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 100_000_000,
            models: [
                ModelFixture("grok-4.6-build", input: 1_000, output: 0, ticks: 200_000_000),
                ModelFixture("grok-4.3", input: 500, output: 0, ticks: 100_000_000),
            ]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
        XCTAssertEqual(usage.models[0].cost, 0.02, accuracy: 1e-9)
        XCTAssertEqual(usage.models[1].cost, 0.01, accuracy: 1e-9)
    }

    func testSpendTheSplitDoesNotAccountForLandsOnTheBiggestRow() async throws {
        // The turn cost $0.04 but the per-model rows only explain $0.03. The difference
        // used to be dropped, so the turn read cheaper than the CLI's own figure.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 400_000_000,
            models: [
                ModelFixture("grok-4.6-build", input: 1_000, output: 0, ticks: 200_000_000),
                ModelFixture("grok-4.3", input: 500, output: 0, ticks: 100_000_000),
            ]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.cost, 0.04, accuracy: 1e-9, "the turn's own total is the truth")
        XCTAssertEqual(usage.models[0].model, "Grok 4.6")
        XCTAssertEqual(usage.models[0].cost, 0.03, accuracy: 1e-9)
        XCTAssertEqual(usage.models[1].cost, 0.01, accuracy: 1e-9)
        XCTAssertEqual(usage.models.count, 2, "no phantom 'unknown' model in the breakdown")
    }

    func testZeroTicksMeanUnpricedNotFree() async throws {
        // A CLI build that writes the field but leaves it at zero used to mark the row
        // priced at $0 and skip the models.dev fallback entirely — a whole session of
        // work reported as costing nothing.
        ModelPricing.updateDynamic([
            "grok-4.6": ModelPrice(
                inputPerM: 2, outputPerM: 6, cacheReadPerM: 0.5,
                cacheCreate5mPerM: 0, cacheCreate1hPerM: 0
            )
        ])
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 0,
            models: [ModelFixture("grok-4.6-build", input: 1_000_000, output: 0, ticks: 0)]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.cost, 2.0, accuracy: 1e-9, "a million input tokens at $2/M")
    }

    // MARK: - Fields the CLI doesn't always write

    /// A `turn_completed` line assembled from raw fragments, for shapes the typed
    /// builder above can't express — a missing field, an empty split.
    private func rawTurnLine(timestampField: String?, usage: String, meta: String) -> String {
        let ts = timestampField.map { "\"timestamp\":\($0)," } ?? ""
        return """
        {\(ts)"method":"_x.ai/session/update","params":{"sessionId":"s-1",\
        "update":{"sessionUpdate":"turn_completed","usage":{\(usage)}},"_meta":{\(meta)}}}
        """
    }

    func testTheAgentTimestampStandsInForAMissingOuterOne() async throws {
        let ms = Int(now.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        try write([rawTurnLine(
            timestampField: nil,
            usage: #""inputTokens":100,"outputTokens":1,"totalTokens":101,"costUsdTicks":100000000"#,
            meta: #""eventId":"m1","agentTimestampMs":\#(ms)"#
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.cost, 0.01, accuracy: 1e-9)
    }

    func testALineWithNoTimeAtAllIsDropped() async throws {
        try write([rawTurnLine(
            timestampField: nil,
            usage: #""inputTokens":100,"outputTokens":1,"totalTokens":101,"costUsdTicks":100000000"#,
            meta: #""eventId":"m1""#
        )], project: alphaDir)

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.weekCost, 0, "a turn with no time has no place in any window")
    }

    func testWithoutAnEventIdIdentityFallsBackToTheTurnsContent() async throws {
        let seconds = Int(now.addingTimeInterval(-600).timeIntervalSince1970)
        let sameContent = #""inputTokens":100,"outputTokens":1,"totalTokens":101,"costUsdTicks":100000000"#
        let otherContent = #""inputTokens":200,"outputTokens":2,"totalTokens":202,"costUsdTicks":200000000"#
        try write([
            rawTurnLine(timestampField: "\(seconds)", usage: sameContent, meta: ""),
            rawTurnLine(timestampField: "\(seconds)", usage: sameContent, meta: ""),
            rawTurnLine(timestampField: "\(seconds)", usage: otherContent, meta: ""),
        ], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.turns, 2, "identical content is one event; different content is not")
        XCTAssertEqual(usage.cost, 0.03, accuracy: 1e-9)
    }

    func testATurnWithoutAModelSplitIsBilledToAGenericGrokRow() async throws {
        let seconds = Int(now.addingTimeInterval(-600).timeIntervalSince1970)
        try write([rawTurnLine(
            timestampField: "\(seconds)",
            usage: #""inputTokens":100,"outputTokens":1,"totalTokens":101,"costUsdTicks":100000000"#,
            meta: #""eventId":"nosplit""#
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.models.map { $0.model }, ["Grok"])
        XCTAssertEqual(usage.cost, 0.01, accuracy: 1e-9)
        XCTAssertEqual(usage.tokens, 101)
    }

    func testAZeroTotalFallsBackToInputPlusOutput() async throws {
        let seconds = Int(now.addingTimeInterval(-600).timeIntervalSince1970)
        try write([rawTurnLine(
            timestampField: "\(seconds)",
            usage: #""inputTokens":100,"outputTokens":7,"totalTokens":0,"costUsdTicks":100000000"#,
            meta: #""eventId":"zerototal""#
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        XCTAssertEqual(usage.tokens, 107)
    }

    func testAnEmptyLogRootProducesNothing() async throws {
        let aggregator = await loaded()
        let breakdown = await aggregator.breakdown()
        let usage = await lastHour(aggregator)

        XCTAssertEqual(breakdown.weekCost, 0)
        XCTAssertTrue(breakdown.projectsWeek.isEmpty)
        XCTAssertTrue(usage.isEmpty)
    }

    // MARK: - Token breakdown

    func testFreshInputIsTheDifferenceAndThereAreNoCategoryDollars() async throws {
        // The CLI's `inputTokens` INCLUDES the cached read — unlike Claude's, which is
        // the uncached part already. Fresh input is the difference, or the two would
        // double-count the same context.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 178_020_000,
            models: [ModelFixture(
                "grok-4.6-build", input: 8_790, output: 37, cachedRead: 6_000,
                ticks: 178_020_000
            )]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(model.breakdown.input, 2_790)
        XCTAssertEqual(model.breakdown.cacheRead, 6_000)
        XCTAssertEqual(model.breakdown.output, 37)
        XCTAssertEqual(model.breakdown.cacheWrite, 0)
        XCTAssertEqual(model.breakdown.thinking, 0, "the CLI logs no reasoning split")
        XCTAssertNil(model.breakdown.cost, "the CLI prices a whole turn; there is no per-category rate")
        XCTAssertNil(usage.breakdown.cost)
        XCTAssertEqual(usage.breakdown.input, 2_790)
        XCTAssertEqual(usage.breakdown.cacheRead, 6_000)
        // The dollars still come from the CLI's own ticks, untouched by any of this.
        XCTAssertEqual(usage.cost, 0.017802, accuracy: 1e-9)
    }

    func testTheHeadlineTotalStaysTheCLIsEvenWhenTheSplitDisagrees() async throws {
        // `cacheCreationTokens` is reported alongside and is not inside the CLI's
        // `totalTokens`, so the split sums higher. The headline is the CLI's figure;
        // the split is the split.
        try write([turnLine(
            eventID: "e1",
            secondsAgo: 600,
            ticks: 100_000_000,
            models: [ModelFixture(
                "grok-4.6-build", input: 1_000, output: 10, cachedRead: 400,
                cacheCreation: 250, ticks: 100_000_000
            )]
        )], project: alphaDir)

        let usage = await lastHour(loaded())
        let model = try XCTUnwrap(usage.models.first)
        XCTAssertEqual(usage.tokens, 1_010, "the CLI's own totalTokens")
        XCTAssertEqual(model.tokens, 1_010)
        XCTAssertEqual(model.breakdown.input, 600)
        XCTAssertEqual(model.breakdown.cacheWrite5m, 250)
        XCTAssertEqual(model.breakdown.cacheWrite1h, 0, "the CLI reports one cache-write figure")
        XCTAssertEqual(model.breakdown.total, 1_260, "the parts, which need not match the headline")
        XCTAssertEqual(usage.breakdown.total, 1_260)
        XCTAssertEqual(usage.tokens, 1_010, "and the headline does not follow the parts")
    }

    func testTheDashboardShapeCarriesTheSplitPerModelAndPerDay() async throws {
        // One second ago, not ten minutes: a "today" turn placed ten minutes back falls
        // into yesterday whenever the suite runs between 00:00 and 00:10.
        try write([turnLine(
            eventID: "a1",
            secondsAgo: 1,
            ticks: 300_000_000,
            models: [ModelFixture(
                "grok-4.6-build", input: 300, output: 3, cachedRead: 100,
                cacheCreation: 50, ticks: 300_000_000
            )]
        )], project: alphaDir)

        let breakdown = await loaded().breakdown()
        XCTAssertEqual(breakdown.todayTokenBreakdown.input, 200)
        XCTAssertEqual(breakdown.todayTokenBreakdown.cacheRead, 100)
        XCTAssertEqual(breakdown.todayTokenBreakdown.cacheWrite, 50)
        XCTAssertEqual(breakdown.todayTokenBreakdown.output, 3)
        XCTAssertNil(breakdown.todayTokenBreakdown.cost)
        XCTAssertEqual(breakdown.todayTokens, 303, "still the CLI's totalTokens")

        let model = try XCTUnwrap(breakdown.byModelToday.first)
        XCTAssertEqual(model.model, "Grok 4.6")
        XCTAssertEqual(model.breakdown.input, 200)
        XCTAssertEqual(model.breakdown.cacheWrite, 50)
        XCTAssertNil(model.breakdown.cost)

        let day = try XCTUnwrap(breakdown.daily.last)
        XCTAssertEqual(day.tokens.input, 200)
        XCTAssertEqual(day.tokens.cacheRead, 100)
        XCTAssertEqual(day.totalTokens, 303)
        XCTAssertNil(day.tokens.cost)
    }
}
