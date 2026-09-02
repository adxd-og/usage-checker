import XCTest
@testable import Omelette

final class AgentHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("agent-sessions.jsonl") }

    private func record(
        id: String = "claude:s1",
        source: AgentSource = .claude,
        project: String = "Projects / alpha",
        startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date = Date(timeIntervalSince1970: 1_800_003_600),
        turns: Int = 4,
        needsYouCount: Int = 1
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: source, project: project,
            startedAt: startedAt, endedAt: endedAt, turns: turns, needsYouCount: needsYouCount
        )
    }

    func testAnEmptyLogLoadsAsNothing() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertEqual(try store.load(), [])
    }

    func testRecordsRoundTripInOrder() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        let first = record(id: "claude:s1", turns: 4)
        let second = record(id: "codex:t2", source: .codex, project: "Projects / beta", turns: 1, needsYouCount: 0)
        try store.append(first)
        try store.append(second)

        let loaded = try AgentHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded, [first, second], "the log is append-only: order is the order things ended")
        XCTAssertEqual(loaded[1].source, .codex)
    }

    func testTheLogIsOneJSONObjectPerLine() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record())
        try store.append(record(id: "claude:s2"))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(text.hasSuffix("\n"), "every record ends its own line so an append never corrupts the previous one")
        for line in lines {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testNoToolDetailIsEverWritten() throws {
        // Privacy rule from the spec: the history is a summary, never a transcript.
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")[0].utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["id", "source", "project", "startedAt", "endedAt", "turns", "needsYouCount"])
    }

    func testACorruptLineIsSkippedRatherThanLosingTheLog() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:good1"))
        try "{not json at all\n".appendTo(fileURL)
        try store.append(record(id: "claude:good2"))

        let loaded = try AgentHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(loaded.map(\.id), ["claude:good1", "claude:good2"])
    }

    func testTheDirectoryIsCreatedOnDemand() throws {
        // App Support/UsageTracker may not exist on a fresh install before the first
        // session ends; an append must not fail because of that.
        let nested = directory.appendingPathComponent("does/not/exist/agent-sessions.jsonl")
        let store = AgentHistoryStore(fileURL: nested)
        try store.append(record())
        XCTAssertEqual(try store.load().count, 1)
    }

    // MARK: - Rotation

    /// 2026-09-02 12:00:00 UTC.
    private var rotationNow: Date { Date(timeIntervalSince1970: 1_788_350_400) }

    func testRotationKeepsRecordsInsideTheWindow() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        // 2026-08-01 12:00 UTC — 32 days old, comfortably inside 90.
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load().map(\.id), ["claude:recent"])
    }

    func testRotationDropsRecordsOlderThanTheWindow() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        // 2026-01-01 12:00 UTC — 244 days old.
        try store.append(record(id: "claude:ancient", endedAt: Date(timeIntervalSince1970: 1_767_268_800)))
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load().map(\.id), ["claude:recent"])
    }

    func testRotationIsMeasuredFromEndedAt() {
        // A session that started before the window but ended inside it is kept.
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertNoThrow(try store.append(record(
            id: "claude:marathon",
            startedAt: Date(timeIntervalSince1970: 1_767_268_800),
            endedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )))
        XCTAssertNoThrow(try store.rotate(keepDays: 90, now: rotationNow))
        XCTAssertEqual(try? store.load().map(\.id), ["claude:marathon"])
    }

    func testRotationDropsACorruptLineWithoutLosingTheGoodOnes() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:good1", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        try "{not json at all\n".appendTo(fileURL)
        try store.append(record(id: "claude:good2", endedAt: Date(timeIntervalSince1970: 1_785_589_200)))

        try store.rotate(keepDays: 90, now: rotationNow)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("not json"), "the rewrite is what finally clears it out")
        XCTAssertEqual(try store.load().map(\.id), ["claude:good1", "claude:good2"])
    }

    func testRotationLeavesAHealthyLogByteIdentical() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:recent", endedAt: Date(timeIntervalSince1970: 1_785_585_600)))
        let before = try Data(contentsOf: fileURL)

        try store.rotate(keepDays: 90, now: rotationNow)

        XCTAssertEqual(try Data(contentsOf: fileURL), before, "nothing to drop means nothing to write")
    }

    func testRotatingAMissingLogDoesNothingAndCreatesNoFile() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        XCTAssertNoThrow(try store.rotate(keepDays: 90, now: rotationNow))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testRotationCanEmptyTheLogEntirely() throws {
        let store = AgentHistoryStore(fileURL: fileURL)
        try store.append(record(id: "claude:ancient", endedAt: Date(timeIntervalSince1970: 1_767_268_800)))
        try store.rotate(keepDays: 90, now: rotationNow)
        XCTAssertEqual(try store.load(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "an empty log is still a log")
    }
}

private extension String {
    /// Appends raw bytes to a file the test already created.
    func appendTo(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
