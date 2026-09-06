import XCTest
@testable import Omelette

/// Independent verification of the reset-time wording (spec: "the parenthesis only
/// beyond one hour, so nothing on screen gets taller") at the exact boundary the
/// executor's `ResetCopyTests` / `ResetTextTests` do not pin (they test 45m and
/// 100m, never the second the rule flips), and of the "no reset time" composition
/// that must never print a literal "(nil)" anywhere.
final class ResetTextVerificationTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Same fixture instant as ResetCopyTests/ResetTextTests: Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    // MARK: - The exact 3600s / 3601s boundary

    func testAtExactlyOneHourTheParenthesisIsStillOmitted() {
        XCTAssertEqual(
            ResetCopy.both(resetsAt: now.addingTimeInterval(3600), now: now, calendar: calendar, locale: locale),
            "resets in 1h 0m",
            "the rule is a strict '> 3600', so exactly one hour is still inside the short form"
        )
    }

    func testOneSecondPastTheHourGainsTheParenthesis() {
        XCTAssertEqual(
            ResetCopy.both(resetsAt: now.addingTimeInterval(3601), now: now, calendar: calendar, locale: locale),
            "resets in 1h 0m (12:20)"
        )
    }

    func testWindowRankingSessionRowValueCarriesTheSameBoundary() {
        // WindowRanking.sessionRowValue composes ResetCopy.both directly; the boundary
        // must not shift when a percentage is prefixed in front of it.
        let atHour = Fixture.bucket(id: "five_hour", percent: 50, resetsAt: now.addingTimeInterval(3600), kind: .session)
        let pastHour = Fixture.bucket(id: "five_hour", percent: 50, resetsAt: now.addingTimeInterval(3601), kind: .session)
        XCTAssertEqual(WindowRanking.sessionRowValue(atHour, now: now, calendar: calendar, locale: locale), "50% · resets in 1h 0m")
        XCTAssertEqual(WindowRanking.sessionRowValue(pastHour, now: now, calendar: calendar, locale: locale), "50% · resets in 1h 0m (12:20)")
    }

    // MARK: - Percentage clamping at the other end (below 0)

    func testANegativePercentClampsToZeroInTheRow() {
        let negative = Fixture.bucket(id: "five_hour", percent: -12, resetsAt: .distantFuture, kind: .session)
        XCTAssertEqual(WindowRanking.sessionRowValue(negative, now: now, calendar: calendar, locale: locale), "0%")
    }

    // MARK: - "no reset time" never prints anything resembling "(nil)"

    func testAnUntouchedRingWithNoResetTimeHasATooltipOfJustTheEmptyHint() {
        // OMRingRow.tooltip's title branch (percent == 0 → emptyHint) and its reset
        // branch (no absolute time → title alone) compose independently; this is the
        // combination neither ResetTextTests case exercises.
        let untouchedUnknown = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 0,
                                              resetsAt: .distantFuture, kind: .modelSpecific)
        let tooltip = OMRingRow.tooltip(for: untouchedUnknown, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(tooltip, "You haven't used Opus yet")
        XCTAssertFalse(tooltip.lowercased().contains("nil"), tooltip)
    }

    func testTheResetTooltipHelperOnAnUnknownWindowIsEmptyNotNil() {
        // The exact expression PopoverView/OMHero use for `.help(...)`:
        // `ResetCopy.absolute(...).map { "Resets \($0)" } ?? ""`. AppKit's own way of
        // saying "no tooltip" is an empty string; this must never be the literal text
        // "Resets " with nothing after it, and never contain "nil".
        let help = ResetCopy.absolute(resetsAt: .distantFuture, now: now, calendar: calendar, locale: locale)
            .map { "Resets \($0)" } ?? ""
        XCTAssertEqual(help, "")
    }

    func testSessionRowValueOnAnUnknownWindowIsJustThePercentage() {
        let unknown = Fixture.bucket(id: "seven_day_cowork", label: "Cowork", percent: 44,
                                     resetsAt: .distantFuture, kind: .modelSpecific)
        let value = WindowRanking.sessionRowValue(unknown, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(value, "44%")
        XCTAssertFalse(value.contains("nil"), value)
    }
}
