import XCTest
@testable import Omelette

/// What a history reading keeps of its windows across the log on disk: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds (a past
/// window has the length its readings recorded; legacy records without one use the live
/// bucket's). The store writes ISO 8601 dates and reads them back on the next launch.
final class HistoryRecordWindowsVerificationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRecordWindowsVerificationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAReadingKeepsItsResetsAndLengthsAcrossTheLogOnDisk() async throws {
        let now = Date()
        let codexReset = now.addingTimeInterval(3 * 86_400 + 0.5)
        let claude = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", percent: 0, kind: .session),                       // no session open
            Fixture.bucket(id: "seven_day", percent: 40, resetsAt: now.addingTimeInterval(2 * 86_400), kind: .weekly),
        ])
        let codex = Fixture.snapshot(id: "codex", buckets: [
            Fixture.bucket(id: "codex_weekly", percent: 19, resetsAt: codexReset, kind: .weekly, windowLength: 30 * 86_400),
        ])
        let store = HistoryStore(directory: directory)
        await store.append(snapshot: claude)
        await store.append(snapshot: codex)

        let relaunched = HistoryStore(directory: directory)
        let claudeRecords = await relaunched.records(since: now.addingTimeInterval(-60), service: "claude")
        let codexRecords = await relaunched.records(since: now.addingTimeInterval(-60), service: "codex")
        let claudeRecord = try XCTUnwrap(claudeRecords.first)
        let codexRecord = try XCTUnwrap(codexRecords.first)

        XCTAssertNil(claudeRecord.resetsAt(for: "five_hour"), "no session open: the reset is Date.distantFuture")
        XCTAssertEqual(claudeRecord.windowLength(for: "five_hour"), 5 * 3_600)
        XCTAssertEqual(claudeRecord.resetsAt(for: "seven_day")?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(2 * 86_400).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(claudeRecord.windowLength(for: "seven_day"), 7 * 86_400)
        XCTAssertEqual(codexRecord.resetsAt(for: "codex_weekly")?.timeIntervalSince1970 ?? 0,
                       codexReset.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(codexRecord.windowLength(for: "codex_weekly"), 30 * 86_400, "the length the bucket stated")
    }

    func testARecordFromBeforeWindowsWereKeptHasNoLengthAndNoCodexReset() throws {
        let lines = try LimitHistoryFixture.records(LimitHistoryFixture.codexBeforeResetTimes)
        XCTAssertNil(lines.first?.resetsAt(for: "codex_weekly"))
        XCTAssertNil(lines.first?.windowLength(for: "codex_weekly"))
        let after = try LimitHistoryFixture.records(LimitHistoryFixture.codexAfterResetTimes)
        XCTAssertEqual(after.first?.windowLength(for: "codex_weekly"), 604_800)
        XCTAssertEqual(after.first?.resetsAt(for: "codex_weekly"), ISO8601DateFormatter().date(from: "2026-10-22T13:00:48Z"))
    }
}
