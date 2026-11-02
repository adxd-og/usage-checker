import XCTest
@testable import Omelette

/// History keeps which windows Claude Code's status line fed (spec 2026-11-02 Claude limits
/// from the status line, § Source tag), so the Limits tab can later tell the status line's
/// one-decimal readings from OAuth's whole numbers: `bucketSources`, additive, nil when no
/// window says, and a record from before it reads as OAuth.
final class HistoryRecordSourceTests: XCTestCase {
    private var directory: URL!

    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRecordSourceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fedClaude() -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 23.5, kind: .session, source: .statusLine),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 41, kind: .weekly),
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, kind: .modelSpecific),
            ],
            at: now
        )
    }

    func testARecordKeepsWhichWindowsTheStatusLineFed() {
        let record = HistoryRecord(from: fedClaude(), at: now)

        XCTAssertEqual(record.bucketSources, ["five_hour": "statusLine"])
        XCTAssertEqual(record.source(for: "five_hour"), .statusLine)
        XCTAssertEqual(record.source(for: "seven_day"), .oauth)
        XCTAssertEqual(record.source(for: "seven_day_opus"), .oauth)
    }

    func testARecordWithNoTaggedWindowStoresNoSources() {
        let record = HistoryRecord(
            from: Fixture.snapshot(id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)]),
            at: now
        )

        XCTAssertNil(record.bucketSources)
        XCTAssertEqual(record.source(for: "codex_session"), .oauth)
    }

    func testARecordFromBeforeTheTagDecodesAndReadsAsOAuth() throws {
        let legacy = """
        {"id":"7C6DEC8E-0F71-4E27-9C2C-1F7A1E9A0005",
         "timestamp":"2026-09-06T11:20:00Z",
         "fiveHourPercent":23.0,
         "sevenDayPercent":41.0,
         "bucketPercents":{"five_hour":23.0,"seven_day":41.0}}
        """

        let record = try Self.decoder.decode(HistoryRecord.self, from: Data(legacy.utf8))

        XCTAssertNil(record.bucketSources)
        XCTAssertEqual(record.source(for: "five_hour"), .oauth)
        XCTAssertEqual(record.percent(for: "five_hour"), 23)
    }

    func testTheSourcesSurviveTheLog() async {
        let fixed = now
        await HistoryStore(directory: directory, now: { fixed }).append(snapshot: fedClaude())

        let reread = await HistoryStore(directory: directory, now: { fixed }).all(service: "claude")

        XCTAssertEqual(reread.map(\.bucketSources), [["five_hour": "statusLine"]])
    }
}
