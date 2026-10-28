import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, "Daily summary follows
/// the switch" (ruling 2026-10-27): the summary is Claude Code's log, so with Claude off it
/// is neither read nor sent. The notification centre is out of reach; the rule is tested.
final class DailySummaryClaudeSwitchTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Tuesday 2026-10-27, 09:30 UTC.
    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 30))!
    }

    private func due(
        summaryEnabled: Bool = true, claudeEnabled: Bool = true, inQuiet: Bool = false,
        lastSentKey: String = "", summaryHour: Int = 9, at now: Date? = nil
    ) -> Bool {
        UsageNotifier.dailySummaryDue(
            summaryEnabled: summaryEnabled, claudeEnabled: claudeEnabled, inQuiet: inQuiet,
            lastSentKey: lastSentKey, summaryHour: summaryHour, now: now ?? morning, calendar: calendar
        )
    }

    func testTheSummaryIsDuePastItsHourWithClaudeOn() {
        XCTAssertTrue(due())
    }

    func testWithClaudeOffNoSummaryIsDue() {
        XCTAssertFalse(due(claudeEnabled: false), "Claude off: its log is not read and nothing is sent")
    }

    func testBeforeItsHourNoSummaryIsDue() {
        XCTAssertFalse(due(summaryHour: 10))
    }

    func testASummarySentTodayIsNotSentAgain() {
        XCTAssertFalse(due(lastSentKey: UsageNotifier.dayKey(for: morning, calendar: calendar)))
    }

    func testYesterdaysSummaryLeavesTodaysDue() {
        let yesterday = UsageNotifier.dayKey(for: morning.addingTimeInterval(-24 * 3600), calendar: calendar)
        XCTAssertTrue(due(lastSentKey: yesterday))
    }

    func testQuietHoursAndTheSummarySwitchStillWin() {
        XCTAssertFalse(due(inQuiet: true))
        XCTAssertFalse(due(summaryEnabled: false))
    }

    func testClaudeTurnedBackOnLaterThatDayStillGetsTheSummary() {
        XCTAssertFalse(due(claudeEnabled: false))
        XCTAssertTrue(
            due(claudeEnabled: true, lastSentKey: "", at: morning.addingTimeInterval(2 * 3600)),
            "nothing marked the day while Claude was off"
        )
    }
}
