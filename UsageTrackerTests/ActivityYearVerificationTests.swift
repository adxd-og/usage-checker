import XCTest
@testable import Omelette

/// Independent verification of the Activity year-retention design, pure-rule half:
/// `ActivityCardRule.cutoffs`, `GridCache.build`, `ActivityCopy.retentionNote`,
/// `ActivityGridView.retentionNote(provider:showsQuota:)` and `InsightsView.peakDay`.
/// Written from the spec and the diff, independently of the executor's own tests —
/// different pinned instants, a leap-day crossing and an America/New_York DST case
/// the executor's suite does not cover.
///
/// Spec: docs/superpowers/specs/2026-09-17-activity-year-retention-design.md
/// § Cards, § Note under the cards, § Retention.

// MARK: - ActivityCardRule.cutoffs

final class ActivityCardRuleVerificationTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// 2026-11-19 09:41:00 UTC — an arbitrary weekday, deliberately not the pinned
    /// Sunday the executor's own tests use, so a bug tied to that specific date would
    /// not slip past both suites. Expected cutoffs cross-computed independently with
    /// `python3`'s `datetime` (not by hand): 2026-10-21 / 2026-08-22 / 2025-11-20.
    func testCutoffsAtAnArbitraryNonBoundaryDate() {
        let now = Date(timeIntervalSince1970: 1_795_081_260)
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)

        XCTAssertEqual(c.thirty, day("2026-10-21", cal))
        XCTAssertEqual(c.ninety, day("2026-08-22", cal))
        XCTAssertEqual(c.year, day("2025-11-20", cal))
    }

    /// The year cutoff crosses a leap day (2028-02-29). Calendar-day arithmetic must
    /// not be thrown off by the extra day the way a fixed 365 x 86 400 subtraction
    /// would be. Expected values cross-computed with `python3`.
    func testCutoffsCrossALeapDayCorrectly() {
        let now = Date(timeIntervalSince1970: 1_835_535_600) // 2028-03-01 15:00 UTC
        let cal = utc
        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)

        XCTAssertEqual(c.thirty, day("2028-02-01", cal))
        XCTAssertEqual(c.ninety, day("2027-12-03", cal))
        XCTAssertEqual(c.year, day("2027-03-03", cal))
    }

    /// A DST case in a different zone from the executor's Vilnius test: America/New_York,
    /// where the 90-day span crosses the 2026 spring-forward (2026-03-08) and the year
    /// span crosses two DST changes. Expected epochs cross-computed with `python3`'s
    /// `zoneinfo`, independently of the app's own `Calendar` arithmetic.
    func testCutoffsCrossingDaylightSavingInNewYorkAreTheRightDayStarts() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let now = Date(timeIntervalSince1970: 1_777_653_000) // 2026-05-01 16:30 UTC = 12:30 EDT

        let c = ActivityCardRule.cutoffs(now: now, calendar: cal)

        XCTAssertEqual(c.thirty, Date(timeIntervalSince1970: 1_775_102_400), "2026-04-02 00:00 EDT")
        XCTAssertEqual(c.ninety, Date(timeIntervalSince1970: 1_769_922_000), "2026-02-01 00:00 EST")
        XCTAssertEqual(c.year, Date(timeIntervalSince1970: 1_746_158_400), "2025-05-02 00:00 EDT")
    }

    private func day(_ text: String, _ calendar: Calendar) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text)!
    }
}

// MARK: - GridCache.build

final class GridCacheVerificationTests: XCTestCase {
    /// 2028-03-01 15:00 UTC — the same leap-crossing instant as the card-rule test
    /// above, so the two subjects are checked against the same, independently
    /// cross-computed cutoffs: thirty = 2028-02-01, ninety = 2027-12-03, year = 2027-03-03.
    private let now = Date(timeIntervalSince1970: 1_835_535_600)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func daily(_ dayOffset: Int, cost: Double) -> CLIDailySummary {
        let cal = utc
        let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now))!
        return CLIDailySummary(
            day: day, totalCost: cost, totalTokens: 0, tokens: .zero,
            turns: cost > 0 ? 1 : 0, byFamily: [:]
        )
    }

    /// One offset per boundary plus a day that crosses the leap day and a zero-cost
    /// day, so an "active days" miscount or a boundary off-by-one shows up as a wrong
    /// dollar figure rather than hiding behind a coincidence.
    private var dailies: [CLIDailySummary] {
        [
            daily(0, cost: 5),        // today
            daily(-15, cost: 0),      // ran, spent nothing — must not count as active
            daily(-29, cost: 7),      // the 30-day card's boundary day
            daily(-30, cost: 11),     // one day past it
            daily(-89, cost: 13),     // the 90-day card's boundary day
            daily(-90, cost: 17),     // one day past it — only the year sees it
            daily(-300, cost: 19),    // crosses the 2028-02-29 leap day
            daily(-364, cost: 23),    // the year card's boundary day
            daily(-365, cost: 29),    // one day past it — no card sees it
        ]
    }

    private func stats() -> [GridStat] {
        GridCache.build(from: dailies, weeks: 52, now: now, calendar: utc).stats
    }

    func testTheThirtyDayCardStopsAtItsBoundary() {
        XCTAssertEqual(stats()[0].label, "Last 30 days")
        XCTAssertEqual(stats()[0].value, "$12.00", "today (5) + the zero day + the 29-days-back boundary (7)")
    }

    func testTheNinetyDayCardReachesItsBoundaryButNoFurther() {
        XCTAssertEqual(stats()[1].label, "Last 90 days")
        XCTAssertEqual(stats()[1].value, "$36.00", "adds the 30-back (11) and 89-back (13) days")
    }

    /// The whole point of the package, checked across a leap-day crossing: the year
    /// card reaches days the 90-day card cannot, and only up to its own boundary.
    func testTheYearCardExceedsTheNinetyDayCardAndStopsAtItsOwnBoundary() {
        let s = stats()
        XCTAssertEqual(s[2].label, "Last year")
        XCTAssertEqual(s[2].value, "$95.00", "adds the 90-back, 300-back and 364-back days; 365-back is out")
        XCTAssertNotEqual(s[2].value, s[1].value)
    }

    func testActiveDaysCountsOnlyDaysWithCostInsideTheYear() {
        // Seven days carry cost inside the year cutoff: 0, -29, -30, -89, -90, -300, -364.
        // The zero-cost day at -15 and the out-of-range day at -365 are both excluded.
        XCTAssertEqual(stats()[2].sub, "7 active days")
    }
}

