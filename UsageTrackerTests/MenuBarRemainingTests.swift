import XCTest
@testable import Omelette

/// The menu bar has room for a 22 pt bar and two digits; everything else it has to
/// say is in the status item's tooltip. Both count down when the switch is on.
/// Spec § "Surfaces that switch" — "Menu bar: MenuBarLabel (number, bar width,
/// tooltip text in StatusBarController)".
final class MenuBarRemainingTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    // MARK: - The tooltip's per-provider line

    func testALiveProviderDropsTheWordUsageAndSaysWhatIsLeft() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 37, kind: .weekly)]
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, mode: .used, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Claude usage 37%"
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, mode: .remaining, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Claude 63% left"
        )
    }

    func testARetainedProviderKeepsItsStampAndItsReason() {
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62, kind: .weekly)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running",
            at: moment(day: 5, hour: 14, minute: 5)
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, mode: .remaining, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Antigravity: last known 38% left (as of 14:05) — Not running"
        )
    }

    func testTheDefaultIsStillUsedSoNothingElseHadToChange() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 37, kind: .weekly)]
        )
        XCTAssertEqual(
            MenuBarLabel.text(for: service, now: moment(day: 5, hour: 17, minute: 40),
                              calendar: calendar, locale: locale),
            "Claude usage 37%"
        )
    }

    // MARK: - The whole tooltip

    private func snapshot(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    func testTheTooltipCountsEveryWindowDown() {
        let now = moment(day: 5, hour: 17, minute: 40)
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 18, kind: .weekly),
            ],
            weekCost: 15.6,
            at: now
        )
        let text = StatusBarController.tooltipText(
            snapshot: snapshot([claude], at: now), mode: .remaining,
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(text, """
        Max 20x
          Current session: 58% left
          All models: 82% left
          Last 7 days: $15.60

        Updated just now
        """)
    }

    func testTheTooltipReadsAsItAlwaysDidWhenTheSwitchIsOff() {
        let now = moment(day: 5, hour: 17, minute: 40)
        let claude = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)],
            at: now
        )
        let text = StatusBarController.tooltipText(
            snapshot: snapshot([claude], at: now), mode: .used,
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(text.contains("  Current session: 42%"), text)
        XCTAssertFalse(text.contains("left"), "used mode adds no word: \(text)")
    }

    func testAnUntouchedWeeklyIsStillHiddenWhenTheAppCountsDown() {
        // Which windows appear is a question about usage: a window nobody has
        // touched is still the untouched one at "100% left".
        let now = moment(day: 5, hour: 17, minute: 40)
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session),
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 0, kind: .modelSpecific),
            ],
            at: now
        )
        let text = StatusBarController.tooltipText(
            snapshot: snapshot([service], at: now), mode: .remaining,
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertFalse(text.contains("Opus only"), "an untouched window must not appear as 100% left: \(text)")
    }

    func testARetainedProviderHeadsItsBlockWithTheLastKnownLine() {
        let now = moment(day: 5, hour: 17, minute: 40)
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", plan: "Pro",
            buckets: [Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62, kind: .weekly)],
            state: .notRunning,
            at: moment(day: 5, hour: 14, minute: 5)
        )
        let text = StatusBarController.tooltipText(
            snapshot: snapshot([service], at: moment(day: 5, hour: 14, minute: 5)),
            mode: .remaining, now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(text.hasPrefix("Antigravity: last known 38% left (as of 14:05) — Not running"), text)
        XCTAssertTrue(text.contains("  Gemini models: 38% left"), text)
    }

    func testNothingReportingYetIsTheLoadingLine() {
        let now = moment(day: 5, hour: 17, minute: 40)
        XCTAssertEqual(
            StatusBarController.tooltipText(snapshot: snapshot([], at: now), mode: .remaining, now: now,
                                            calendar: calendar, locale: locale),
            "Omelette — loading…"
        )
    }
}
