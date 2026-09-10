import XCTest
@testable import Omelette

/// The popover: the hero ring's spoken line, the All-tab tile, the weekly ring row
/// and the session row's trailing value. Spec § "Surfaces that switch" — "Popover:
/// PopoverView rows, OMRingRow, OMProviderTile (ring, secondary line "All 52%"),
/// OMHero".
final class PopoverRemainingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    // MARK: - OMHero

    func testTheHeroSaysWhatIsLeftAndStillCallsItAlmostAtTheLimit() {
        let hero = Fixture.bucket(id: "seven_day", label: "All models", percent: 93, kind: .weekly)
        XCTAssertEqual(
            OMHero.accessibilityText(for: hero, mode: .used),
            "All models, 93 percent used, Almost at the limit"
        )
        // The phrase and the colour are the warning; only the number turns around.
        XCTAssertEqual(
            OMHero.accessibilityText(for: hero, mode: .remaining),
            "All models, 7 percent left, Almost at the limit"
        )
    }

    func testTheHerosPhraseIsStillDecidedByUsage() {
        XCTAssertEqual(OMHero.statusPhrase(93), "Almost at the limit")
        XCTAssertEqual(OMHero.statusPhrase(7), "Plenty of headroom")
    }

    // MARK: - OMProviderTile

    func testTheTileTellsVoiceOverWhatIsLeft() {
        let hero = Fixture.bucket(id: "seven_day", label: "All models", percent: 55, kind: .weekly)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [hero])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero, mode: .remaining),
            "Claude, All models 45 percent left"
        )
    }

    func testARetainedTileStillSaysTheNumbersAreOld() {
        let hero = Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62)
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", buckets: [hero],
            state: .notRunning, stateMessage: "Antigravity isn't running"
        )
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero, mode: .remaining),
            "Antigravity, Gemini models 38 percent left, last known, Not running"
        )
    }

    func testTheTilesDefaultIsStillUsedSoTheOlderTestsStillHold() {
        let hero = Fixture.bucket(id: "seven_day", label: "All models", percent: 55, kind: .weekly)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [hero])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero),
            "Claude, All models 55 percent used"
        )
    }

    // MARK: - OMRingRow

    func testAWeeklyRingReadsItsWindowAndThenItsNumber() {
        let weekly = Fixture.bucket(
            id: "seven_day", label: "All models", percent: 52,
            resetsAt: now.addingTimeInterval(3 * 24 * 3600), kind: .weekly
        )
        let label = OMRingRow.accessibilityLabel(for: weekly, mode: .remaining)
        XCTAssertTrue(label.hasPrefix("All models · resets "), label)
        XCTAssertTrue(label.hasSuffix(", 48 percent left"), label)
    }

    func testAnUntouchedRingStillExplainsItselfRatherThanClaimingAFullTank() {
        // "You haven't used Opus yet" is decided on the used value; a 0%-used window
        // must not read as "100 percent left, Opus only".
        let unused = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 0, kind: .modelSpecific)
        let label = OMRingRow.accessibilityLabel(for: unused, mode: .remaining)
        XCTAssertTrue(label.hasPrefix("You haven't used Opus yet"), label)
        XCTAssertEqual(OMRingRow.emptyHint(for: unused), "You haven't used Opus yet")
    }

    // MARK: - WindowRanking.sessionRowValue

    func testASessionRowCountsDownAndKeepsItsReset() {
        let bucket = Fixture.bucket(
            id: "five_hour", label: "Current session", percent: 37,
            resetsAt: now.addingTimeInterval(100 * 60), kind: .session
        )
        XCTAssertEqual(
            WindowRanking.sessionRowValue(bucket, mode: .used, now: now, calendar: calendar, locale: locale),
            "37% · resets in 1h 40m (13:00)"
        )
        XCTAssertEqual(
            WindowRanking.sessionRowValue(bucket, mode: .remaining, now: now, calendar: calendar, locale: locale),
            "63% · resets in 1h 40m (13:00)"
        )
    }

    func testAWindowWithNoResetIsJustItsNumber() {
        let unknown = Fixture.bucket(id: "extra_usage", label: "Spend limit", percent: 25, kind: .other)
        XCTAssertEqual(
            WindowRanking.sessionRowValue(unknown, mode: .remaining, now: now, calendar: calendar, locale: locale),
            "75%"
        )
    }

    func testAWindowPastItsLimitHasNothingLeft() {
        let over = Fixture.bucket(id: "extra_usage", label: "Spend limit", percent: 137, kind: .other)
        XCTAssertEqual(
            WindowRanking.sessionRowValue(over, mode: .remaining, now: now, calendar: calendar, locale: locale),
            "0%"
        )
    }
}
