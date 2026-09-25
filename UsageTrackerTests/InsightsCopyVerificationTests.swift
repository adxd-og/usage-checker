import XCTest
@testable import Omelette

/// Independent verification of `InsightsCopy` against the liquid-glass spec (§ Screens,
/// "Insights") and the P6 plan's session rulings 4 and 8. Written from the spec and the
/// diff, not from the executor's `InsightsCopyTests.swift`.
final class InsightsCopyVerificationTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    // MARK: - Days at limit

    /// The upper boundary: every one of the seven days observed and every one at the
    /// limit still reads "7 of 7", not clamped or worded differently at the ceiling.
    func testDaysAtLimitValueAtTheCeilingReadsSevenOfSeven() {
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 7, observed: 7, span: 7)),
            "7 of 7"
        )
    }

    /// `daysAtLimitValue` reads only `observed`, never `atCapacity`, to decide the dash:
    /// even a (production-impossible) state where `atCapacity` is nonzero but `observed`
    /// is zero must still show "—", because the dash is "was any of the seven days seen
    /// at all", not "were any found at capacity".
    func testDaysAtLimitValueDashDependsOnObservedNotAtCapacity() {
        XCTAssertEqual(
            InsightsCopy.daysAtLimitValue(QuotaDaysAtCapacity(atCapacity: 0, observed: 0, span: 7)),
            InsightsCopy.noValue
        )
    }

    // MARK: - This week vs last (session ruling 8: flat week, no arrow)

    /// A perfectly flat week — this week's dollars equal last week's, not merely a
    /// change that rounds away — reads "0%" with no up/down arrow.
    func testAPerfectlyFlatWeekReadsZeroPercentWithNoArrow() {
        let flat = WeekOverWeek(thisWeek: 842.10, lastWeek: 842.10)

        XCTAssertEqual(InsightsCopy.weekDelta(flat), "0%")
        XCTAssertFalse(InsightsCopy.weekDelta(flat)?.contains("↑") ?? false)
        XCTAssertFalse(InsightsCopy.weekDelta(flat)?.contains("↓") ?? false)
    }

    // MARK: - Empty session window (session ruling 4: provider-aware copy)

    /// The three branches independently: Claude names the Claude apps, Codex names
    /// another Codex client, and every other provider id falls through to the neutral
    /// sentence rather than crashing or naming Claude/Codex by mistake.
    func testEmptySessionCopyIsProviderAwareAcrossAllThreeBranches() {
        let claude = InsightsCopy.emptySession(providerID: "claude")
        let codex = InsightsCopy.emptySession(providerID: "codex")
        let grok = InsightsCopy.emptySession(providerID: "grok")
        let antigravity = InsightsCopy.emptySession(providerID: "antigravity")
        let unknown = InsightsCopy.emptySession(providerID: "not-a-real-provider-id")

        XCTAssertTrue(claude.contains("Claude"))
        XCTAssertTrue(codex.contains("Codex"))
        // Every provider without its own sentence gets the identical neutral one, not a
        // string built from its id (which would produce ungrammatical copy for ids like
        // "antigravity" or a typo).
        XCTAssertEqual(grok, antigravity)
        XCTAssertEqual(grok, unknown)
        XCTAssertFalse(grok.contains("Claude"))
        XCTAssertFalse(grok.contains("Codex"))
        // All three are distinct sentences, not the same string for everyone.
        XCTAssertNotEqual(claude, codex)
        XCTAssertNotEqual(claude, grok)
        XCTAssertNotEqual(codex, grok)
    }

    // MARK: - "since" and the busiest hour share one time style

    /// The spec's brief: `since` (the session window's start) and `hour` (the busiest
    /// quota hour) must print the same style of clock time for the same instant, in both
    /// the 24-hour (en_GB) and 12-hour (en_US) conventions — not just "both call
    /// DateFormatter" but the actual digits matching.
    func testSinceAndHourAgreeOnTheSameInstantInBothClockConventions() {
        for locale in [Locale(identifier: "en_GB"), Locale(identifier: "en_US")] {
            let sinceText = InsightsCopy.since(
                DateComponents(calendar: utc, timeZone: utc.timeZone, year: 2026, month: 1, day: 15, hour: 14).date!,
                calendar: utc, locale: locale
            )
            let hourText = InsightsCopy.hour(14, calendar: utc, locale: locale)

            // "since 14:00" / "since 2:00 PM": strip the "since " prefix to compare the
            // clock-time rendering itself against `hour`'s.
            XCTAssertTrue(sinceText.hasPrefix("since "))
            let sinceClock = String(sinceText.dropFirst("since ".count))
            XCTAssertEqual(sinceClock, hourText, "mismatched style for locale \(locale.identifier)")
        }
    }

    /// The en_GB rendering is 24-hour ("14:00"), the en_US rendering is 12-hour with a
    /// meridiem ("2:00 PM") — pinning the actual convention, not just that the two
    /// functions agree with each other.
    func testHourRendersTheLocalesOwnClockConvention() {
        let gb = InsightsCopy.hour(14, calendar: utc, locale: Locale(identifier: "en_GB"))
        let us = InsightsCopy.hour(14, calendar: utc, locale: Locale(identifier: "en_US"))

        XCTAssertEqual(gb, "14:00")
        XCTAssertTrue(us.contains("2:00"))
        XCTAssertTrue(us.uppercased().contains("PM"))
    }
}
