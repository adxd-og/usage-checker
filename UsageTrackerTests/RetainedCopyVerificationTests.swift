import XCTest
@testable import Omelette

/// Independent verification of `RetainedCopy` / `RelativeStamp` / `ServiceSnapshot.isRetained`,
/// probing edges the executor's own `RetainedCopyTests.swift` left alone: a year
/// boundary, a whitespace-only state message, and the three isRetained truth-table
/// rows called out in the verification brief.
final class RetainedCopyVerificationTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - RelativeStamp across a year boundary

    func testAYearBoundaryStillCountsAsADifferentDay() {
        let at = moment(year: 2025, month: 12, day: 31, hour: 23, minute: 50)
        let now = moment(year: 2026, month: 1, day: 1, hour: 0, minute: 10)
        let stamp = RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(stamp.hasPrefix("23:50") && stamp.count == 5,
                       "a reading from Dec 31 read on Jan 1 must carry its day, not look like a bare time: \(stamp)")
    }

    // MARK: - caption: a whitespace-only stateMessage behaves like no message

    func testCaptionTreatsAWhitespaceOnlyMessageAsNoMessage() {
        let at = moment(year: 2026, month: 9, day: 5, hour: 14, minute: 5)
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning, stateMessage: "   \n  ",
            at: at
        )
        let caption = RetainedCopy.caption(for: service,
                                           now: moment(year: 2026, month: 9, day: 5, hour: 17, minute: 40),
                                           calendar: calendar, locale: locale)
        XCTAssertEqual(caption, "Last known values from 14:05",
                       "a whitespace-only stateMessage should not produce a dangling dash")
    }

    // MARK: - isRetained truth table

    func testOkWithBucketsIsNeverRetained() {
        let s = Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 40)], state: .ok)
        XCTAssertFalse(s.isRetained)
    }

    func testErrorWithBucketsIsRetained() {
        let s = Fixture.snapshot(id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 40)],
                                 state: .error, stateMessage: "boom")
        XCTAssertTrue(s.isRetained)
        XCTAssertNotNil(s.retainedAt)
    }

    func testNotRunningWithEmptyBucketsIsNotRetained() {
        let s = Fixture.snapshot(id: "antigravity", buckets: [], state: .notRunning)
        XCTAssertFalse(s.isRetained)
        XCTAssertNil(s.retainedAt)
    }

    // MARK: - chipText covers every state exactly once, with no silent fallthrough

    func testChipTextIsDistinctForEveryNonOkState() {
        let states: [ServiceState] = [.notSignedIn, .notRunning, .error]
        let words = Set(states.map(RetainedCopy.chipText(for:)))
        XCTAssertEqual(words.count, states.count, "each failure state must have its own word, not a shared fallback")
    }
}
