import XCTest
@testable import Omelette

final class HistoryRecordCodingTests: XCTestCase {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func testServiceIDSurvivesARoundTrip() throws {
        let original = HistoryRecord(
            from: Fixture.snapshot(
                id: "codex",
                plan: "Codex Pro",
                buckets: [
                    Fixture.bucket(id: "codex_session", percent: 42, kind: .session),
                    Fixture.bucket(id: "codex_weekly", percent: 7, kind: .weekly),
                ]
            ),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let decoded = try Self.decoder.decode(
            HistoryRecord.self, from: Self.encoder.encode(original)
        )

        XCTAssertEqual(decoded.serviceID, "codex")
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.percent(for: "codex_session"), 42)
        XCTAssertEqual(decoded.percent(for: "codex_weekly"), 7)
        XCTAssertNil(decoded.percent(for: "five_hour"))
    }

    func testTheEncodedKeyIsPlainServiceID() throws {
        let record = HistoryRecord(from: Fixture.snapshot(id: "gemini"), at: Date())
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.encoder.encode(record)) as? [String: Any]
        )
        XCTAssertEqual(json["serviceID"] as? String, "gemini")
        XCTAssertNil(json["storedServiceID"], "the private storage name must not leak into the log")
    }

    func testAnOldRecordWithoutAServiceIDIsClaudes() throws {
        // Written before history went multi-provider, when only Claude was recorded.
        let legacy = """
        {"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0001",
         "timestamp":"2026-08-01T10:00:00Z",
         "fiveHourPercent":42.0,
         "sevenDayPercent":18.0,
         "plan":"Max 20x"}
        """
        let record = try Self.decoder.decode(HistoryRecord.self, from: Data(legacy.utf8))

        XCTAssertEqual(record.serviceID, "claude")
        XCTAssertEqual(record.percent(for: "five_hour"), 42.0)
        XCTAssertEqual(record.percent(for: "seven_day"), 18.0)
        XCTAssertEqual(record.plan, "Max 20x")
    }
}

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func claude(percent: Double = 40) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: percent, kind: .session)]
        )
    }

    private func codex(percent: Double = 12) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex",
            buckets: [Fixture.bucket(id: "codex_session", percent: percent, kind: .session)]
        )
    }

    func testThrottlingIsPerServiceNotGlobal() async {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: claude())
        // Straight after Claude, and well inside the 30-second throttle: a global
        // check dropped this silently and Codex never recorded anything.
        await store.append(snapshot: codex())
        // A second Claude in the same breath IS throttled.
        await store.append(snapshot: claude(percent: 99))

        let claudeRecords = await store.all(service: "claude")
        let codexRecords = await store.all(service: "codex")

        XCTAssertEqual(claudeRecords.count, 1)
        XCTAssertEqual(claudeRecords.first?.percent(for: "five_hour"), 40)
        XCTAssertEqual(codexRecords.count, 1)
        XCTAssertEqual(codexRecords.first?.percent(for: "codex_session"), 12)
    }

    func testQueriesReturnOnlyTheRequestedService() async {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: claude())
        await store.append(snapshot: codex())

        let claudeRecords = await store.all(service: "claude")
        let codexRecords = await store.all(service: "codex")
        let geminiRecords = await store.all(service: "gemini")
        XCTAssertEqual(claudeRecords.map(\.serviceID), ["claude"])
        XCTAssertEqual(codexRecords.map(\.serviceID), ["codex"])
        XCTAssertTrue(geminiRecords.isEmpty)

        let recent = await store.records(since: Date().addingTimeInterval(-3600), service: "codex")
        XCTAssertEqual(recent.map(\.serviceID), ["codex"])

        let ancient = await store.records(since: Date().addingTimeInterval(3600), service: "codex")
        XCTAssertTrue(ancient.isEmpty, "a cutoff in the future must exclude everything")
    }

    func testDefaultingToClaudeKeepsExistingCallersHonest() async {
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: codex())
        await store.append(snapshot: claude())

        // No service argument means Claude — what every pre-existing caller assumed.
        let defaulted = await store.all()
        XCTAssertEqual(defaulted.map(\.serviceID), ["claude"])
    }

    func testRecordedServicesListsWhatHasActuallyBeenSeen() async {
        let store = HistoryStore(directory: directory)
        let beforeAnything = await store.recordedServices()
        XCTAssertEqual(beforeAnything, [])

        await store.append(snapshot: claude())
        await store.append(snapshot: codex())
        await store.append(snapshot: Fixture.snapshot(id: "gemini"))

        let seen = await store.recordedServices()
        XCTAssertEqual(seen, ["claude", "codex", "gemini"])
    }

    func testRecordsSurviveAReopenWithTheirService() async {
        let writer = HistoryStore(directory: directory)
        await writer.append(snapshot: claude(percent: 61))
        await writer.append(snapshot: codex(percent: 3))

        let reader = HistoryStore(directory: directory)
        let claudeRecords = await reader.all(service: "claude")
        let codexRecords = await reader.all(service: "codex")
        let seen = await reader.recordedServices()
        XCTAssertEqual(claudeRecords.first?.percent(for: "five_hour"), 61)
        XCTAssertEqual(codexRecords.first?.percent(for: "codex_session"), 3)
        XCTAssertEqual(seen, ["claude", "codex"])
    }

    func testALogWrittenByAnOlderBuildReadsAsClaude() async throws {
        let legacy = """
        {"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0002","timestamp":"2026-08-01T10:00:00Z","fiveHourPercent":55.0}
        """
        try (legacy + "\n").write(
            to: directory.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8
        )

        let store = HistoryStore(directory: directory)
        let records = await store.all(service: "claude")

        let codexRecords = await store.all(service: "codex")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.serviceID, "claude")
        XCTAssertEqual(records.first?.percent(for: "five_hour"), 55.0)
        XCTAssertTrue(codexRecords.isEmpty)
    }
}
