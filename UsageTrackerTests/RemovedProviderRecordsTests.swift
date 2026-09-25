import XCTest
@testable import Omelette

/// Liquid-glass spec § Packages P8: "Stored history records with `serviceID == "gemini"`
/// are left in place and ignored", and the session's ruling R1 for P8. A reading or a
/// history record the removed Gemini CLI provider left on disk decodes next to the live
/// providers' own, is never migrated or deleted, and never reaches the screen.
final class RemovedProviderRecordsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemovedProviderRecordsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - last-known.json

    func testALaunchSeedsOnlyTheProvidersItPollsAndGeminiIsNotOneOfThem() {
        XCTAssertEqual(
            AppState.polledServiceIDs(codexEnabled: false, antigravityEnabled: false, grokEnabled: false, hasAdminKey: false),
            ["claude"],
            "Claude is not behind a switch"
        )
        XCTAssertEqual(
            AppState.polledServiceIDs(codexEnabled: true, antigravityEnabled: true, grokEnabled: true, hasAdminKey: true),
            ["claude", "codex", "antigravity", "grok", "anthropic-admin"]
        )
    }

    func testAStoredGeminiReadingStaysOnDiskAndIsNeverSeeded() async throws {
        let file = directory.appendingPathComponent("last-known.json")
        let readAt = Date(timeIntervalSince1970: 1_790_000_000)
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 63, kind: .session)],
            at: readAt
        )
        // What a build that still polled the Gemini CLI wrote: its daily Pro window,
        // named and shaped the way the removed provider named it.
        let gemini = Fixture.snapshot(
            id: "gemini", displayName: "Gemini", icon: "diamond", plan: "Gemini Pro",
            buckets: [Fixture.bucket(id: "gemini_pro", label: "Pro (daily)", percent: 91,
                                     kind: .modelSpecific, windowLength: 24 * 3600)],
            at: readAt
        )
        await LastKnownStore(fileURL: file).remember([claude, gemini])

        let stored = await LastKnownStore(fileURL: file).load()
        XCTAssertEqual(Set(stored.keys), ["claude", "gemini"], "both entries decode from disk")

        let polled = AppState.polledServiceIDs(codexEnabled: true, antigravityEnabled: true, grokEnabled: true, hasAdminKey: true)
        let seeded = AppState.seededSnapshot(from: stored, enabledServiceIDs: polled)
        XCTAssertEqual(seeded.services.map(\.id), ["claude"], "the Gemini reading never reaches the screen")
        XCTAssertEqual(seeded.services.first?.buckets.first?.utilization, 63)

        // The next poll writes Claude again; the Gemini entry is neither migrated nor deleted.
        let later = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 70, kind: .session)],
            at: readAt.addingTimeInterval(60)
        )
        await LastKnownStore(fileURL: file).remember([later])
        let reread = await LastKnownStore(fileURL: file).load()
        XCTAssertEqual(reread["gemini"]?.buckets.map(\.id), ["gemini_pro"])
        XCTAssertEqual(reread["claude"]?.buckets.first?.utilization, 70)
    }

    // MARK: - history.jsonl

    /// Two lines in the shape the app writes them. The Claude line is a record from this
    /// Mac's log, scrubbed. The other is what the Gemini CLI provider left: its bucket
    /// ids and plan, as that provider named them before 3.0. Both are recent, so the
    /// 90-day rotation keeps them. That age rotation applies to gemini records as to any
    /// other provider's; P8 adds no deletion of its own.
    func testAGeminiHistoryRecordStaysOnDiskAndIsNeverOffered() async throws {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let geminiAt = iso.string(from: now.addingTimeInterval(-3600))
        let claudeAt = iso.string(from: now.addingTimeInterval(-1800))
        let lines = [
            #"{"timestamp":"\#(geminiAt)","id":"0B5E9C1A-6D1F-4C3E-9A7B-2F4D8E6C1A01","plan":"Gemini Pro","bucketPercents":{"gemini_pro":91,"gemini_flash":12,"gemini_flash_lite":0},"serviceID":"gemini"}"#,
            #"{"plan":"Claude Max 20x","id":"E86A654B-8745-4C50-A815-E6BCA3EAE937","bucketPercents":{"five_hour":63,"seven_day":17},"fiveHourPercent":63,"extraCreditsUsed":0,"serviceID":"claude","timestamp":"\#(claudeAt)","sevenDayPercent":17}"#,
        ]
        let log = directory.appendingPathComponent("history.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)

        let store = HistoryStore(directory: directory)
        let recorded = await store.recordedServices()
        XCTAssertEqual(recorded, ["claude", "gemini"], "both lines decode")
        let claude = await store.all(service: "claude")
        XCTAssertEqual(claude.first?.percent(for: "five_hour"), 63)

        let offered = DashboardState.availableServices(
            recorded: recorded,
            snapshot: UsageSnapshot(
                services: [Fixture.snapshot(id: "claude", state: .notSignedIn)],
                fetchedAt: now, isStale: false, lastError: nil
            ),
            disabled: []
        )
        XCTAssertEqual(offered, ["claude"], "a provider this build no longer polls is not offered")

        let onDisk = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(#""serviceID":"gemini""#), "the record stays on disk")
    }

    // MARK: - the dashboard's stored selection

    /// The dashboard's stored provider is "gemini" and nothing is on offer yet: a fresh
    /// launch whose Claude fetch failed. Standing still would let `refreshHistory` load
    /// that id's leftover records onto the tab, so the selection goes to Claude, which is
    /// always polled. A provider this build still polls keeps standing still, as before.
    func testAStoredGeminiSelectionWithNothingOnOfferHealsToClaude() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "gemini", available: []), "claude")
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "codex", available: []), "codex",
            "a polled provider still stands still when there is nothing to heal to"
        )
    }

    func testTheCoordinatorNamesEveryProviderItPollsAndSettingsListsTheSame() {
        XCTAssertEqual(ProviderCoordinator.serviceIDs, ["claude", "anthropic-admin", "codex", "antigravity", "grok"])
        XCTAssertTrue(ProviderCoordinator.serviceIDs.isSuperset(of: [
            ClaudeOAuthProvider.serviceID,
            CodexProvider.serviceID,
            AntigravityProvider.shared.serviceID,
            GrokProvider.shared.serviceID,
        ]))
        XCTAssertEqual(
            ProviderCoordinator.serviceIDs,
            Set(ProvidersSettingsCopy.listed.map(\.id)).union([ProvidersSettingsCopy.adminID]),
            "Settings › Providers lists every provider the coordinator polls"
        )
    }

    func testTheHealTakesThePolledSetAsItsInput() {
        XCTAssertEqual(DashboardState.healedSelection(stored: "x", available: [], polled: ["x"]), "x")
        XCTAssertEqual(DashboardState.healedSelection(stored: "codex", available: [], polled: ["claude"]), "claude")
        XCTAssertEqual(
            DashboardState.healedSelection(stored: "gemini", available: ["grok"], polled: ["claude"]), "grok",
            "with options on offer the first one wins, whatever the set"
        )
    }
}
