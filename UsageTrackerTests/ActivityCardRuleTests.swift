import XCTest
@testable import Omelette

/// The cutoffs behind Dashboard → Activity's three cost cards.
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md § Cards.
final class ActivityCardRuleTests: XCTestCase {
    /// 2026-09-06 12:00 UTC — a Sunday, and midday, so a cutoff computed by
    /// subtracting seconds instead of days would still land on the right date and
    /// these tests would prove nothing. The DST case at the bottom is where it shows.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func day(_ text: String, in calendar: Calendar) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)!
    }

    func testEveryCutoffIsADayStart() {
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)
        for cutoff in [c.thirty, c.ninety, c.year] {
            XCTAssertEqual(cal.startOfDay(for: cutoff), cutoff)
        }
    }

    /// "Last 30 days" means thirty calendar days ending today, so the cutoff is the
    /// start of the day 29 days back — not this time of day 30 days back, which used
    /// to drop the boundary day's whole total.
    func testACardCoversItsDaysEndingToday() {
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)
        XCTAssertEqual(c.thirty, day("2026-08-08", in: cal))
        XCTAssertEqual(c.ninety, day("2026-06-09", in: cal))
        XCTAssertEqual(c.year, day("2025-09-07", in: cal))
    }

    func testTheBoundaryDayIsInsideItsCard() {
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)
        XCTAssertGreaterThanOrEqual(day("2026-08-08", in: cal), c.thirty)
        XCTAssertGreaterThanOrEqual(day("2026-06-09", in: cal), c.ninety)
        XCTAssertGreaterThanOrEqual(day("2025-09-07", in: cal), c.year)
    }

    func testTodayIsInsideEveryCard() {
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)
        let today = cal.startOfDay(for: now)
        XCTAssertGreaterThanOrEqual(today, c.thirty)
        XCTAssertGreaterThanOrEqual(today, c.ninety)
        XCTAssertGreaterThanOrEqual(today, c.year)
    }

    func testADayThirtyDaysAgoIsOutOfTheThirtyDayCardAndInsideTheNinety() {
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)
        let thirtyBack = day("2026-08-07", in: cal)
        XCTAssertLessThan(thirtyBack, c.thirty)
        XCTAssertGreaterThanOrEqual(thirtyBack, c.ninety)
    }

    /// The year cutoff crosses two daylight-saving changes. Subtracting 364 x 86 400
    /// seconds lands an hour off and, for a `now` near midnight, on the wrong date;
    /// calendar day arithmetic cannot.
    func testACutoffCrossingDaylightSavingIsStillTheRightDayStart() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Vilnius")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)

        for cutoff in [c.thirty, c.ninety, c.year] {
            XCTAssertEqual(cal.startOfDay(for: cutoff), cutoff)
        }
        XCTAssertEqual(cal.dateComponents([.day], from: c.year, to: cal.startOfDay(for: now)).day, 364)
        XCTAssertEqual(cal.dateComponents([.day], from: c.ninety, to: cal.startOfDay(for: now)).day, 89)
        XCTAssertEqual(cal.dateComponents([.day], from: c.thirty, to: cal.startOfDay(for: now)).day, 29)
    }
}
