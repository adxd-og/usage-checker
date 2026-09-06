import XCTest
@testable import Omelette

/// Independent verification of the fix batch 35db235..d54ddb4 against
/// `RelativeStamp.asOf` and `RetainedCopy.caption` (item 12 of the batch brief): a
/// reading 366 days back (guaranteed to cross a year boundary) against one 300 days
/// back from the same "now" (which, chosen close to year's end, does not), and the
/// exact 120/121-character boundary of the caption's message cap — the executor's
/// own test only tried a message of 400 characters, well past the cap either way.
final class RetainedCopyVerification2Tests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func retained(at date: Date, message: String?) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning, stateMessage: message, at: date
        )
    }

    // MARK: - 366 days back always crosses a year; 300 from the same "now" need not

    func test366DaysBackFromLateDecemberCarriesTheYear() {
        let now = moment(2026, 12, 30)
        let at = calendar.date(byAdding: .day, value: -366, to: now)!
        let stamp = RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
        let year = calendar.component(.year, from: at)
        XCTAssertTrue(stamp.contains(String(year)), "366 days is always a different year: \(stamp)")
    }

    func test300DaysBackFromTheSameLateDecemberNowStaysWithinTheYearAndOmitsIt() {
        // From Dec 30, 300 days back lands in early March of the *same* year — the
        // component-based year check must say so correctly rather than assuming any
        // reading more than ~300 days old must be from last year.
        let now = moment(2026, 12, 30)
        let at = calendar.date(byAdding: .day, value: -300, to: now)!
        XCTAssertEqual(calendar.component(.year, from: at), calendar.component(.year, from: now), "test setup sanity")
        let stamp = RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(stamp.contains("2026"), "same calendar year as \"now\" — the year must not be spelled out: \(stamp)")
    }

    // MARK: - The 120-character message cap, exactly at and one past the boundary

    func testAMessageOfExactlyOneHundredTwentyCharactersIsNotCut() {
        let message = String(repeating: "x", count: 120)
        let caption = RetainedCopy.caption(
            for: retained(at: moment(2026, 9, 5, 14, 5), message: message),
            now: moment(2026, 9, 5, 17, 40),
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(caption, "Last known values from 14:05 — \(message)", "exactly at the cap must not be shortened")
    }

    func testAMessageOfOneHundredTwentyOneCharactersIsCutToExactlyOneHundredTwenty() throws {
        let message = String(repeating: "x", count: 121)
        let caption = try XCTUnwrap(RetainedCopy.caption(
            for: retained(at: moment(2026, 9, 5, 14, 5), message: message),
            now: moment(2026, 9, 5, 17, 40),
            calendar: calendar, locale: locale
        ))
        let shown = try XCTUnwrap(caption.components(separatedBy: " — ").last)
        XCTAssertEqual(shown.count, 120, "one character over the cap must still land on exactly the cap length")
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual(shown, String(repeating: "x", count: 119) + "…")
    }
}
