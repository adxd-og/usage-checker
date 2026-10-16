import XCTest
@testable import Omelette

/// A past window's share: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design, Window bounds ("a past window: between two resets") and Totals ("chat shares
/// plus Outside equal the window's percent"). A past window found by its reset is made of
/// the readings that named that reset, whenever the poll stamped them; a reading that named
/// another reset is another window's even inside this one's span; a reading that named none
/// counts by its time.
final class LimitPastWindowShareTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private func percent(of past: LimitPastWindow, _ records: [HistoryRecord]) -> Double? {
        LimitShareRules.share(
            for: LimitShareRules.request(for: past, bucketID: "five_hour"), log: TurnCostLog(), readings: records
        )?.percent
    }

    func testBothSessionsAroundAnEarlyResetEndAtThePercentTheirOwnReadingsReported() throws {
        // 2026-10-12: 97 % at 13:19:33 and 99 % at 13:20:07 name the 15:00 reset; from
        // 13:20:42 the readings name 18:20, the session that began at 13:20:00.
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.restoreAndEarlyReset)
        let past = LimitShareRules.pastWindows(
            records: records, bucketID: "five_hour", windowLength: 5 * hour,
            before: at("2026-10-12T19:00:00Z"), horizonStart: at("2026-09-12T00:00:00Z")
        )
        XCTAssertEqual(past.map(\.window), [
            LimitWindow(start: at("2026-10-12T13:20:00Z"), end: at("2026-10-12T18:20:00Z")),
            LimitWindow(start: at("2026-10-12T10:00:00Z"), end: at("2026-10-12T13:20:00Z")),
        ])
        XCTAssertEqual(
            past.map { percent(of: $0, records) }, [15, 99],
            "the 99 % stamped seven seconds after 13:20 is the earlier session's last reading"
        )
    }

    func testAReadingThatNamedAnotherResetIsNotThisWindowsEvenInsideItsSpan() {
        let reset = at("2026-10-05T12:00:00Z")
        let other = reset.addingTimeInterval(4 * hour)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: reset.addingTimeInterval(-4 * hour), percent: 10, resetsAt: reset),
            (at: reset.addingTimeInterval(-1 * hour), percent: 20, resetsAt: reset),
            (at: reset.addingTimeInterval(-30 * 60), percent: 60, resetsAt: other),
        ])
        let past = LimitPastWindow(start: reset.addingTimeInterval(-5 * hour), end: reset, resets: reset...reset)
        XCTAssertEqual(percent(of: past, records) ?? -1, 20, accuracy: 1e-9)
    }

    func testAReadingWithNoResetCountsInAPastWindowByItsTime() {
        let reset = at("2026-10-05T12:00:00Z")
        let named = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: reset.addingTimeInterval(-4 * hour), percent: 10, resetsAt: reset),
        ])
        let unnamed = Fixture.readings(bucketID: "five_hour", points: [
            (at: reset.addingTimeInterval(-2 * hour), percent: 30),
            (at: reset.addingTimeInterval(1 * hour), percent: 50),
        ])
        let past = LimitPastWindow(start: reset.addingTimeInterval(-5 * hour), end: reset, resets: reset...reset)
        XCTAssertEqual(
            percent(of: past, named + unnamed) ?? -1, 30, accuracy: 1e-9,
            "the 30 % inside the window counts; the 50 % an hour after it does not"
        )
    }
}
