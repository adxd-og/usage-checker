import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// `HistoryStore` (report B #5, #7): "the replace path runs only when the file does
/// not exist; otherwise log and leave the file." Written independently of
/// `HistoryStoreWriteFailureTests.swift`, with its own fixtures, timing and services.
///
/// The append scenario uses `chflags uchg` (immutable) rather than the executor's
/// POSIX 0444 — a deliberate mechanism swap on that path, which is mechanism-agnostic
/// (the append code never reaches an atomic write once the file already exists, so
/// either failure mode exercises the same branch). The migration scenario keeps
/// `uchg`: the report's own proof that 0444 alone leaves `FileHandle(forWritingTo:)`
/// failing while the `.atomic` fallback still SUCCEEDS means 0444 would not actually
/// fail `rewriteFile()`'s atomic write, so swapping it there would silently test
/// nothing.
final class HistoryStoreVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreVerificationTests-\(UUID().uuidString)", isDirectory: true)
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

    private func snapshot(_ id: String, percent: Double = 50) -> ServiceSnapshot {
        Fixture.snapshot(id: id, buckets: [Fixture.bucket(id: "\(id)_session", percent: percent, kind: .session)])
    }

    // MARK: - Append (report B #5)

    func testAppendCreatesTheLogWhenNoneExistsYet() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "precondition: nothing on disk yet")
        let store = HistoryStore(directory: directory)

        await store.append(snapshot: snapshot("verify-claude"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "the first append must create the log")
        let reread = await HistoryStore(directory: directory).recordedServices()
        XCTAssertEqual(reread, ["verify-claude"])
    }

    func testAnImmutableLogKeepsEveryLineAfterAFailedAppend() async throws {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: snapshot("verify-claude"))
        await store.append(snapshot: snapshot("verify-codex"))
        await store.append(snapshot: snapshot("verify-gemini"))
        let beforeFailure = await HistoryStore(directory: directory).recordedServices()
        XCTAssertEqual(beforeFailure, ["verify-claude", "verify-codex", "verify-gemini"], "precondition")

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: log.path)

        await store.append(snapshot: snapshot("verify-grok"))

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: log.path)
        let onDisk = await HistoryStore(directory: directory).recordedServices()
        XCTAssertEqual(
            onDisk, ["verify-claude", "verify-codex", "verify-gemini"],
            "the immutable log keeps exactly its three lines, not one line of just the fourth record"
        )
        let inMemory = await store.recordedServices()
        XCTAssertEqual(
            inMemory, ["verify-claude", "verify-codex", "verify-gemini", "verify-grok"],
            "the fourth record still lives in memory, waiting for a rewrite that can succeed"
        )
    }

    // MARK: - Legacy migration (report B #7)

    /// An older JSONL log plus a legacy array newer than it (as a rollback to a
    /// pre-JSONL build, followed by more polls, would leave behind).
    private func writeOlderLogAndNewerLegacy() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(HistoryRecord(
            from: snapshot("verify-claude", percent: 15), at: Date().addingTimeInterval(-4 * 86_400)
        ))
        line.append(0x0A)
        try line.write(to: log)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: log.path
        )
        let rolledBack = [
            HistoryRecord(from: snapshot("verify-claude", percent: 45), at: Date().addingTimeInterval(-7_200)),
            HistoryRecord(from: snapshot("verify-codex", percent: 8), at: Date().addingTimeInterval(-3_600)),
        ]
        try encoder.encode(rolledBack).write(to: legacy)
    }

    func testANewerLegacyHistorySurvivesWhenTheLogCannotBeReplaced() async throws {
        try writeOlderLogAndNewerLegacy()
        // `rewriteFile()` writes directly with `.atomic`, no `FileHandle` involved, and
        // POSIX 0444 alone does not block that path on this Mac (see the header note)
        // — only `uchg` does, so it is what both files use for this scenario.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: log.path)

        _ = await HistoryStore(directory: directory).recordedServices()

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: log.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.path),
            "the rolled-back records' only copy must survive a migration that could not write them out"
        )
    }

    func testANewerLegacyHistoryIsRemovedOnceTheRewriteSucceeds() async throws {
        try writeOlderLogAndNewerLegacy()

        let services = await HistoryStore(directory: directory).recordedServices()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "superseded once safely rewritten")
        XCTAssertEqual(services, ["verify-claude", "verify-codex"])
    }
}
