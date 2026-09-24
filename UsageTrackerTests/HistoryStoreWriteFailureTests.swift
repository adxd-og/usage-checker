import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// `HistoryStore` (report B #5 and #7): a write that fails must never cost the history
/// already on disk. The log is made read-only (0444) or immutable (`uchg`) in a
/// writable directory, the two ways measured on this Mac to make `FileHandle` refuse
/// the file while an atomic replace still — or no longer — succeeds.
final class HistoryStoreWriteFailureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreWriteFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: log.path) {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: log.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private var log: URL { directory.appendingPathComponent("history.jsonl") }
    private var legacy: URL { directory.appendingPathComponent("history.json") }

    private func snapshot(_ id: String, percent: Double = 40) -> ServiceSnapshot {
        Fixture.snapshot(id: id, buckets: [Fixture.bucket(id: "\(id)_session", percent: percent, kind: .session)])
    }

    // MARK: - Append (report B #5)

    func testAnAppendThatCannotOpenTheLogLeavesTheLogAsItIs() async throws {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: snapshot("claude"))
        await store.append(snapshot: snapshot("codex"))
        await store.append(snapshot: snapshot("gemini"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.path)

        await store.append(snapshot: snapshot("grok"))

        let onDisk = await HistoryStore(directory: directory).recordedServices()
        XCTAssertEqual(onDisk, ["claude", "codex", "gemini"], "three records on disk, not the fourth alone")
        let inMemory = await store.recordedServices()
        XCTAssertEqual(inMemory, ["claude", "codex", "gemini", "grok"], "the fourth waits for the next rewrite")
    }

    func testTheFirstAppendStillCreatesTheLog() async throws {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: snapshot("claude"))

        let onDisk = await HistoryStore(directory: directory).recordedServices()
        XCTAssertEqual(onDisk, ["claude"])
    }

    // MARK: - Legacy migration (report B #7)

    /// A JSONL log a migration once wrote, a day old, and a legacy array a pre-JSONL
    /// build wrote after a rollback — newer than the log, so the migration runs again.
    private func writeOlderLogAndNewerLegacy() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(HistoryRecord(
            from: snapshot("claude", percent: 20), at: Date().addingTimeInterval(-2 * 86_400)
        ))
        line.append(0x0A)
        try line.write(to: log)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: log.path
        )
        let rolledBack = [
            HistoryRecord(from: snapshot("claude", percent: 30), at: Date().addingTimeInterval(-3_600)),
            HistoryRecord(from: snapshot("codex", percent: 5), at: Date().addingTimeInterval(-1_800)),
        ]
        try encoder.encode(rolledBack).write(to: legacy)
    }

    func testALegacyHistoryIsKeptWhenTheLogCannotTakeItsRecords() async throws {
        try writeOlderLogAndNewerLegacy()
        // The log cannot be replaced, so the rewrite that should carry the legacy
        // records over fails — while the old log still exists.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: log.path)

        _ = await HistoryStore(directory: directory).recordedServices()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.path),
            "the only copy of the rolled-back records must survive a failed migration"
        )
    }

    func testALegacyHistoryIsRemovedOnceTheLogHoldsItsRecords() async throws {
        try writeOlderLogAndNewerLegacy()

        let services = await HistoryStore(directory: directory).recordedServices()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(services, ["claude", "codex"], "the legacy array superseded the older log")
    }
}
