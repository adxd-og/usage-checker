import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Design (Source, Attribution, What the app
/// has already counted, Token shape, Model and price, Dollars, Unknown store) and Decisions 1–3;
/// plan R1, R9. Fixtures are vibe's own records (`VibeFixture`) under a per-test temp root, with
/// the ledger beside them, and models.dev's `mistral` rows as fetched (`ModelsDevMistralFixture`).
/// No test reads the real `~/.vibe` or Application Support.
final class VibeUsageAggregatorTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("unified", isDirectory: true) }
    private var ledgerURL: URL { directory.appendingPathComponent("vibe-usage-ledger-v1.json") }

    /// 2026-11-06 18:00 UTC, a Friday: every fixture session ran that afternoon.
    private let now = Date(timeIntervalSince1970: 1_793_988_000)
    /// 2026-11-06 00:00 UTC.
    private let nov6 = Date(timeIntervalSince1970: 1_793_923_200)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    /// UTC+08:45 with no daylight saving: its midnight is 15:15 UTC, inside the midnight fixture.
    private let eucla: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Eucla")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    /// 6 November 00:00 in Eucla (5 November 15:15 UTC) and 7 November 00:00 (6 November 15:15 UTC).
    private let euclaNov6 = Date(timeIntervalSince1970: 1_793_891_700)
    private let euclaNov7 = Date(timeIntervalSince1970: 1_793_978_100)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeUsageAggregatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MistralModelPricing.update([:])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        MistralModelPricing.update([:])
    }

    private func aggregator(calendar: Calendar, persisted: Bool = true) -> VibeUsageAggregator {
        VibeUsageAggregator(rootURL: root, ledgerURL: persisted ? ledgerURL : nil, calendar: calendar)
    }

    private var family: [String: MistralModelPricing.Model] {
        ModelsDevPricing.parseFamily(ModelsDevMistralFixture.root, provider: ModelsDevPricing.vibeFamily)
    }

    /// The six sessions of 6 November: whole, pruned, repeated, no total, GLM, vibe's default model.
    private func writeAll() throws {
        for session in [
            VibeFixture.whole(), VibeFixture.pruned(), VibeFixture.repeated(),
            VibeFixture.noTotal(), VibeFixture.glm(), VibeFixture.medium(),
        ] {
            try VibeFixture.write(session, under: root)
        }
    }

    /// One step more for the whole session: 66 132 → 70 132 at 15:09:00 UTC.
    private var nextStep: String {
        VibeFixture.envelope(
            VibeFixture.whole(), sequence: 85,
            usage: VibeFixture.Usage(input: 66_931, cached: 49_152, output: 3_201), ms: 1_793_977_740_000
        )
    }

    private func appendToWholesJournal(_ line: String) throws {
        let journal = root.appendingPathComponent(VibeFixture.whole().id)
            .appendingPathComponent("journal/\(VibeFixture.sequenceName(1)).jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    func testEverySessionCountsOnceAndASessionWithNoTotalAddsNothing() async throws {
        try writeAll()
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        await vibe.refresh(now: now.addingTimeInterval(30))
        let today = await vibe.breakdown(now: now)
        // whole 66 132 + pruned 797 997 + repeated 6 997 + glm 6 866 + medium 7 065 + no total 0
        XCTAssertEqual(today.todayTokens, 885_057, "whoever ran them: the fleet's sessions count too")
        XCTAssertEqual(today.todayTurns, 11, "6 + 2 + 1 + 1 + 1")
        XCTAssertEqual(today.daily.map(\.day), [nov6])
        XCTAssertEqual(today.daily.map(\.totalTokens), [885_057])
    }

    func testTheSplitIsInputLessCachedThenCachedThenOutput() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let split = await vibe.breakdown(now: now).todayTokenBreakdown
        XCTAssertEqual(split.input, 17_463, "63 031 − 45 568: input already includes the cached tokens")
        XCTAssertEqual(split.cacheRead, 45_568)
        XCTAssertEqual(split.output, 3_101)
        XCTAssertEqual(split.cacheWrite, 0)
        XCTAssertEqual(split.thinking, 0)
        XCTAssertEqual(split.total, 66_132)
    }

    func testDollarsAreModelsDevListPricesForEachSessionsModel() async throws {
        try writeAll()
        MistralModelPricing.update(family)
        let vibe = aggregator(calendar: utc)
        let polled = await vibe.refreshedWeekCost(now: now)
        // whole     17 463 × 0.70 +  45 568 × 0.07 + 3 101 × 2.10 =  21 925.96  mistral-large-4
        // pruned   123 938 × 0.70 + 667 648 × 0.07 + 6 411 × 2.10 = 146 955.06  mistral-large-4
        // repeated   3 858 × 0.70 +   3 072 × 0.07 +    67 × 2.10 =   3 056.34  mistral-large-4
        // glm          911 × 1.40 +   5 952 × 0.14 +     3 × 4.40 =   2 121.88  zai-glm-5-3
        // medium     3 827 × 1.50 +   3 200 × 0.15 +    38 × 7.50 =   6 505.50  mistral-medium-2604
        // the day                                                    180 564.74 per million
        XCTAssertEqual(polled, 0.180_564_74, accuracy: 1e-9)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 0.180_564_74, accuracy: 1e-9)
        XCTAssertEqual(b.weekCost, 0.180_564_74, accuracy: 1e-9)
        XCTAssertEqual(b.monthCost, 0.180_564_74, accuracy: 1e-9)
        let split = try XCTUnwrap(b.todayTokenBreakdown.cost, "every session with tokens is priced, so the split is too")
        XCTAssertEqual(split.total, 0.180_564_74, accuracy: 1e-9)
        XCTAssertEqual(split.cacheWrite, 0)
    }

    func testVibesDefaultModelIsPricedByItsModelsDevName() async throws {
        try VibeFixture.write(VibeFixture.medium(), under: root)
        MistralModelPricing.update(family)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 0.006_505_5, accuracy: 1e-12, "3 827 × 1.50 + 3 200 × 0.15 + 38 × 7.50 = 6 505.50 per million")
        XCTAssertEqual(b.byModelToday.map { $0.model }, ["Mistral Medium 3.5"])
    }

    func testAnAliasWithNoRowIsPricedByTheIDVibeSent() async throws {
        try VibeFixture.write(VibeFixture.glm(), under: root)
        MistralModelPricing.update(family)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayCost, 0.002_121_88, accuracy: 1e-12, "911 × 1.40 + 5 952 × 0.14 + 3 × 4.40 = 2 121.88 per million")
        XCTAssertEqual(b.byModelToday.map { $0.model }, ["Glm 5 3"], "named by vibe's alias, priced by the id it sent")
    }

    func testAModelModelsDevDoesNotPriceCountsItsTokensWithoutDollars() async throws {
        try VibeFixture.write(VibeFixture.glm(), under: root)
        var withoutGLM = family
        withoutGLM["zai-glm-5-3"] = nil
        MistralModelPricing.update(withoutGLM)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 6_866)
        XCTAssertEqual(b.todayCost, 0)
        XCTAssertNil(b.todayTokenBreakdown.cost, "no per-kind dollars to invent")
    }

    func testByModelAndByProjectRowsNameTheModelAndTheFolder() async throws {
        try writeAll()
        MistralModelPricing.update(family)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.byModelToday.map { $0.model }, ["Mistral Large 4 0 3", "Mistral Medium 3.5", "Glm 5 3"])
        XCTAssertEqual(b.byModelToday.map { $0.tokens }, [871_126, 7_065, 6_866], "66 132 + 797 997 + 6 997 for Large")
        XCTAssertEqual(b.projectsWeek.map(\.displayName), ["Vibe Fixtures / movie app", "Vibe Fixtures / probe"])
        XCTAssertEqual(b.projectsWeek.map(\.totalTokens), [797_997, 87_060], "66 132 + 6 997 + 6 866 + 7 065 in probe")
        XCTAssertEqual(b.projectsWeek.map(\.turns), [2, 9])
    }

    func testASessionCrossingMidnightSplitsBetweenTheTwoDays() async throws {
        try VibeFixture.write(VibeFixture.midnight(), under: root)
        let vibe = aggregator(calendar: eucla)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [euclaNov6, euclaNov7])
        XCTAssertEqual(b.daily.map(\.totalTokens), [1_623_625, 6_822_727], "7 295 + 1 616 330, then 197 790 + 6 624 937")
        XCTAssertEqual(b.daily.map(\.turns), [2, 2])
        XCTAssertEqual(b.daily.first?.tokens.input, 171_623)
        XCTAssertEqual(b.daily.first?.tokens.cacheRead, 1_449_024)
        XCTAssertEqual(b.daily.first?.tokens.output, 2_978)
        XCTAssertEqual(b.todayTokens, 6_822_727, "18:00 UTC is already 7 November in Eucla")
    }

    func testARelaunchAfterVibePrunedTheJournalKeepsEachDayWhereItWas() async throws {
        try VibeFixture.write(VibeFixture.midnight(), under: root)
        await aggregator(calendar: eucla).refresh(now: now)
        try FileManager.default.removeItem(at: root.appendingPathComponent(VibeFixture.midnight().id))
        try VibeFixture.write(VibeFixture.midnightPruned(), under: root)
        let relaunched = aggregator(calendar: eucla)
        await relaunched.refresh(now: now)
        let b = await relaunched.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [euclaNov6, euclaNov7])
        XCTAssertEqual(b.daily.map(\.totalTokens), [1_623_625, 6_822_727])
        XCTAssertEqual(b.daily.map(\.turns), [2, 2])
    }

    func testWithoutTheLedgerAPrunedSessionLandsWholeOnItsLastKnownDay() async throws {
        try VibeFixture.write(VibeFixture.midnightPruned(), under: root)
        let vibe = aggregator(calendar: eucla, persisted: false)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.daily.map(\.day), [euclaNov7])
        XCTAssertEqual(b.daily.map(\.totalTokens), [8_446_352])
        XCTAssertEqual(b.daily.map(\.turns), [1])
    }

    func testAStepIsCountedOnceAcrossPollsAndANewStepAddsOnlyItsRise() async throws {
        try writeAll()
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        await vibe.refresh(now: now.addingTimeInterval(30))
        try appendToWholesJournal(nextStep)
        await vibe.refresh(now: now.addingTimeInterval(60))
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 889_057, "885 057 and the new step's 4 000 (3 900 input, 100 output)")
        XCTAssertEqual(b.todayTurns, 12)
    }

    func testReadsWithinTwentySecondsShareOneRead() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        try appendToWholesJournal(nextStep)
        await vibe.refresh(now: now.addingTimeInterval(5))
        let soon = await vibe.breakdown(now: now).todayTokens
        XCTAssertEqual(soon, 66_132, "the status file's gather five seconds after the provider's poll shares its read")
        await vibe.refresh(now: now.addingTimeInterval(25))
        let later = await vibe.breakdown(now: now).todayTokens
        XCTAssertEqual(later, 70_132)
    }

    func testALedgerOfAnotherRuleVersionIsDiscardedAndRebuiltFromTheLogs() async throws {
        let directoryOfWhole = try VibeFixture.write(VibeFixture.whole(), under: root)
        let cases = [
            (VibeLedger.currentVersion, 1, "this rule's ledger is trusted"),
            (0, 66_132, "an older rule's ledger is rebuilt from the logs"),
            (VibeLedger.currentVersion + 98, 66_132, "an unknown rule's ledger is rebuilt from the logs"),
        ]
        for (version, expected, why) in cases {
            var saved = VibeLedger(version: version)
            var session = VibeLedger.Session()
            session.counted = VibeLedger.Counters(input: 63_031, cached: 45_568, output: 3_101)
            session.steps = [VibeLedger.Step(at: now, input: 1, cached: 0, output: 0)]
            session.mark = VibeSessionStore.mark(of: directoryOfWhole)
            saved.sessions[VibeFixture.whole().id] = session
            try JSONEncoder().encode(saved).write(to: ledgerURL)
            let vibe = aggregator(calendar: utc)
            await vibe.refresh(now: now)
            let tokens = await vibe.breakdown(now: now).todayTokens
            XCTAssertEqual(tokens, expected, why)
        }
    }

    func testAnUnknownStoreFormatIsSkippedWholeAndCountedOnce() async throws {
        var future = VibeFixture.whole()
        future.format = "mistral.vibe.unified-session-store/v2"
        try VibeFixture.write(future, under: root)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let skipped = await vibe.lastSkippedCount
        XCTAssertEqual(skipped, 1)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, 0)
        await vibe.refresh(now: now.addingTimeInterval(30))
        let again = await vibe.lastSkippedCount
        XCTAssertEqual(again, 0, "logged once, not at every poll")
    }

    func testTheWeekReachesBackSevenDaysAndTheMonthThirty() async throws {
        try writeAll()
        MistralModelPricing.update(family)
        let vibe = aggregator(calendar: utc)
        let eightDaysLater = now.addingTimeInterval(8 * 86_400)
        await vibe.refresh(now: eightDaysLater)
        let b = await vibe.breakdown(now: eightDaysLater)
        XCTAssertEqual(b.todayCost, 0)
        XCTAssertEqual(b.weekCost, 0)
        XCTAssertEqual(b.monthCost, 0.180_564_74, accuracy: 1e-9)
        XCTAssertTrue(b.projectsWeek.isEmpty)
        XCTAssertEqual(b.projectsMonth.count, 2)
        let week = await vibe.weekCost(now: eightDaysLater)
        XCTAssertEqual(week, 0)
    }

    func testAWindowCountsOnlyTheStepsInsideIt() async throws {
        try VibeFixture.write(VibeFixture.whole(), under: root)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let window = await vibe.usage(from: Date(timeIntervalSince1970: 1_793_977_720), to: now)
        XCTAssertEqual(window.turns, 4)
        XCTAssertEqual(window.tokens, 45_460, "11 140 + 11 249 + 11 372 + 11 699")
        XCTAssertEqual(window.projects.map(\.displayName), ["Vibe Fixtures / probe"])
    }

    func testAnExtremeCounterInALogLineNeitherCrashesNorWraps() async throws {
        var huge = VibeFixture.whole(id: "00000000-0000-4000-8000-00000000ffff")
        huge.currentGeneration = 9
        huge.generations = [9: (VibeFixture.Usage(input: Int.max - 10, cached: 0, output: 100), 1_793_977_000_000)]
        huge.journals = [10: []]
        try VibeFixture.write(huge, under: root)
        try VibeFixture.write(VibeFixture.whole(), under: root)
        let vibe = aggregator(calendar: utc)
        await vibe.refresh(now: now)
        let b = await vibe.breakdown(now: now)
        XCTAssertEqual(b.todayTokens, Int.max, "saturated: not wrapped, not a trap")
        XCTAssertEqual(b.daily.map(\.totalTokens), [Int.max])
        XCTAssertEqual(b.todayTurns, 7)
    }
}
