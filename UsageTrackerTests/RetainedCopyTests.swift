import XCTest
@testable import Omelette

/// The wording four surfaces share. Time formatting is the user's locale, so the
/// tests pin a calendar and a locale and check composition rather than glyphs —
/// except the one 24-hour case, which is stable.
final class RetainedCopyTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func time(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
        )
    }

    private func retained(
        at date: Date,
        state: ServiceState = .notRunning,
        message: String? = "Antigravity isn't running"
    ) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity",
            displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: state,
            stateMessage: message,
            at: date
        )
    }

    // MARK: - RelativeStamp

    func testTodaysReadingIsJustATime() {
        let at = moment(month: 9, day: 5, hour: 14, minute: 5)
        let stamp = RelativeStamp.asOf(at, now: moment(month: 9, day: 5, hour: 17, minute: 40),
                                       calendar: calendar, locale: locale)
        XCTAssertEqual(stamp, "14:05")
    }

    func testAnOlderReadingCarriesItsDay() {
        let at = moment(month: 9, day: 5, hour: 14, minute: 5)
        let stamp = RelativeStamp.asOf(at, now: moment(month: 9, day: 6, hour: 9, minute: 0),
                                       calendar: calendar, locale: locale)
        XCTAssertTrue(stamp.hasSuffix(", \(time(at))"), "got \(stamp)")
        XCTAssertGreaterThan(stamp.count, time(at).count, "\"as of 14:05\" on yesterday's numbers is worse than no stamp")
    }

    func testMidnightIsADifferentDayNotADifferentHour() {
        let at = moment(month: 9, day: 5, hour: 23, minute: 55)
        let stamp = RelativeStamp.asOf(at, now: moment(month: 9, day: 6, hour: 0, minute: 5),
                                       calendar: calendar, locale: locale)
        XCTAssertNotEqual(stamp, time(at))
    }

    // MARK: - chipText

    func testTheChipKeepsTheWordsTheAppAlreadyUses() {
        XCTAssertEqual(RetainedCopy.chipText(for: .notRunning), "Not running")
        XCTAssertEqual(RetainedCopy.chipText(for: .notSignedIn), "Sign in")
        XCTAssertEqual(RetainedCopy.chipText(for: .error), "Error")
        XCTAssertEqual(RetainedCopy.chipText(for: .ok), "No data")
    }

    // MARK: - chipSuffix

    func testTheTileChipGainsAnAsOfStamp() {
        let at = moment(month: 9, day: 5, hour: 14, minute: 5)
        let suffix = RetainedCopy.chipSuffix(for: retained(at: at),
                                             now: moment(month: 9, day: 5, hour: 17, minute: 40),
                                             calendar: calendar, locale: locale)
        XCTAssertEqual(suffix, "· as of 14:05")
    }

    func testALiveServiceGetsNoStamp() {
        let live = Fixture.snapshot(buckets: [Fixture.bucket(id: "seven_day", percent: 55)])
        XCTAssertNil(RetainedCopy.chipSuffix(for: live, calendar: calendar, locale: locale))
    }

    func testAFailureWithNoNumbersGetsNoStamp() {
        let bare = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)
        XCTAssertNil(RetainedCopy.chipSuffix(for: bare, calendar: calendar, locale: locale))
    }

    // MARK: - caption

    func testTheCaptionSaysWhenAndWhy() {
        let at = moment(month: 9, day: 5, hour: 14, minute: 5)
        let caption = RetainedCopy.caption(for: retained(at: at),
                                           now: moment(month: 9, day: 5, hour: 17, minute: 40),
                                           calendar: calendar, locale: locale)
        XCTAssertEqual(caption, "Last known values from 14:05 — Antigravity isn't running")
    }

    func testTheCaptionDropsTheDashWhenThereIsNoMessage() {
        let at = moment(month: 9, day: 5, hour: 14, minute: 5)
        let caption = RetainedCopy.caption(for: retained(at: at, message: nil),
                                           now: moment(month: 9, day: 5, hour: 17, minute: 40),
                                           calendar: calendar, locale: locale)
        XCTAssertEqual(caption, "Last known values from 14:05")
    }

    func testALiveServiceHasNoCaption() {
        let live = Fixture.snapshot(buckets: [Fixture.bucket(id: "seven_day", percent: 55)])
        XCTAssertNil(RetainedCopy.caption(for: live, calendar: calendar, locale: locale))
    }
}
