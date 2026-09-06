import XCTest
@testable import Omelette

/// The reset wording each row shows, as pure rules. `ResetCopy` itself is covered by
/// `ResetCopyTests`; this file pins what the rows *compose* out of it — the percentage
/// in front, the tooltip that always names the wall-clock time, and the ring row's
/// split between a tooltip and what VoiceOver reads.
final class ResetTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC, built from components so the epoch cannot be off.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func bucket(_ percent: Double, in seconds: TimeInterval, id: String = "five_hour",
                        label: String = "Current session", kind: BucketKind = .session) -> UsageBucket {
        Fixture.bucket(id: id, label: label, percent: percent,
                       resetsAt: now.addingTimeInterval(seconds), kind: kind)
    }

    // MARK: - WindowRanking.sessionRowValue

    func testARowBeyondAnHourCarriesTheWallClockTime() {
        XCTAssertEqual(
            WindowRanking.sessionRowValue(bucket(37, in: 100 * 60), now: now, calendar: calendar, locale: locale),
            "37% · resets in 1h 40m (13:00)"
        )
    }

    func testARowInsideTheHourStaysExactlyAsShortAsItWas() {
        // The parenthesis is what could wrap a row onto a second line; within the
        // hour the countdown is the useful half anyway.
        XCTAssertEqual(
            WindowRanking.sessionRowValue(bucket(37, in: 45 * 60), now: now, calendar: calendar, locale: locale),
            "37% · resets in 45m"
        )
    }

    func testAWeeklyRowNamesTheWeekday() {
        XCTAssertEqual(
            WindowRanking.sessionRowValue(
                bucket(76, in: 4 * 86_400 + 175 * 60, id: "seven_day", label: "All models", kind: .weekly),
                now: now, calendar: calendar, locale: locale
            ),
            "76% · resets in 4d 2h (Thu 14:15)"
        )
    }

    func testAPassedWindowSaysResetsNow() {
        XCTAssertEqual(
            WindowRanking.sessionRowValue(bucket(12, in: -5), now: now, calendar: calendar, locale: locale),
            "12% · resets now"
        )
    }

    func testAWindowWithNoResetTimeIsJustAPercentage() {
        let unknown = Fixture.bucket(id: "seven_day_sonnet", label: "Sonnet only", percent: 0,
                                     resetsAt: .distantFuture, kind: .modelSpecific)
        XCTAssertEqual(
            WindowRanking.sessionRowValue(unknown, now: now, calendar: calendar, locale: locale),
            "0%"
        )
    }

    func testThePercentageIsRoundedAndClamped() {
        let over = Fixture.bucket(id: "five_hour", percent: 130, resetsAt: .distantFuture, kind: .session)
        XCTAssertEqual(WindowRanking.sessionRowValue(over, now: now, calendar: calendar, locale: locale), "100%")
    }

    // MARK: - OMRingRow

    func testTheRingTooltipNamesTheWallClockTimeAndNothingElse() {
        let weekly = bucket(52, in: 4 * 86_400 + 175 * 60, id: "seven_day", label: "All models", kind: .weekly)
        XCTAssertEqual(
            OMRingRow.tooltip(for: weekly, now: now, calendar: calendar, locale: locale),
            "All models · resets Thu 14:15"
        )
    }

    func testAnUntouchedRingExplainsItselfInTheTooltip() {
        let unused = bucket(0, in: 4 * 86_400, id: "seven_day_opus", label: "Opus only", kind: .modelSpecific)
        XCTAssertTrue(
            OMRingRow.tooltip(for: unused, now: now, calendar: calendar, locale: locale)
                .hasPrefix("You haven't used Opus yet · resets "),
            OMRingRow.tooltip(for: unused, now: now, calendar: calendar, locale: locale)
        )
        XCTAssertEqual(OMRingRow.emptyHint(for: unused), "You haven't used Opus yet")
    }

    func testARingWithNoResetTimeHasATooltipOfJustItsTitle() {
        let unknown = Fixture.bucket(id: "seven_day_cowork", label: "Cowork", percent: 44,
                                     resetsAt: .distantFuture, kind: .modelSpecific)
        XCTAssertEqual(OMRingRow.tooltip(for: unknown, now: now, calendar: calendar, locale: locale), "Cowork")
    }

    func testVoiceOverKeepsTheFullDate() {
        // A screen reader cannot glance at a menu bar to work out which Thursday
        // "Thu 14:15" means, so the accessibility text keeps the abbreviated date it
        // has always read.
        let weekly = bucket(52, in: 4 * 86_400 + 175 * 60, id: "seven_day", label: "All models", kind: .weekly)
        let text = OMRingRow.accessibilityText(for: weekly)
        XCTAssertTrue(text.hasPrefix("All models · resets "), text)
        XCTAssertTrue(text.contains("2026"), "the accessibility text keeps a full date: \(text)")
    }
}
