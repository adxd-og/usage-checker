import XCTest
@testable import Omelette

/// get_usage's advice when some numbers are last known. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "`get_usage`: `worstWindow` prefers live services; with only retained windows the
/// advice states last-known with its time and gives no wait/room verdict; a retained
/// window past its reset is never used."
final class MCPSummaryRetainedTests: XCTestCase {
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

    private func window(
        _ id: String, _ label: String, _ percent: Double, resetsIn: TimeInterval? = nil, kind: String? = nil
    ) -> StatusSnapshot.Window {
        StatusSnapshot.Window(
            id: id, label: label, percent: percent,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind
        )
    }

    private func claude(windows: [StatusSnapshot.Window]) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, plan: "Max 5x", windows: windows
        )
    }

    private func antigravity(retainedAt: Date?, windows: [StatusSnapshot.Window]) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: retainedAt, plan: "Pro", windows: windows
        )
    }

    private func snapshot(_ services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none
        )
    }

    private var frozen: StatusSnapshot.Window {
        window("antigravity_gemini", "Gemini models", 95, kind: "weekly")
    }

    private var reportScenario: StatusSnapshot {
        snapshot([
            antigravity(retainedAt: now.addingTimeInterval(-3600), windows: [frozen]),
            claude(windows: [window("five_hour", "Session", 20, resetsIn: 100 * 60, kind: "session")]),
        ])
    }

    func testALiveWindowLeadsEvenWhenARetainedOneIsFuller() throws {
        let worst = try XCTUnwrap(MCPSummary.worstWindow(reportScenario, now: now))
        XCTAssertEqual(worst.service.id, "claude")
        XCTAssertEqual(worst.window.id, "five_hour")
        XCTAssertEqual(
            MCPSummary.advice(for: reportScenario, now: now, calendar: calendar, locale: locale),
            "Claude's session window is 20% used and resets in 1h 40m (13:00), so there is room to work."
        )
    }

    func testTheVerifiersScenarioNoLongerSaysToWait() {
        // Verbatim before: "Antigravity's gemini models window is 95% used — heavy work
        // should wait for the reset or move to a cheaper model." with Claude live at 20%.
        let text = MCPSummary.usage(snapshot: reportScenario, now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(text.contains("heavy work should wait"), text)
        XCTAssertTrue(text.contains("last known at 10:20; the provider is not reporting now"), text)
    }

    func testOnlyRetainedWindowsGiveTheLastReadingAndNoVerdict() {
        let advice = MCPSummary.advice(
            for: snapshot([antigravity(retainedAt: now.addingTimeInterval(-3600), windows: [frozen])]),
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(
            advice,
            "Nothing is reporting live: Antigravity's gemini models window was 95% used when last seen at 10:20, so there is no current number to pace against."
        )
        XCTAssertFalse(advice.contains("wait"), advice)
        XCTAssertFalse(advice.contains("room to work"), advice)
    }

    func testARetainedReadingWithoutAStampHasNoTime() {
        XCTAssertEqual(
            MCPSummary.advice(
                for: snapshot([antigravity(retainedAt: nil, windows: [frozen])]),
                now: now, calendar: calendar, locale: locale
            ),
            "Nothing is reporting live: Antigravity's gemini models window was 95% used when last seen, so there is no current number to pace against."
        )
    }

    func testARetainedWindowPastItsResetIsNeverUsed() {
        let snap = snapshot([antigravity(retainedAt: now.addingTimeInterval(-3 * 3600), windows: [
            window("antigravity_session", "Session", 95, resetsIn: -3600, kind: "session"),
            window("antigravity_weekly", "Weekly", 30, resetsIn: 2 * 3600, kind: "weekly"),
        ])])
        XCTAssertEqual(MCPSummary.worstWindow(snap, now: now)?.window.id, "antigravity_weekly")
    }

    func testRetainedWindowsThatHaveAllResetLeaveNothingToPaceAgainst() {
        let snap = snapshot([antigravity(retainedAt: now.addingTimeInterval(-3600), windows: [
            window("antigravity_session", "Session", 95, resetsIn: 0, kind: "session"),
        ])])
        XCTAssertNil(MCPSummary.worstWindow(snap, now: now))
        XCTAssertEqual(
            MCPSummary.advice(for: snap, now: now, calendar: calendar, locale: locale),
            "No rate-limit window is reporting, so there is nothing to pace against."
        )
    }

    func testALiveWindowPastItsResetStillCounts() {
        let snap = snapshot([claude(windows: [window("five_hour", "Session", 98, resetsIn: -5, kind: "session")])])
        XCTAssertEqual(MCPSummary.worstWindow(snap, now: now)?.window.id, "five_hour")
    }
}
