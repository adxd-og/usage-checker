import XCTest
@testable import Omelette

/// The figures the Agents tab takes from finished sessions (liquid-glass spec § Screens,
/// "Agents": Sessions in 3.0; agent time, approvals and the busiest project stay in the
/// model for 3.1). Dates are fixed epochs: "did this end inside the range" is measured
/// from `now`, never from the machine's clock.
final class AgentHistorySummaryTests: XCTestCase {
    /// 2026-09-02 12:00:00 UTC — a Wednesday.
    private let now = Date(timeIntervalSince1970: 1_788_350_400)

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
