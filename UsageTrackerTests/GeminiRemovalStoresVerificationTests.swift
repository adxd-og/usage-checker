import XCTest
@testable import Omelette

/// Independent verification of the liquid-glass redesign spec, P8 row: "Stored history
/// records with `serviceID == "gemini"` are left in place and ignored" (line 238), and
/// the owner's 2026-09-26 clarification: "the store's existing 90-day age rotation
/// applies to them like to any other provider's; that is prior behaviour, not a P8
/// deletion."
///
/// Builds its own on-disk fixtures rather than reusing the executor's
/// `RemovedProviderRecordsTests` ones, and specifically forces a real compaction
/// rewrite (by putting a genuinely stale *third* provider's record in the same file)
/// to prove the rewrite path keeps a recent gemini line rather than special-casing it
/// away.
final class GeminiRemovalStoresVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeminiRemovalStoresVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var recordEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Writes an already-built `HistoryRecord` as one JSONL line, in the exact format
    /// `HistoryStore` itself writes (same encoder settings), without going through the
    /// store's `append(snapshot:)` — which always stamps `Date()` and cannot place a
    /// record 91 days in the past.
    private func writeLine(_ record: HistoryRecord, to url: URL, append: Bool) throws {
        var data = try recordEncoder.encode(record)
        data.append(0x0A)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    func testARecentGeminiRecordSurvivesRotationThatDropsAGenuinelyStaleOtherProvider() async throws {
        let now = Date()
        let log = directory.appendingPathComponent("history.jsonl")

        let geminiRecord = HistoryRecord(
            from: Fixture.snapshot(
                id: "gemini", displayName: "Gemini", plan: "Gemini Pro",
                buckets: [Fixture.bucket(id: "gemini_pro", label: "Pro (daily)", percent: 77, kind: .modelSpecific)]
            ),
            at: now.addingTimeInterval(-3600)
        )
        let claudeRecord = HistoryRecord(
            from: Fixture.snapshot(
                id: "claude", displayName: "Claude", plan: "Claude Max 20x",
                buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 55, kind: .session)]
            ),
            at: now.addingTimeInterval(-1800)
        )
        // 91 days old: past HistoryStore's 90-day `maxAge`, so rotation must drop this
        // one on load — proving the rewrite it triggers doesn't also drop gemini's line.
        let staleCodexRecord = HistoryRecord(
            from: Fixture.snapshot(id: "codex", displayName: "Codex", plan: nil,
                                    buckets: [Fixture.bucket(id: "codex_weekly", percent: 40)]),
            at: now.addingTimeInterval(-91 * 24 * 3600)
        )

        try writeLine(geminiRecord, to: log, append: false)
        try writeLine(claudeRecord, to: log, append: true)
        try writeLine(staleCodexRecord, to: log, append: true)

        // A fresh actor over the same directory — nothing has been loaded yet, so this
        // exercises `loadIfNeeded()` -> `rotateIfNeeded()` -> `rewriteFile()` end to end.
        let store = HistoryStore(directory: directory)
        let recorded = await store.recordedServices()
        XCTAssertEqual(recorded, ["claude", "gemini"], "the stale codex record rotated out; gemini and claude did not")

        let claudeOnly = await store.all(service: "claude")
        XCTAssertEqual(claudeOnly.count, 1)
        XCTAssertEqual(claudeOnly.first?.percent(for: "five_hour"), 55)

        let geminiOnly = await store.all(service: "gemini")
        XCTAssertEqual(geminiOnly.count, 1, "the gemini record itself is untouched, not merely its count in recordedServices()")
        XCTAssertEqual(geminiOnly.first?.percent(for: "gemini_pro"), 77)

        // The rotation rewrite already ran (staleOnDisk > 0 from the codex record), so
        // this reads back what actually landed on disk, not what is only in memory.
        let onDisk = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(onDisk.contains(#""serviceID":"gemini""#), "the rewrite kept the gemini line")
        XCTAssertFalse(onDisk.contains(#""serviceID":"codex""#), "the genuinely stale record is the one that should be gone")
    }

    func testLastKnownStoreLoadsAFileWithAGeminiEntryWithoutErrorAndKeepsIt() async throws {
        let file = directory.appendingPathComponent("last-known.json")
        let fetchedAt = Date(timeIntervalSince1970: 1_795_000_000)

        // Written the way an older build (one that still polled the Gemini CLI) would
        // have written it: a plain [String: LastKnownService] dictionary, same encoder
        // settings LastKnownStore itself uses, built without ever touching the store.
        let geminiEntry = LastKnownService(
            from: Fixture.snapshot(
                id: "gemini", displayName: "Gemini", icon: "diamond", plan: "Gemini Pro",
                buckets: [Fixture.bucket(id: "gemini_pro", label: "Pro (daily)", percent: 64, kind: .modelSpecific)],
                at: fetchedAt
            ),
            order: 3
        )
        let claudeEntry = LastKnownService(
            from: Fixture.snapshot(
                id: "claude", displayName: "Claude", plan: "Claude Max 20x",
                buckets: [Fixture.bucket(id: "five_hour", percent: 20, kind: .session)],
                at: fetchedAt
            ),
            order: 0
        )
        let onDisk: [String: LastKnownService] = ["gemini": geminiEntry, "claude": claudeEntry]
        try recordEncoder.encode(onDisk).write(to: file, options: [.atomic])

        let store = LastKnownStore(fileURL: file)
        let loaded = await store.load()
        XCTAssertEqual(Set(loaded.keys), ["gemini", "claude"], "the file decodes without error, gemini included")
        XCTAssertEqual(loaded["gemini"]?.buckets.first?.utilization, 64)
        XCTAssertEqual(loaded["gemini"]?.plan, "Gemini Pro")

        // A poll that reports only Claude must not disturb the gemini entry sitting
        // next to it — `remember` only ever sets keys for services it was handed.
        let refreshedClaude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Claude Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", percent: 33, kind: .session)],
            at: fetchedAt.addingTimeInterval(120)
        )
        await store.remember([refreshedClaude])
        let reloaded = await store.load()
        XCTAssertEqual(reloaded["gemini"]?.buckets.first?.utilization, 64, "still exactly what the fixture wrote")
        XCTAssertEqual(reloaded["claude"]?.buckets.first?.utilization, 33, "claude's own entry did move")
    }
}