// MARK: - ActivityCopy.retentionNote / ActivityGridView.retentionNote

final class ActivityCopyVerificationTests: XCTestCase {
    func testClaudeGetsTheTranscriptCleanupSentence() {
        let note = ActivityCopy.retentionNote(provider: "claude")
        XCTAssertEqual(
            note,
            "Claude Code deletes local transcripts after 30 days by default. " +
            "Set cleanupPeriodDays in ~/.claude/settings.json to keep a year."
        )
    }

    func testCodexAndGrokGetNoNote() {
        XCTAssertNil(ActivityCopy.retentionNote(provider: "codex"))
        XCTAssertNil(ActivityCopy.retentionNote(provider: "grok"))
    }

    /// The match is exact on the provider id `DashboardState.selectedService` holds —
    /// not a case-insensitive or substring match. A provider id that merely contains
    /// or resembles "claude" must not pick up the note by accident.
    func testTheProviderMatchIsExactNotCaseInsensitiveOrSubstring() {
        XCTAssertNil(ActivityCopy.retentionNote(provider: "Claude"))
        XCTAssertNil(ActivityCopy.retentionNote(provider: "CLAUDE"))
        XCTAssertNil(ActivityCopy.retentionNote(provider: "claude-code"))
        XCTAssertNil(ActivityCopy.retentionNote(provider: " claude"))
    }

    /// Only the cost grid ever shows the note; quota squares are percentages out of
    /// Omelette's own history, which no transcript cleanup can shorten.
    func testTheGridViewHelperHidesTheNoteInQuotaModeForEveryProvider() {
        for provider in ["claude", "codex", "grok", "antigravity"] {
            XCTAssertNil(
                ActivityGridView.retentionNote(provider: provider, showsQuota: true),
                "\(provider) must show no note while showsQuota is true"
            )
        }
        XCTAssertEqual(
            ActivityGridView.retentionNote(provider: "claude", showsQuota: false),
            ActivityCopy.claudeTranscriptCleanup
        )
    }
}

// MARK: - InsightsView.peakDay

final class InsightsPeakDayVerificationTests: XCTestCase {
    /// A different zone from the executor's UTC test, to catch a peakDay that
    /// silently depended on UTC day boundaries.
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private let now = Date(timeIntervalSince1970: 1_795_081_260) // 2026-11-19 09:41 UTC

    private func daily(_ dayOffset: Int, cost: Double, calendar: Calendar) -> CLIDailySummary {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))!
        return CLIDailySummary(
            day: day, totalCost: cost, totalTokens: 0, tokens: .zero,
            turns: cost > 0 ? 1 : 0, byFamily: [:]
        )
    }

    /// A day just inside the ninety-day cutoff, carrying a modest cost, against a much
    /// bigger day one day further back. If the cutoff were off by even one day the
    /// bigger, older day would win and the assertion below would catch it.
    func testABiggerDayOneDayPastTheCutoffLosesToASmallerDayInsideIt() {
        let cal = tokyo
        let peak = InsightsView.peakDay(
            in: [
                daily(-89, cost: 5, calendar: cal),   // inside — the ninety-day boundary
                daily(-90, cost: 1_000, calendar: cal), // one day out — must be ignored
            ],
            now: now, calendar: cal
        )
        XCTAssertEqual(peak?.cost ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(peak?.day, cal.date(byAdding: .day, value: -89, to: cal.startOfDay(for: now)))
    }

    func testNoDayInsideTheWindowMeansNoPeak() {
        let cal = tokyo
        XCTAssertNil(InsightsView.peakDay(in: [daily(-91, cost: 50, calendar: cal)], now: now, calendar: cal))
    }
}
