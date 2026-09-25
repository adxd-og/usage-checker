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
}
