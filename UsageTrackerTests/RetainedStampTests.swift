import XCTest
@testable import Omelette

/// The "as of" phrase, declared in CLICore so the `omelette` status line can say it too.
/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "Status line: … the text says how old it is (via `RetainedCopy`)". The tile's chip
/// suffix must stay exactly this phrase with a dot in front.
final class RetainedStampTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testTodaysReadingIsAsOfItsTime() {
        let phrase = RetainedCopy.asOf(
            moment(day: 5, hour: 14, minute: 5), now: moment(day: 5, hour: 17, minute: 40),
            calendar: calendar, locale: locale
        )
        XCTAssertEqual(phrase, "as of 14:05")
    }

    func testAnOlderReadingKeepsItsDay() {
        let at = moment(day: 5, hour: 14, minute: 5)
        let now = moment(day: 6, hour: 9, minute: 0)
        let phrase = RetainedCopy.asOf(at, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(phrase, "as of \(RelativeStamp.asOf(at, now: now, calendar: calendar, locale: locale))")
        XCTAssertNotEqual(phrase, "as of 14:05", "a time alone on yesterday's numbers is a lie")
    }

    func testTheTileSuffixIsThePhraseWithADot() {
        let at = moment(day: 5, hour: 14, minute: 5)
        let now = moment(day: 5, hour: 17, minute: 40)
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning, at: at
        )
        XCTAssertEqual(
            RetainedCopy.chipSuffix(for: service, now: now, calendar: calendar, locale: locale),
            "· " + RetainedCopy.asOf(at, now: now, calendar: calendar, locale: locale)
        )
    }
}
