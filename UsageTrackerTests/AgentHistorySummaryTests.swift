import XCTest
@testable import Omelette

/// Everything the Agents tab shows is computed here, so every number and every
/// string on that screen is pinned by one of these cases. Dates are fixed epochs
/// and calendars carry an explicit time zone: "which day did this end on" is a
/// question with a different answer in every zone.
final class AgentHistorySummaryTests: XCTestCase {
    /// 2026-09-02 12:00:00 UTC — a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_788_350_400)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func record(
        id: String = "claude:s1",
        source: AgentSource = .claude,
        project: String = "Usage tracker",
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        turns: Int = 4,
        needsYouCount: Int = 0
    ) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: source, project: project,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: Date(timeIntervalSince1970: endedAt),
            turns: turns, needsYouCount: needsYouCount
        )
    }

    /// Ends 2026-09-02 09:30 UTC after 3h 12m.
    private var today: AgentSessionRecord {
        record(id: "claude:today", startedAt: 1_788_329_880, endedAt: 1_788_341_400, needsYouCount: 2)
    }
    /// Ends 2026-09-01 23:30 UTC — yesterday in UTC, today in Warsaw.
    private var lateYesterday: AgentSessionRecord {
        record(id: "claude:late", project: "Orion Gate", startedAt: 1_788_303_600, endedAt: 1_788_305_400)
    }
    /// Started 2026-09-01 23:40 UTC, ended 2026-09-02 00:20 UTC — crosses midnight.
    private var acrossMidnight: AgentSessionRecord {
        record(id: "codex:cross", source: .codex, project: "Jaravis", startedAt: 1_788_306_000, endedAt: 1_788_308_400)
    }
    /// Ends 2026-08-20 12:00 UTC — outside a 7-day window, inside 30d.
    private var old: AgentSessionRecord {
        record(id: "claude:old", project: "Ancient", startedAt: 1_787_223_600, endedAt: 1_787_227_200)
    }

    // MARK: - Range and source filtering

    func testOnlySessionsThatEndedInsideTheRangeCount() {
        let summary = AgentHistorySummary.make(
            records: [today, lateYesterday, old], source: nil, range: .sevenDays, now: now
        )
        XCTAssertEqual(summary.sessions, 2, "the 2026-08-20 session is 13 days old")
    }

    func testAWiderRangeLetsTheOldSessionBackIn() {
        let summary = AgentHistorySummary.make(
            records: [today, lateYesterday, old], source: nil, range: .thirtyDays, now: now
        )
        XCTAssertEqual(summary.sessions, 3)
    }

    func testTheRangeIsMeasuredFromEndedAtNotStartedAt() {
        // Started 8 days ago, ended 10 minutes ago: the run belongs to today.
        let marathon = record(id: "claude:long", startedAt: 1_787_659_200, endedAt: 1_788_349_800)
        let summary = AgentHistorySummary.make(records: [marathon], source: nil, range: .oneDay, now: now)
        XCTAssertEqual(summary.sessions, 1)
    }

    func testTheSourceFilterKeepsOnlyThatProvider() {
        let all = AgentHistorySummary.make(records: [today, acrossMidnight], source: nil, range: .sevenDays, now: now)
        let codex = AgentHistorySummary.make(records: [today, acrossMidnight], source: .codex, range: .sevenDays, now: now)
        XCTAssertEqual(all.sessions, 2)
        XCTAssertEqual(codex.sessions, 1)
        XCTAssertEqual(codex.approvalsWaited, 0)
    }

    // MARK: - The four tiles

    func testAgentTimeSumsEveryRunInRange() {
        let summary = AgentHistorySummary.make(
            records: [today, acrossMidnight], source: nil, range: .sevenDays, now: now
        )
        XCTAssertEqual(summary.agentTime, 11_520 + 2_400, accuracy: 0.5)
    }

    func testApprovalsWaitedSumsNeedsYouCounts() {
        let another = record(id: "claude:two", startedAt: 1_788_330_000, endedAt: 1_788_333_600, needsYouCount: 3)
        let summary = AgentHistorySummary.make(records: [today, another], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.approvalsWaited, 5)
    }

    func testBusiestProjectCountsSessionsNotTime() {
        let a1 = record(id: "claude:a1", project: "alpha", startedAt: 1_788_330_000, endedAt: 1_788_330_600)
        let a2 = record(id: "claude:a2", project: "alpha", startedAt: 1_788_331_000, endedAt: 1_788_331_600)
        let b1 = record(id: "claude:b1", project: "beta", startedAt: 1_788_300_000, endedAt: 1_788_340_000)
        let summary = AgentHistorySummary.make(records: [b1, a1, a2], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.busiestProject?.name, "alpha")
        XCTAssertEqual(summary.busiestProject?.sessions, 2)
    }

    func testATieGoesToTheProjectSeenFirst() {
        let b1 = record(id: "claude:b1", project: "beta", startedAt: 1_788_300_000, endedAt: 1_788_300_600)
        let a1 = record(id: "claude:a1", project: "alpha", startedAt: 1_788_301_000, endedAt: 1_788_301_600)
        let b2 = record(id: "claude:b2", project: "beta", startedAt: 1_788_302_000, endedAt: 1_788_302_600)
        let a2 = record(id: "claude:a2", project: "alpha", startedAt: 1_788_303_000, endedAt: 1_788_303_600)
        let summary = AgentHistorySummary.make(records: [b1, a1, b2, a2], source: nil, range: .sevenDays, now: now)
        XCTAssertEqual(summary.busiestProject?.name, "beta")
        XCTAssertEqual(summary.busiestProject?.sessions, 2)
    }

    func testNothingInRangeIsAllZeroes() {
        let summary = AgentHistorySummary.make(records: [old], source: nil, range: .oneDay, now: now)
        XCTAssertEqual(summary, AgentHistorySummary(sessions: 0, agentTime: 0, approvalsWaited: 0, busiestProject: nil))
    }

    // MARK: - Day grouping

    func testDaysAreNewestFirstAndRecordsInsideADayToo() {
        let earlier = record(id: "claude:early", startedAt: 1_788_318_000, endedAt: 1_788_321_600) // ends 04:00 UTC today
        let groups = AgentHistorySummary.days(
            records: [earlier, today, lateYesterday], source: nil, range: .sevenDays, now: now, calendar: utc
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].day, Date(timeIntervalSince1970: 1_788_307_200)) // 2026-09-02 00:00 UTC
        XCTAssertEqual(groups[0].records.map(\.id), ["claude:today", "claude:early"])
        XCTAssertEqual(groups[1].records.map(\.id), ["claude:late"])
    }

    func testASessionThatCrossedMidnightIsFiledUnderTheDayItEnded() {
        let groups = AgentHistorySummary.days(
            records: [acrossMidnight], source: nil, range: .sevenDays, now: now, calendar: utc
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].day, Date(timeIntervalSince1970: 1_788_307_200))
    }

    func testGroupingFollowsTheCalendarsTimeZone() {
        // 2026-09-01 23:30 UTC is 2026-09-02 01:30 in Warsaw: same instant, different day.
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        warsaw.locale = Locale(identifier: "en_US_POSIX")

        let inUTC = AgentHistorySummary.days(records: [lateYesterday], source: nil, range: .sevenDays, now: now, calendar: utc)
        let inWarsaw = AgentHistorySummary.days(records: [lateYesterday], source: nil, range: .sevenDays, now: now, calendar: warsaw)
        XCTAssertEqual(AgentHistorySummary.dayTitle(inUTC[0].day, now: now, calendar: utc), "Yesterday")
        XCTAssertEqual(AgentHistorySummary.dayTitle(inWarsaw[0].day, now: now, calendar: warsaw), "Today")
    }

    func testDSTDoesNotMergeOrSplitDays() {
        // Europe/Warsaw springs forward at 02:00 on 2026-03-29.
        var warsaw = Calendar(identifier: .gregorian)
        warsaw.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        warsaw.locale = Locale(identifier: "en_US_POSIX")
        let before = record(id: "claude:before", startedAt: 1_774_735_200, endedAt: 1_774_737_000) // 28th, 23:30 local
        let after = record(id: "claude:after", startedAt: 1_774_747_200, endedAt: 1_774_747_800)   // 29th, 03:30 local
        let dstNow = Date(timeIntervalSince1970: 1_774_778_400)                                     // 29th, 12:00 local

        let groups = AgentHistorySummary.days(
            records: [before, after], source: nil, range: .sevenDays, now: dstNow, calendar: warsaw
        )
        XCTAssertEqual(groups.count, 2, "the short day is still one day")
        XCTAssertEqual(groups[0].records.map(\.id), ["claude:after"])
        XCTAssertEqual(AgentHistorySummary.dayTitle(groups[0].day, now: dstNow, calendar: warsaw), "Today")
        XCTAssertEqual(AgentHistorySummary.dayTitle(groups[1].day, now: dstNow, calendar: warsaw), "Yesterday")
    }

    func testAnOlderDayReadsAsWeekdayDayMonth() {
        let monday = AgentHistorySummary.days(
            records: [record(id: "claude:mon", startedAt: 1_788_166_800, endedAt: 1_788_170_400)],
            source: nil, range: .sevenDays, now: now, calendar: utc
        )[0].day
        XCTAssertEqual(AgentHistorySummary.dayTitle(monday, now: now, calendar: utc), "Mon 31 Aug")
    }

    // MARK: - Duration strings

    func testDurationReadsAsHoursAndMinutes() {
        XCTAssertEqual(AgentHistorySummary.duration(11_520), "3h 12m")
    }

    func testDurationPadsMinutesUnderTenLikeTheLiveRows() {
        XCTAssertEqual(AgentHistorySummary.duration(11_100), "3h 05m")
    }

    func testDurationUnderAnHourIsMinutesOnly() {
        XCTAssertEqual(AgentHistorySummary.duration(2_700), "45m")
        XCTAssertEqual(AgentHistorySummary.duration(3_599), "59m")
    }

    func testAnythingUnderAMinuteIsTheFloorMarker() {
        XCTAssertEqual(AgentHistorySummary.duration(59), "<1m")
        XCTAssertEqual(AgentHistorySummary.duration(0), "<1m")
        XCTAssertEqual(AgentHistorySummary.duration(-30), "<1m", "a clock that stepped back is not negative time")
    }

    func testAnExactHourKeepsItsZeroMinutes() {
        XCTAssertEqual(AgentHistorySummary.duration(3_600), "1h 00m")
    }

    /// A 90-day "Agent time" tile reads in hundreds of hours otherwise, which is a
    /// number nobody can picture. Minutes are dropped: at this scale they are noise.
    func testADayOrMoreRollsHoursIntoDays() {
        XCTAssertEqual(AgentHistorySummary.duration(21 * 86_400 + 8 * 3_600), "21d 8h")
        XCTAssertEqual(AgentHistorySummary.duration(86_400), "1d 0h", "exactly a day is the first day form")
        XCTAssertEqual(AgentHistorySummary.duration(86_399), "23h 59m", "one second short is still hours")
        XCTAssertEqual(
            AgentHistorySummary.duration(86_400 + 3_600 + 3_540), "1d 1h",
            "the leftover 59 minutes are dropped, never rounded up into another hour"
        )
    }
}
