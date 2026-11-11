import XCTest
@testable import Omelette

/// Verification of spec 2026-11-10 Mistral provider § Local usage (P2): Design (Source,
/// Attribution, What the app has already counted, Token shape, Model and price, Dollars, Sessions,
/// Unknown store, Surfaces) and Decisions 1-3, on inputs the executor's own tests leave out:
/// damaged store files and journal lines, day, week and month boundaries (UTC and New York across
/// both daylight-saving changes), a relaunch after days away, a changed time zone, a rewritten or
/// vanished store, a damaged or foreign ledger, what the ledger keeps, cache-read pricing, the
/// order of the price lookup, a table that learns a model later, saturation across sessions, and
/// the gather's and the protocol's paths. Everything is a `VibeFixture` or a line shaped like one
/// under a per-test temp root; no test reads the real `~/.vibe`, Application Support or the network.
final class VibeUsageVerificationTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("unified", isDirectory: true) }
    private var ledgerURL: URL { directory.appendingPathComponent("vibe-usage-ledger-v1.json") }

    /// 2026-11-06 18:00 UTC, a Friday.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeUsageVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MistralModelPricing.update([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        MistralModelPricing.update([:])
    }

    // MARK: - Helpers

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private var utc: Calendar { calendar("UTC") }

    private func aggregator(_ calendar: Calendar, persisted: Bool = true) -> VibeUsageAggregator {
        VibeUsageAggregator(rootURL: root, ledgerURL: persisted ? ledgerURL : nil, calendar: calendar)
    }

    /// An instant in UTC, in epoch milliseconds.
    private func ms(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0, _ milli: Int = 0) -> Int64 {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day
        parts.hour = hour; parts.minute = minute; parts.second = second
        let date = utc.date(from: parts)!
        return Int64(date.timeIntervalSince1970) * 1000 + Int64(milli)
    }

    private func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private func usage(_ input: Int, cached: Int = 0, output: Int = 0) -> VibeFixture.Usage {
        VibeFixture.Usage(input: input, cached: cached, output: output)
    }

    /// A session whose journal holds one `set_envelope` per given step, in the order given.
    private func custom(
        _ id: String, model: String? = "mistral-medium-3.5", modelName: String? = "mistral-vibe-cli-latest",
        folder: String? = "/tmp/Vibe Verification/probe", steps: [(ms: Int64, usage: VibeFixture.Usage)]
    ) -> VibeFixture.Session {
        let created = (steps.map(\.ms).min() ?? 1_793_977_000_000) - 1_000
        var session = VibeFixture.Session(
            id: id, workingDirectory: folder, activeModel: model, modelName: modelName,
            createdMs: created, currentGeneration: 1, generations: [:], journals: [:]
        )
        session.generations = [1: (nil, created)]
        session.journals = [
            1: steps.enumerated().map { index, step in
                VibeFixture.envelope(session, sequence: index + 3, usage: step.usage, ms: step.ms)
            },
            2: [],
        ]
        return session
    }

    private func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    private func appendToJournal(of session: VibeFixture.Session, first: Int = 1, lines: [String]) throws {
        let journal = root.appendingPathComponent(session.id)
            .appendingPathComponent("journal/\(VibeFixture.sequenceName(first)).jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }

    private var mediumFamily: [String: MistralModelPricing.Model] {
        ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily)
    }

    private func price(_ input: Double, _ output: Double, _ cacheRead: Double) -> ModelPrice {
        ModelPrice(inputPerM: input, outputPerM: output, cacheReadPerM: cacheRead, cacheCreate5mPerM: 0, cacheCreate1hPerM: 0)
    }

    // MARK: - The store reader

    func testLinesThatAreNotStepsAreSkippedAndTheStepsAroundThemStillCount() {
        let s = VibeFixture.repeated()
        let first = VibeFixture.envelope(s, sequence: 7, usage: usage(6_930, cached: 3_072, output: 67), ms: 1_793_977_627_409)
        let last = VibeFixture.envelope(s, sequence: 20, usage: usage(9_000, cached: 3_072, output: 80), ms: 1_793_977_700_000)
        let notJSON = #"{"type":"projection_delta","payload":{"delta":[{"op":"set_envelope"}  <- damaged"#
        let topLevelArray = #"[{"op":"set_envelope"}]"#
        let deltaNotAnArray = #"{"type":"projection_delta","payload":{"delta":"set_envelope"}}"#
        let noState = #"{"type":"projection_delta","payload":{"delta":[{"op":"set_envelope"}]}}"#
        let wrongRecord = #"{"type":"core_input","payload":{"delta":[{"op":"set_envelope","state":{"session":{"tokenUsage":{"inputTokens":5,"cachedInputTokens":0,"outputTokens":5,"totalTokens":10},"updatedAt":1793977627500}}}]}}"#
        let twoSteps = #"{"type":"projection_delta","payload":{"delta":[{"op":"set_envelope","state":{"session":{"tokenUsage":{"cachedInputTokens":3072,"inputTokens":7000,"outputTokens":70,"totalTokens":7070},"updatedAt":1793977650000}}},{"op":"append_entry","entry":{}},{"op":"set_envelope","state":{"session":{"tokenUsage":{"cachedInputTokens":3072,"inputTokens":8000,"outputTokens":75,"totalTokens":8075},"updatedAt":1793977660000}}}]}}"#
        // CRLF line ends, as a journal copied through a Windows tool would have.
        let text = [first, notJSON, topLevelArray, deltaNotAnArray, wrongRecord, noState, twoSteps, last].joined(separator: "\r\n") + "\r\n"
        XCTAssertEqual(
            VibeSessionStore.points(journal: Data(text.utf8)).map(\.total), [6_997, 7_070, 8_075, 9_080],
            "only projection_delta set_envelope items are steps, two in one line both count, nothing else breaks the read"
        )
    }

    func testEmptyAndDamagedFilesInASessionDirectoryLeaveWhatTheRestHolds() throws {
        let valid = VibeFixture.projectionState(VibeFixture.whole(), generation: 73, usage: usage(63_031, cached: 45_568, output: 3_101), ms: 1_793_977_736_011)
        let damages: [(String, Data)] = [
            ("empty", Data()),
            ("cut in half", Data(valid.prefix(valid.count / 2).utf8)),
            ("null", Data("null".utf8)),
            ("an array", Data("[]".utf8)),
            ("no snapshot", Data("{}".utf8)),
        ]
        for (name, bytes) in damages {
            let folder = root.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let directory = try VibeFixture.write(VibeFixture.whole(id: id(1)), under: folder)
            try bytes.write(to: directory.appendingPathComponent("generations/\(VibeFixture.sequenceName(73))/projection-state.json"))
            try Data().write(to: directory.appendingPathComponent("journal/\(VibeFixture.sequenceName(99)).jsonl"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("generations/\(VibeFixture.sequenceName(50))"), withIntermediateDirectories: true
            )
            try Data().write(to: directory.appendingPathComponent("meta.json"))
            guard case .session(let meta, let points) = VibeSessionStore.read(directory) else { return XCTFail("\(name): not read") }
            XCTAssertEqual(meta, VibeSessionStore.Meta(), "\(name): an empty meta.json names nothing")
            XCTAssertEqual(points.count, 7, "\(name): the journal's seven totals are all there is")
            XCTAssertEqual(points.last?.total, 66_132, name)
        }
    }

    func testCURRENTInEveryShapeIsEitherTheOneFormatOrSkippedWhole() throws {
        let v1 = VibeFixture.storeFormat
        let cases: [(String, VibeSessionStore.Contents?)] = [
            ("", .unknownStore(nil)),
            ("not json at all", .unknownStore(nil)),
            ("[]", .unknownStore(nil)),
            (#"{"store_format":7}"#, .unknownStore(nil)),
            (#"{"generation":"0000000000000001"}"#, .unknownStore(nil)),
            (#"{"store_format":"mistral.vibe.unified-session-store/v2"}"#, .unknownStore("mistral.vibe.unified-session-store/v2")),
            (#"{"store_format":"mistral.vibe.unified-session-store/V1"}"#, .unknownStore("mistral.vibe.unified-session-store/V1")),
            (#"{"store_format":"\#(v1)","store_format_minor":99}"#, nil),
        ]
        for (text, expected) in cases {
            let directory = try VibeFixture.write(VibeFixture.whole(id: id(2)), under: root)
            try Data(text.utf8).write(to: directory.appendingPathComponent("CURRENT"))
            let contents = VibeSessionStore.read(directory)
            if let expected {
                XCTAssertEqual(contents, expected, text)
            } else if case .session(_, let points) = contents {
                XCTAssertEqual(points.count, 8, "a higher minor version keeps the format's name and is read")
            } else {
                XCTFail("\(text): skipped")
            }
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testACurrentNamingAGenerationThatIsNotThereStillReadsWhatIsOnDisk() throws {
        var session = VibeFixture.whole()
        session.currentGeneration = 500
        let directory = try VibeFixture.write(session, under: root)
        guard case .session(_, let points) = VibeSessionStore.read(directory) else { return XCTFail("not read") }
        XCTAssertEqual(points.count, 8, "generation 73 and seven journal totals")
        XCTAssertEqual(points.last?.total, 66_132)
    }

    func testCountersOfOddTypesNeverTrapAndNeverShrinkAGoodTotal() {
        func line(_ tokenUsage: String) -> Data {
            Data(#"{"type":"projection_delta","payload":{"delta":[{"op":"set_envelope","state":{"session":{"tokenUsage":\#(tokenUsage),"updatedAt":1793977627500}}}]}}"#.utf8)
        }
        let cases = [
            #"{"inputTokens":"5000","outputTokens":10}"#,
            #"{"inputTokens":1500.0,"outputTokens":10}"#,
            #"{"inputTokens":1500.7,"outputTokens":10.9,"cachedInputTokens":2.5}"#,
            #"{"inputTokens":null,"outputTokens":10}"#,
            #"{"inputTokens":5}"#,
            #"{"inputTokens":-1e30,"outputTokens":-4}"#,
            #"{"inputTokens":9223372036854775807,"outputTokens":9223372036854775807,"cachedInputTokens":9223372036854775807}"#,
            #"[1,2,3]"#,
            #""tokens""#,
        ]
        for tokenUsage in cases {
            for point in VibeSessionStore.points(journalLine: line(tokenUsage)) {
                XCTAssertGreaterThanOrEqual(min(point.input, point.cached, point.output), 0, tokenUsage)
            }
        }
        XCTAssertEqual(
            VibeSessionStore.points(journalLine: line(#"{"inputTokens":1e30,"outputTokens":10}"#)).map(\.total), [Int.max],
            "a counter past Int.max reads as the biggest Int, summed without a trap"
        )
        XCTAssertEqual(
            VibeSessionStore.points(journalLine: line(#"{"inputTokens":9223372036854775807,"outputTokens":9223372036854775807}"#)).map(\.total),
            [Int.max]
        )
    }

    func testAnOperationThatIsNotSetEnvelopeNeverMakesAStepEvenWhenItCarriesATokenUsage() {
        let carrying = #"{"type":"projection_delta","payload":{"delta":[{"op":"replace_state","state":{"session":{"tokenUsage":{"cachedInputTokens":0,"inputTokens":9000,"outputTokens":10,"totalTokens":9010},"updatedAt":1793977627500}}},{"op":"set_envelope","state":{"session":{"tokenUsage":{"cachedInputTokens":0,"inputTokens":100,"outputTokens":5,"totalTokens":105},"updatedAt":1793977627600}}}]}}"#
        XCTAssertEqual(VibeSessionStore.points(journalLine: Data(carrying.utf8)).map(\.total), [105], "only the set_envelope item is a step")
    }

    // MARK: - Attribution to a moment

    func testAStepAtMidnightBelongsToTheNewDayAndOneMillisecondBeforeToTheOld() async throws {
        try VibeFixture.write(custom(id(3), steps: [
            (ms(2026, 11, 6, 23, 59, 59, 999), usage(1_000)),
            (ms(2026, 11, 7, 0, 0, 0, 0), usage(3_000)),
        ]), under: root)
        let vibe = aggregator(utc, persisted: false)
        let midnight = date(ms(2026, 11, 7))
        await vibe.refresh(now: midnight)
        let b = await vibe.breakdown(now: midnight)
        XCTAssertEqual(b.daily.map(\.day), [date(ms(2026, 11, 6)), midnight])
        XCTAssertEqual(b.daily.map(\.totalTokens), [1_000, 2_000], "the instant of midnight is the new day's")
        XCTAssertEqual(b.todayTokens, 2_000, "today starts at, and includes, midnight")
    }

    func testDaysFollowTheLocalCalendarAcrossTheFallBackAndTheSpringForward() async throws {
        let newYork = calendar("America/New_York")
        // Clocks fell back on 1 November 2026 at 06:00 UTC: that day in New York is 25 hours long.
        try VibeFixture.write(custom(id(4), steps: [
            (ms(2026, 11, 1, 3, 59, 59), usage(1_000)),   // 31 October 23:59:59 EDT
            (ms(2026, 11, 2, 4, 59, 59), usage(2_000)),   // 1 November 23:59:59 EST: the 25th hour
            (ms(2026, 11, 2, 5, 0, 0), usage(3_000)),     // 2 November 00:00 EST
        ]), under: root)
        // Clocks sprang forward on 8 March 2026 at 07:00 UTC: that day is 23 hours long.
        try VibeFixture.write(custom(id(5), steps: [
            (ms(2026, 3, 9, 3, 59, 59), usage(4_000)),    // 8 March 23:59:59 EDT
            (ms(2026, 3, 9, 4, 0, 0), usage(9_000)),      // 9 March 00:00 EDT
        ]), under: root)
        let vibe = aggregator(newYork, persisted: false)
        let later = date(ms(2026, 11, 3, 12))
        await vibe.refresh(now: later)
        let b = await vibe.breakdown(now: later)
        let expectedDays = [
            date(ms(2026, 3, 8, 5)), date(ms(2026, 3, 9, 4)),
            date(ms(2026, 10, 31, 4)), date(ms(2026, 11, 1, 4)), date(ms(2026, 11, 2, 5)),
        ]
        XCTAssertEqual(b.daily.map(\.day), expectedDays, "midnights of New York, not multiples of 24 hours")
        XCTAssertEqual(b.daily.map(\.totalTokens), [4_000, 5_000, 1_000, 1_000, 1_000])
    }

    func testTheWeekAndTheMonthIncludeTheirExactInstantAndNotAMillisecondBefore() async throws {
        let week = ms(2026, 10, 30, 18)    // now - 7 days
        let month = ms(2026, 10, 7, 18)    // now - 30 days
        for (n, step) in [(10, (week, 1_000)), (11, (week - 1, 2_000)), (12, (month, 10_000)), (13, (month - 1, 20_000))] {
            try VibeFixture.write(custom(id(n), steps: [(step.0, usage(step.1))]), under: root)
        }
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.projectsWeek.map(\.totalTokens), [1_000], "exactly seven days back is in the week")
        XCTAssertEqual(b.projectsMonth.map(\.totalTokens), [13_000], "1 000 + 2 000 + 10 000: exactly thirty days back is in the month")
        let window = await vibe.usage(from: date(week), to: date(week))
        XCTAssertEqual(window.tokens, 1_000, "a window's two ends are both inside it")
    }

    func testAnAppAwayForDaysPutsEachStepOnItsOwnDayNotOnTheDayItReadThem() async throws {
        let session = VibeFixture.whole()
        try VibeFixture.write(session, under: root)
        await aggregator(utc).refresh(now: now)
        try appendToJournal(of: session, lines: [
            VibeFixture.envelope(session, sequence: 90, usage: usage(66_931, cached: 49_152, output: 3_201), ms: ms(2026, 11, 7, 10)),
            VibeFixture.envelope(session, sequence: 91, usage: usage(76_931, cached: 49_152, output: 3_201), ms: ms(2026, 11, 8, 10)),
        ])
        let relaunched = aggregator(utc)
        let back = date(ms(2026, 11, 9, 12))
        await relaunched.refresh(now: back)
        let b = await relaunched.breakdown(now: back)
        XCTAssertEqual(b.daily.map(\.day), [date(ms(2026, 11, 6)), date(ms(2026, 11, 7)), date(ms(2026, 11, 8))])
        XCTAssertEqual(b.daily.map(\.totalTokens), [66_132, 4_000, 10_000])
        XCTAssertEqual(b.todayTokens, 0, "nothing happened on the day the app came back")
        XCTAssertEqual(b.daily.map(\.turns), [6, 1, 1])
    }

    func testAChangedTimeZoneBetweenRunsMovesTheDaysAndKeepsEveryToken() async throws {
        try VibeFixture.write(VibeFixture.midnight(), under: root)
        let eucla = calendar("Australia/Eucla")
        let first = aggregator(eucla)
        await first.refresh(now: now)
        let inEucla = await first.breakdown(now: now)
        XCTAssertEqual(inEucla.daily.map(\.totalTokens), [1_623_625, 6_822_727])
        let moved = aggregator(utc)
        await moved.refresh(now: now)
        let b = await moved.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [date(ms(2026, 11, 6))])
        XCTAssertEqual(b.daily.map(\.totalTokens), [8_446_352], "the same 1 623 625 + 6 822 727, now on one day")
        XCTAssertEqual(b.daily.map(\.turns), [4])
        let back = aggregator(eucla)
        await back.refresh(now: now)
        let again = await back.breakdown(now: now)
        XCTAssertEqual(again.daily.map(\.totalTokens), [1_623_625, 6_822_727], "and back")
    }

    func testStepsWithBackwardsClocksAreOrderedByTimeAndTheirTotalNeverExceedsTheHighest() async throws {
        let at = ms(2026, 11, 6, 12)
        try VibeFixture.write(custom(id(6), steps: [
            (at + 60_000, usage(100)),      // written first, stamped second
            (at, usage(50)),                // stamped earlier
            (at + 120_000, usage(300)),
        ]), under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 300, "50, then 50 more, then 200 more: the highest total, once")
        XCTAssertEqual(b.todayTurns, 3)
    }

    // MARK: - What the app has already counted

    func testAStoreRewrittenLowerCountsNothingUntilItPassesTheOldMarkAndThenOnlyTheRise() async throws {
        let session = VibeFixture.whole()
        try VibeFixture.write(session, under: root)
        await aggregator(utc).refresh(now: now)

        // vibe recreates the session from scratch: a lower total at a later time.
        try FileManager.default.removeItem(at: root.appendingPathComponent(session.id))
        let rewritten = custom(session.id, steps: [(ms(2026, 11, 6, 16), usage(20_000, cached: 10_000, output: 1_000))])
        try VibeFixture.write(rewritten, under: root)
        let relaunched = aggregator(utc)
        await relaunched.refresh(now: now.addingTimeInterval(60))
        var b = await relaunched.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 66_132, "a lower total attributes nothing and does not lower the mark")
        XCTAssertEqual(b.todayTurns, 6)

        // It grows past the old mark (63 031 / 45 568 / 3 101): only the part above it is new.
        try appendToJournal(of: rewritten, lines: [
            VibeFixture.envelope(rewritten, sequence: 10, usage: usage(70_000, cached: 50_000, output: 4_000), ms: ms(2026, 11, 6, 17)),
        ])
        await relaunched.refresh(now: now.addingTimeInterval(120))
        b = await relaunched.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 74_000, "66 132 and the 7 868 by which 74 000 passes it")
        XCTAssertEqual(b.todayTurns, 7)
        XCTAssertEqual(b.todayTokenBreakdown.cacheRead, 50_000, "cached 45 568 then 4 432 more")
    }

    func testASessionDirectoryThatDisappearsKeepsWhatWasCountedAndListedAcrossRelaunches() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        try VibeFixture.write(VibeFixture.medium(), under: root)
        let vibe = aggregator(utc)
        await vibe.refresh(now: now)
        try FileManager.default.removeItem(at: root.appendingPathComponent(VibeFixture.whole().id))
        await vibe.refresh(now: now.addingTimeInterval(60))
        var b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 73_197, "66 132 + 7 065: spent tokens do not leave with their folder")
        let relaunched = aggregator(utc)
        await relaunched.refresh(now: now.addingTimeInterval(86_400))
        b = await relaunched.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.totalTokens), [73_197])
        let chats = await relaunched.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(Set(chats.map(\.id)), [VibeFixture.whole().id, VibeFixture.medium().id])
    }

    func testALedgerThatCannotBeReadIsRebuiltFromTheLogsAndReplacedByAReadableOne() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        await aggregator(utc).refresh(now: now)
        let good = try Data(contentsOf: ledgerURL)
        let damages: [(String, Data)] = [
            ("empty", Data()),
            ("garbage", Data("not a ledger".utf8)),
            ("truncated", good.prefix(good.count / 2)),
            ("an array", Data("[]".utf8)),
            ("null", Data("null".utf8)),
            ("no version", Data(#"{"sessions":{}}"#.utf8)),
        ]
        for (name, bytes) in damages {
            try bytes.write(to: ledgerURL)
            let vibe = aggregator(utc)
            await vibe.refresh(now: now)
            let b = await vibe.breakdown(now: now)
            XCTAssertEqual(b.todayTokens, 66_132, "\(name): rebuilt from the logs")
            XCTAssertEqual(b.todayTurns, 6, name)
            let saved = try JSONDecoder().decode(VibeLedger.self, from: Data(contentsOf: ledgerURL))
            XCTAssertEqual(saved.version, VibeLedger.currentVersion, "\(name): the damaged file is replaced")
        }
        // The replaced ledger alone, with the logs gone, still knows the day.
        try FileManager.default.removeItem(at: root.appendingPathComponent(VibeFixture.whole().id))
        let relaunched = aggregator(utc)
        await relaunched.refresh(now: now.addingTimeInterval(3_600))
        let b = await relaunched.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 66_132)
    }

    func testTheLedgerKeepsCountsAndTheModelButNoMessageTextOrUserName() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        try VibeFixture.write(VibeFixture.pruned(), under: root)
        await aggregator(utc).refresh(now: now)
        let text = try String(contentsOf: ledgerURL, encoding: .utf8)
        for canary in ["Fixture reasoning", "Fixture output", "\"username\"", "fixture\""] {
            XCTAssertFalse(text.contains(canary), "the ledger holds no \(canary)")
        }
        XCTAssertFalse(text.contains("set_envelope"), "no journal record is copied")
        let saved = try JSONDecoder().decode(VibeLedger.self, from: Data(text.utf8))
        XCTAssertEqual(saved.version, VibeLedger.currentVersion)
        XCTAssertEqual(saved.sessions.count, 2)
        XCTAssertEqual(saved.sessions[VibeFixture.whole().id]?.counted, VibeLedger.Counters(input: 63_031, cached: 45_568, output: 3_101))
        XCTAssertEqual(saved.sessions[VibeFixture.pruned().id]?.steps.count, 2, "the first point and the rise to 797 997")
    }

    func testASessionVibeRenamesIsListedUnderItsNewTitleWithTheSameTokens() async throws {
        var session = VibeFixture.whole()
        session.title = "First name"
        try VibeFixture.write(session, under: root)
        let vibe = aggregator(utc)
        await vibe.refresh(now: now)
        session.title = "A longer second name"
        try VibeFixture.write(session, under: root)
        await vibe.refresh(now: now.addingTimeInterval(60))
        let chats = await vibe.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(chats.map(\.title), ["A longer second name"])
        XCTAssertEqual(chats.first?.tokens.total, 66_132)
        XCTAssertEqual(chats.first?.turns, 6)
    }

    func testAStoreOfAnUnknownFormatIsReadAtOnceWhenItBecomesTheKnownOne() async throws {
        var future = VibeFixture.whole()
        future.format = "mistral.vibe.unified-session-store/v2"
        let directory = try VibeFixture.write(future, under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        var skipped = await vibe.lastSkippedCount
        XCTAssertEqual(skipped, 1)
        try Data((VibeFixture.current(VibeFixture.whole()) + " ").utf8).write(to: directory.appendingPathComponent("CURRENT"))
        await vibe.refresh(now: now.addingTimeInterval(60))
        skipped = await vibe.lastSkippedCount
        XCTAssertEqual(skipped, 0)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 66_132)
    }

    func testAMissingStoreFolderOrStrayFilesInItAreNoSessions() async throws {
        let vibe = VibeUsageAggregator(rootURL: directory.appendingPathComponent("nowhere"), ledgerURL: nil, calendar: utc)
        await vibe.refresh(now: now)
        var b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 0)
        XCTAssertTrue(b.daily.isEmpty)
        try Data("x".utf8).write(to: root.appendingPathComponent("stray.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty-folder"), withIntermediateDirectories: true)
        try VibeFixture.write(VibeFixture.medium(), under: root)
        let populated = aggregator(utc, persisted: false)
        await populated.refresh(now: now)
        b = await populated.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 7_065)
        let chats = await populated.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(chats.count, 1)
    }

    func testTheWeekTheProviderPollsIsTheSameSevenDaysTheTileShows() async throws {
        MistralModelPricing.update(mediumFamily)
        let sevenDays = ms(2026, 10, 30, 18)
        for (n, at) in [(14, sevenDays + 12 * 3_600_000), (15, sevenDays), (16, sevenDays - 1)] {
            try VibeFixture.write(custom(id(n), steps: [(at, usage(1_000_000))]), under: root)
        }
        let vibe = aggregator(utc, persisted: false)
        let polled = await vibe.refreshedWeekCost(now: now)
        XCTAssertEqual(polled, 3.0, accuracy: 1e-9, "6.5 days ago and exactly 7 days ago count at $1.50 each, a millisecond older does not")
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.weekCost, polled, accuracy: 1e-9, "the provider and the tile read one week")
        let direct = await vibe.weekCost(now: now)
        XCTAssertEqual(direct, polled, accuracy: 1e-9)
    }

    func testAStepKeepsItsDayForAYearAndAHalfDayAndIsForgottenPastIt() async throws {
        // The other CLIs' History reaches back 365 days and keeps a day's last hours: 366 here.
        let kept = ms(2025, 11, 6, 6)       // 365.5 days before `now`
        let forgotten = ms(2025, 11, 4, 18) // 367 days before `now`
        try VibeFixture.write(custom(id(18), steps: [(kept, usage(1_000))]), under: root)
        try VibeFixture.write(custom(id(19), steps: [(forgotten, usage(2_000))]), under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [date(ms(2025, 11, 6))])
        XCTAssertEqual(b.daily.map(\.totalTokens), [1_000])
    }

    func testASessionLastTouchedElevenMonthsAgoIsStillReadAndKeepsItsDay() async throws {
        let at = ms(2025, 11, 22, 12)   // about 350 days before `now`
        let directory = try VibeFixture.write(custom(id(17), steps: [(at, usage(5_000))]), under: root)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: date(at)], ofItemAtPath: file.path)
        }
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [date(ms(2025, 11, 22))], "History's year reaches back this far")
        XCTAssertEqual(b.daily.map(\.totalTokens), [5_000])
    }

    // MARK: - Token shape and prices

    func testCachedTokensAreCountedOnceAndPricedAtTheCacheReadRate() async throws {
        MistralModelPricing.update(mediumFamily)
        try VibeFixture.write(custom(id(20), steps: [(ms(2026, 11, 6, 12), usage(1_000_000, cached: 1_000_000))]), under: root)
        try VibeFixture.write(custom(id(21), steps: [(ms(2026, 11, 6, 13), usage(2_000_000, cached: 500_000, output: 100_000))]), under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let chats = await vibe.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        let allCached = try XCTUnwrap(chats.first { $0.id == id(20) })
        XCTAssertEqual(allCached.tokens.total, 1_000_000, "vibe's total is input + output: the cached part is inside input")
        XCTAssertEqual(allCached.tokens.input, 0)
        XCTAssertEqual(allCached.tokens.cacheRead, 1_000_000)
        XCTAssertEqual(try XCTUnwrap(allCached.tokens.cost).total, 0.15, accuracy: 1e-9, "1M cached at $0.15, nothing at the full input rate")
        let mixed = try XCTUnwrap(chats.first { $0.id == id(21) })
        XCTAssertEqual(mixed.tokens.total, 2_100_000)
        XCTAssertEqual(try XCTUnwrap(mixed.tokens.cost).total, 3.075, accuracy: 1e-9, "1.5M fresh at $1.50, 0.5M cached at $0.15, 0.1M out at $7.50")
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 3.225, accuracy: 1e-9)
        XCTAssertEqual(b.todayTokens, 3_100_000)
    }

    func testATableThatLearnsAModelLaterPricesTheDaysAlreadyCounted() async throws {
        try VibeFixture.write(VibeFixture.medium(), under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        var b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 0, "models.dev has not answered yet: tokens, no dollars")
        XCTAssertNil(b.todayTokenBreakdown.cost)
        MistralModelPricing.update(mediumFamily)
        b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 0.006_505_5, accuracy: 1e-12)
        let week = await vibe.weekCost(now: now)
        XCTAssertEqual(week, 0.006_505_5, accuracy: 1e-12)
    }

    func testASessionWithNoMetaIsCountedWithoutDollarsAndKeptOutOfTheModelRows() async throws {
        MistralModelPricing.update(mediumFamily)
        let directory = try VibeFixture.write(VibeFixture.medium(), under: root)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("meta.json"))
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 7_065)
        XCTAssertEqual(b.todayCost, 0)
        XCTAssertTrue(b.byModelToday.isEmpty, "no model is named")
        let chats = await vibe.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(chats.count, 1)
        XCTAssertNil(chats.first?.title)
        XCTAssertNil(chats.first?.tokens.cost)
    }

    func testASessionWhoseTotalIsZeroIsNotListedAndAddsNoTurn() async throws {
        try VibeFixture.write(custom(id(30), steps: [(ms(2026, 11, 6, 12), usage(0)), (ms(2026, 11, 6, 13), usage(0))]), under: root)
        try VibeFixture.write(VibeFixture.medium(), under: root)
        let vibe = aggregator(utc, persisted: false)
        await vibe.refresh(now: now)
        let chats = await vibe.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(chats.map(\.id), [VibeFixture.medium().id])
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTurns, 1)
    }

    func testTheActiveModelIsTriedBeforeTheIDVibeSentWhenBothAreKeysAndAnEmptyOneIsSkipped() {
        let alpha = price(1, 2, 0.1), beta = price(3, 4, 0.3)
        MistralModelPricing.update([
            "alpha-1": MistralModelPricing.Model(price: alpha, name: "Alpha One"),
            "beta-1": MistralModelPricing.Model(price: beta, name: "Beta One"),
        ])
        XCTAssertEqual(MistralModelPricing.price(activeModel: "alpha-1", modelName: "beta-1"), alpha)
        XCTAssertEqual(MistralModelPricing.price(activeModel: "beta-1", modelName: "alpha-1"), beta)
        XCTAssertEqual(MistralModelPricing.price(activeModel: "unlisted", modelName: "beta-1"), beta)
        XCTAssertEqual(MistralModelPricing.price(activeModel: "", modelName: "beta-1"), beta)
        XCTAssertEqual(MistralModelPricing.price(activeModel: "alpha-1", modelName: nil), alpha)
    }

    func testADisplayNameMatchIsTriedBeforeAShorterLineOfTheSameID() {
        let named = price(1, 2, 0.1), shorter = price(3, 4, 0.3)
        MistralModelPricing.update([
            "foo-2604": MistralModelPricing.Model(price: named, name: "Foo 2"),
            "foo": MistralModelPricing.Model(price: shorter, name: "Foo"),
        ])
        XCTAssertEqual(MistralModelPricing.price(activeModel: "foo-2", modelName: nil), named, "the name Foo 2 is the exact answer, the line foo a guess")
    }

    func testTheIDVibeSentIsMatchedByNameAndByShorterLineToo() {
        let alpha = price(1, 2, 0.1), beta = price(3, 4, 0.3)
        MistralModelPricing.update([
            "gamma-1": MistralModelPricing.Model(price: alpha, name: "Gamma Pro"),
            "beta": MistralModelPricing.Model(price: beta, name: "Beta"),
        ])
        XCTAssertEqual(MistralModelPricing.price(activeModel: "nothing", modelName: "gamma-pro"), alpha, "model_name read as a display name")
        XCTAssertEqual(MistralModelPricing.price(activeModel: "nothing", modelName: "beta-9"), beta, "model_name less its last part")
        XCTAssertEqual(MistralModelPricing.price(activeModel: "beta-9-9-9", modelName: nil), beta, "three parts dropped at most")
        XCTAssertNil(MistralModelPricing.price(activeModel: "beta-9-9-9-9", modelName: nil), "a fourth is one guess too many, as for the other CLIs")
    }

    // MARK: - Saturation across sessions

    func testTwoSessionsNearIntMaxSaturateInEveryFigureAndDoNotTrap() async throws {
        MistralModelPricing.update(mediumFamily)
        let big = usage(Int.max - 10, output: 100)
        try VibeFixture.write(custom(id(40), steps: [(ms(2026, 11, 6, 12), big)]), under: root)
        try VibeFixture.write(custom(id(41), steps: [(ms(2026, 11, 6, 13), big)]), under: root)
        let vibe = aggregator(utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, Int.max)
        XCTAssertEqual(b.todayTokenBreakdown.total, Int.max)
        XCTAssertEqual(b.daily.map(\.totalTokens), [Int.max])
        XCTAssertEqual(b.projectsWeek.map(\.totalTokens), [Int.max])
        XCTAssertEqual(b.projectsMonth.map(\.totalTokens), [Int.max])
        XCTAssertEqual(b.byModelToday.map { $0.tokens }, [Int.max])
        XCTAssertTrue(b.todayCost.isFinite)
        let window = await vibe.usage(from: date(ms(2026, 11, 6)), to: now)
        XCTAssertEqual(window.tokens, Int.max)
        XCTAssertEqual(window.breakdown.total, Int.max)
        let chats = await vibe.sessions(from: date(ms(2026, 11, 6)), to: date(ms(2026, 11, 6)))
        XCTAssertEqual(chats.map(\.tokens.total), [Int.max, Int.max])
        let relaunched = aggregator(utc)
        await relaunched.refresh(now: now.addingTimeInterval(60))
        let again = await relaunched.breakdown(now: now)
        XCTAssertEqual(again.todayTokens, Int.max, "a saturated ledger is saved and read back without a trap")
    }

    // MARK: - Reached the way the app reaches it

    func testHistoryReachesTheChatsThroughTheProtocolNotThroughItsEmptyDefault() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        let vibe: any CostLogAggregating = VibeUsageAggregator(rootURL: root, ledgerURL: nil, calendar: utc)
        await vibe.refresh()
        let chats = await vibe.sessions(from: date(ms(2026, 11, 5)), to: date(ms(2026, 11, 7)))
        XCTAssertEqual(chats.map(\.id), [VibeFixture.whole().id], "an overload that is not the protocol's requirement would answer []")
        XCTAssertEqual(chats.first?.providerID, "mistral")
        let window = await vibe.usage(from: date(ms(2026, 11, 5)), to: date(ms(2026, 11, 7)))
        XCTAssertEqual(window.tokens, 66_132)
        let breakdown = await vibe.breakdown()
        XCTAssertEqual(breakdown.daily.map(\.totalTokens), [66_132])
    }

    func testEveryAnswerMistralCanGiveCarriesTheWeeksLocalDollarsAndNeverCallsThemTheBill() {
        let answers: [(String, Result<MistralBilling, MistralBillingError>?)] = [
            ("no key", nil),
            ("401", .failure(.unauthorized)),
            ("429", .failure(.rateLimited(retryAfter: nil))),
            ("429 with a wait", .failure(.rateLimited(retryAfter: 120))),
            ("500", .failure(.badStatus(500))),
            ("offline", .failure(.transport("offline"))),
            ("undecodable", .failure(.decoding("bad body"))),
            ("403 on the budget", .success(MistralBilling(planName: "INDIVIDUAL", budget: .noUsageAccess))),
            ("404 on the budget", .success(MistralBilling(planName: "INDIVIDUAL", budget: .noBilling))),
            ("a budget with no entries", .success(MistralBilling(planName: nil, budget: .entries([])))),
        ]
        for (name, result) in answers {
            let spent = MistralProvider.snapshot(result: result, now: now, weekCost: 3.9)
            XCTAssertEqual(spent.weekCost, 3.9, name)
            XCTAssertFalse(CostCopy.isPayAsYouGo(spent), "\(name): vibe's dollars are no bill")
            XCTAssertFalse(StatusFileWriter.isPayAsYouGo(spent), name)
            XCTAssertNil(MistralProvider.snapshot(result: result, now: now, weekCost: 0).weekCost, "\(name): nothing spent is no figure")
        }
    }

    func testTheGatherLeavesMistralOutWhenTheProviderIsNotAskedFor() async {
        try? VibeFixture.write(VibeFixture.whole(), under: root)
        let off = await StatusCosts.gather(serviceIDs: [], now: now, vibe: aggregator(utc, persisted: false))
        XCTAssertNil(off.costs["mistral"])
        XCTAssertNil(off.sessions["mistral"])
        let on = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: aggregator(utc, persisted: false))
        XCTAssertEqual(on.costs["mistral"]?.todayTokens, 66_132)
    }

    func testAChatWhoseModelNobodyPricesShowsNoDollarsInTheFileNotAZero() async throws {
        try VibeFixture.write(VibeFixture.medium(), under: root)
        let gathered = await StatusCosts.gather(serviceIDs: ["mistral"], now: now, vibe: aggregator(utc, persisted: false))
        let file = StatusFileWriter.build(
            services: [MistralProvider.snapshot(result: nil, now: now)], costs: gathered.costs, sessions: gathered.sessions,
            agents: .none, now: now, calendar: utc, locale: Locale(identifier: "en_US")
        )
        let service = try XCTUnwrap(file.service(id: "mistral"))
        XCTAssertEqual(service.todayTokens, 7_065)
        let chat = try XCTUnwrap(service.sessions?.first)
        XCTAssertNil(chat.cost, "tokens without a price: no cost, not 0")
        XCTAssertEqual(chat.tokens, 7_065)
        XCTAssertEqual(StatusText.costParts(service), [], "the terminal prints no dollar figure")
        XCTAssertNil(StatusLineText.todayCostText(service), "and the status line none")
        XCTAssertEqual(file.version, 2)
    }
}
