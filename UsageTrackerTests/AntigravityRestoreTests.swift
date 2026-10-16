import XCTest
@testable import Omelette

/// A closed Antigravity's last-known numbers in the shape this build publishes (session
/// addition of 2026-10-16 to spec 2026-10-16-antigravity-argon § "Package 2": the reading
/// stored before the Argon fix showed Argon as a second "Gemini weekly" beside the two
/// aggregates until the next good reading). The rule is
/// `AntigravityProvider.restoredBuckets`; `LastKnownStore.load` applies it, as it drops
/// 3.0.1's credit pools. Every store points at this test's own temp file.
final class AntigravityRestoreTests: XCTestCase {
    private typealias F = AntigravityFixture
    private var directory: URL!
    private var fileURL: URL!
    private let week: TimeInterval = 604_800
    private let fiveHours: TimeInterval = 18_000
    /// 2026-10-16 14:28:43 UTC.
    private let thirdParty5hReset = Date(timeIntervalSince1970: 1_792_160_923)
    /// 2026-10-23 09:28:43 UTC.
    private let thirdPartyWeeklyReset = Date(timeIntervalSince1970: 1_792_747_723)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("last-known.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LastKnownStore { LastKnownStore(fileURL: fileURL) }

    /// `last-known.json`'s Antigravity entry as this Mac's Omelette stored it on 2026-10-16
    /// at 09:28:43 UTC, before the Argon fix (account scrubbed, percents rounded): the two
    /// aggregates, the four pool windows, and Argon as a weekly titled "Gemini weekly".
    private let antigravityBeforeTheArgonFix = """
    {"antigravity": {"displayName": "Antigravity", "icon": "circle.grid.cross", "plan": "Antigravity Google Ai Pro",
      "accountLabel": "owner@example.com", "order": 2, "fetchedAt": "2026-10-16T09:28:43Z", "buckets": [
        {"id": "antigravity_gemini", "label": "Gemini models", "utilization": 47.443414, "resetsAt": "2026-10-23T07:45:44Z", "kind": "weekly", "windowLength": 604800},
        {"id": "antigravity_claude_gpt", "label": "Claude & GPT models", "utilization": 0, "resetsAt": "2026-10-16T14:28:43Z", "kind": "session", "windowLength": 18000},
        {"id": "antigravity_antigravity-quota-summary-gemini-5h", "label": "Gemini 5-hour", "utilization": 0.035733, "resetsAt": "2026-10-16T12:46:06Z", "kind": "session", "windowLength": 18000},
        {"id": "antigravity_antigravity-quota-summary-gemini-weekly", "label": "Gemini weekly", "utilization": 0.01021, "resetsAt": "2026-10-23T07:46:06Z", "kind": "weekly", "windowLength": 604800},
        {"id": "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", "label": "Gemini weekly", "utilization": 47.443414, "resetsAt": "2026-10-23T07:45:44Z", "kind": "weekly", "windowLength": 604800},
        {"id": "antigravity_antigravity-quota-summary-3p-5h", "label": "Claude/GPT 5-hour", "utilization": 0, "resetsAt": "2026-10-16T14:28:43Z", "kind": "session", "windowLength": 18000},
        {"id": "antigravity_antigravity-quota-summary-3p-weekly", "label": "Claude/GPT weekly", "utilization": 0, "resetsAt": "2026-10-23T09:28:43Z", "kind": "weekly", "windowLength": 604800}
      ]}}
    """

    /// Those buckets as values.
    private var oldShape: [UsageBucket] {
        [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 47.443414,
                           resetsAt: F.argonWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", percent: 0.01021,
                           resetsAt: F.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini weekly",
                           percent: 47.443414, resetsAt: F.argonWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 0,
                           resetsAt: thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ]
    }

    /// What this build publishes for that reading: no aggregates, Argon its own row.
    private var todaysShape: [UsageBucket] {
        [
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-5h", label: "Gemini 5-hour", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-weekly", label: "Gemini weekly", percent: 0.01021,
                           resetsAt: F.geminiWeeklyReset, kind: .weekly, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-gemini-argon-wtu-weekly", label: "Gemini Argon",
                           percent: 47.443414, resetsAt: F.argonWeeklyReset, kind: .modelSpecific, windowLength: week),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-5h", label: "Claude/GPT 5-hour", percent: 0,
                           resetsAt: thirdParty5hReset, kind: .session, windowLength: fiveHours),
            Fixture.bucket(id: "antigravity_antigravity-quota-summary-3p-weekly", label: "Claude/GPT weekly", percent: 0,
                           resetsAt: thirdPartyWeeklyReset, kind: .weekly, windowLength: week),
        ]
    }

    func testAReadingStoredBeforeTheArgonFixComesBackInTodaysShape() async throws {
        try Data(antigravityBeforeTheArgonFix.utf8).write(to: fileURL)
        let loaded = await store().load()
        let entry = try XCTUnwrap(loaded["antigravity"])
        XCTAssertEqual(entry.buckets, todaysShape)
        XCTAssertEqual(entry.plan, "Antigravity Google Ai Pro", "only the buckets change")
        XCTAssertEqual(entry.fetchedAt, Date(timeIntervalSince1970: 1_792_142_923))
    }

    func testTheRuleDropsTheAggregatesAndMakesArgonAPerModelRow() {
        XCTAssertEqual(AntigravityProvider.restoredBuckets(oldShape), todaysShape)
    }

    func testTodaysReadingsComeBackUnchanged() {
        let local = AntigravityProvider.buckets(from: F.proSummary)
        XCTAssertEqual(AntigravityProvider.restoredBuckets(local), local)
        XCTAssertEqual(AntigravityProvider.restoredBuckets(AgyUsageFixture.proBuckets), AgyUsageFixture.proBuckets,
                       "a per-model row keeps its name, which may be agy's")
        XCTAssertEqual(AntigravityProvider.restoredBuckets(todaysShape), todaysShape)
    }

    func testAPerModelReadingIsLeftAsItIs() {
        let perModel = AntigravityProvider.buckets(from: F.perModel0750)
        XCTAssertEqual(AntigravityProvider.restoredBuckets(perModel), perModel, "on that path the aggregates are the pools")
    }

    /// The per-model shape (the web fallback) as builds before the Argon fix stored it,
    /// History 07:50:14: the two aggregates and Argon's three effort variants under their
    /// placeholder wire ids, every one `.other`, no window length.
    private var perModelBeforeTheArgonFix: [UsageBucket] {
        [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 0.035733,
                           resetsAt: F.gemini5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 0,
                           resetsAt: F.thirdParty5hReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M419", label: "Gemini 4 Argon (High)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M418", label: "Gemini 4 Argon (Medium)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M417", label: "Gemini 4 Argon (Low)", percent: 6.11776,
                           resetsAt: F.argonWeeklyReset, kind: .other),
        ]
    }

    /// Session ruling of the fix round: on a stored per-model reading every model row
    /// becomes `.modelSpecific`, so Argon's placeholders stop driving the headline. The
    /// aggregates stay (on this path they leave Argon out); nothing collapses or goes.
    func testAPerModelReadingStoredBeforeTheArgonFixNoLongerDrivesTheHeadline() {
        let before = Fixture.snapshot(id: "antigravity", buckets: perModelBeforeTheArgonFix, at: F.readAt)
        XCTAssertGreaterThan(before.headlinePercent, 6, "the bug: the placeholders compete for the headline")

        let restored = AntigravityProvider.restoredBuckets(perModelBeforeTheArgonFix)
        XCTAssertEqual(restored.map(\.id), perModelBeforeTheArgonFix.map(\.id), "nothing dropped, nothing collapsed")
        XCTAssertEqual(restored.map(\.label), perModelBeforeTheArgonFix.map(\.label))
        XCTAssertEqual(restored.map(\.utilization), perModelBeforeTheArgonFix.map(\.utilization))
        XCTAssertEqual(restored.map(\.kind), [.other, .other, .modelSpecific, .modelSpecific, .modelSpecific])
        let after = Fixture.snapshot(id: "antigravity", buckets: restored, at: F.readAt)
        XCTAssertLessThan(after.headlinePercent, 1, "the Gemini pool's 0.04 %, not Argon's 6 %")
        XCTAssertEqual(AntigravityProvider.restoredBuckets(restored), restored, "restoring twice is restoring once")
    }

    /// The probe's reset-only pool windows and its compact fallback stand for the pools on
    /// the per-model path; they keep their kind like the aggregates.
    func testOnAStoredPerModelReadingPoolAndFallbackWindowsKeepTheirKind() {
        let stored = [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 3, kind: .other),
            Fixture.bucket(id: "antigravity_antigravity-gemini", label: "Gemini models", percent: 0, kind: .other),
            Fixture.bucket(id: "antigravity_antigravity-claude-gpt", label: "Claude & GPT models", percent: 0, kind: .other),
            Fixture.bucket(id: "antigravity_antigravity-compact-fallback-pro", label: "Quota", percent: 5, kind: .other),
            Fixture.bucket(id: "antigravity_MODEL_PLACEHOLDER_M417", label: "Gemini 4 Argon (Low)", percent: 9, kind: .other),
        ]
        XCTAssertEqual(AntigravityProvider.restoredBuckets(stored).map(\.kind),
                       [.other, .other, .other, .other, .modelSpecific])
    }

    func testOnlyTheAntigravityEntryIsReshapedAndCreditPoolsStillGo() {
        let claude = LastKnownService(from: Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 7, kind: .session),
            Fixture.bucket(id: "iguana_necktie", label: "Iguana Necktie", percent: 92.37),
        ], at: F.readAt), order: 0)
        let antigravity = LastKnownService(
            from: Fixture.snapshot(id: "antigravity", displayName: "Antigravity", buckets: oldShape, at: F.readAt),
            order: 2
        )
        let other = LastKnownService(from: Fixture.snapshot(id: "other", buckets: oldShape, at: F.readAt), order: 3)

        let restored = LastKnownStore.restorable(
            ["claude": claude, "antigravity": antigravity, "other": other],
            creditPoolIDs: ["iguana_necktie"]
        )

        XCTAssertEqual(restored["claude"]?.buckets.map(\.id), ["five_hour"])
        XCTAssertEqual(restored["antigravity"]?.buckets, todaysShape)
        XCTAssertEqual(restored["other"]?.buckets, oldShape, "the rule is Antigravity's own")
    }

    func testTheNextWriteStoresTheRestoredShape() async throws {
        try Data(antigravityBeforeTheArgonFix.utf8).write(to: fileURL)
        let first = store()
        _ = await first.load()
        await first.remember([
            Fixture.snapshot(id: "claude", displayName: "Claude",
                             buckets: [Fixture.bucket(id: "five_hour", percent: 7, kind: .session)], at: F.readAt),
        ])

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("antigravity_claude_gpt"), raw)
        let reloaded = await store().load()
        XCTAssertEqual(reloaded["antigravity"]?.buckets, todaysShape)
    }
}
