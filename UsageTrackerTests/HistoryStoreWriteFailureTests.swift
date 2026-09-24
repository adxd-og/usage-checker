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
}
