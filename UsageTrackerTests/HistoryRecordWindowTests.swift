import XCTest
@testable import Omelette

/// What a history record keeps of a window besides its percent: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds (a past
/// window runs between two resets). Readings that report one reset are one window, as long
/// as its readings said. Claude's records always kept the session's and the week's reset in
/// their own fields; Codex's kept none, and no record kept a length, until now.
final class HistoryRecordWindowTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

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

    func testACodexRecordKeepsItsWindowsResetAndLengthThroughTheLog() throws {
        // Codex Free's "weekly" window that runs 30 days.
        let month = Fixture.bucket(
            id: "codex_weekly", label: "Monthly", percent: 19, resetsAt: now.addingTimeInterval(6 * day),
            kind: .weekly, windowLength: 30 * day
        )
        let record = HistoryRecord(from: Fixture.snapshot(id: "codex", plan: "Codex Free", buckets: [month]), at: now)

        let decoded = try Self.decoder.decode(HistoryRecord.self, from: Self.encoder.encode(record))

        XCTAssertEqual(decoded.resetsAt(for: "codex_weekly"), now.addingTimeInterval(6 * day))
        XCTAssertEqual(decoded.windowLength(for: "codex_weekly"), 30 * day)
        XCTAssertEqual(decoded, record)
    }

    func testClaudesSessionAndWeekKeepTheirResetsInTheirOwnFieldsAndOnlyTheirLengthsHere() throws {
        let claude = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", percent: 9, resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "seven_day", percent: 40, resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
        let record = HistoryRecord(from: claude, at: now)

        XCTAssertEqual(record.resetsAt(for: "five_hour"), now.addingTimeInterval(hour))
        XCTAssertEqual(record.resetsAt(for: "seven_day"), now.addingTimeInterval(2 * day))
        XCTAssertEqual(record.windowLength(for: "five_hour"), 5 * hour)
        XCTAssertEqual(record.windowLength(for: "seven_day"), 7 * day)
        XCTAssertEqual(record.bucketWindows, [
            "five_hour": HistoryWindow(resetsAt: nil, length: 5 * hour),
            "seven_day": HistoryWindow(resetsAt: nil, length: 7 * day),
        ], "the resets already have their own fields and are not written twice")
    }

    func testAWindowThatIsNotOpenHasNoResetTimeButKeepsItsLength() throws {
        // 2026-10-05 11:30:53 on this Mac: no session open, `fiveHourResetsAt` reads 4001-01-01.
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.sessionEndingAtTwoPercent)
        let idle = try XCTUnwrap(records.first { $0.fiveHourResetsAt == .distantFuture })
        XCTAssertNil(idle.resetsAt(for: "five_hour"))
        XCTAssertEqual(idle.resetsAt(for: "seven_day"), Date(timeIntervalSince1970: 1_791_453_600), "2026-10-08 10:00 UTC")

        let unopened = HistoryRecord(
            from: Fixture.snapshot(id: "codex", buckets: [Fixture.bucket(id: "codex_weekly", percent: 0, kind: .weekly)]),
            at: now
        )
        XCTAssertNil(unopened.resetsAt(for: "codex_weekly"))
        XCTAssertEqual(unopened.windowLength(for: "codex_weekly"), 7 * day, "a weekly window with no stated length is a week")
    }

    func testARecordFromBeforeWindowsWereKeptHasNoneButItsPercent() throws {
        let legacy = try XCTUnwrap(LimitHistoryFixture.records(LimitHistoryFixture.codexBeforeResetTimes).first)
        XCTAssertNil(legacy.bucketWindows)
        XCTAssertNil(legacy.resetsAt(for: "codex_weekly"))
        XCTAssertNil(legacy.windowLength(for: "codex_weekly"))
        XCTAssertEqual(legacy.percent(for: "codex_weekly"), 5)
    }

    func testOnlyTheCoreWindowsAreKept() {
        let codex = Fixture.snapshot(id: "codex", buckets: [
            Fixture.bucket(id: "codex_session", percent: 3, resetsAt: now.addingTimeInterval(hour), kind: .session),
            Fixture.bucket(id: "codex_weekly", percent: 19, resetsAt: now.addingTimeInterval(6 * day), kind: .weekly),
            Fixture.bucket(id: "codex_spark", percent: 1, resetsAt: now.addingTimeInterval(day), kind: .modelSpecific),
            Fixture.bucket(id: "codex_promo", percent: 0, resetsAt: now.addingTimeInterval(day), kind: .weekly),
        ])
        XCTAssertEqual(HistoryRecord(from: codex, at: now).bucketWindows, [
            "codex_session": HistoryWindow(resetsAt: now.addingTimeInterval(hour), length: 5 * hour),
            "codex_weekly": HistoryWindow(resetsAt: now.addingTimeInterval(6 * day), length: 7 * day),
        ], "a model-specific window and a promotional pool are not the windows the Limits tab measures")
    }
}
