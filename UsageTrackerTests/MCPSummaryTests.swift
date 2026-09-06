import XCTest
@testable import Omelette

/// The paragraph a model reads. Exact strings: this is the text that decides whether an
/// agent starts a two-hour job at 95% of a session window.
final class MCPSummaryTests: XCTestCase {
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

    private func service(
        id: String = "claude",
        name: String = "Claude",
        state: String = "ok",
        retained: Bool = false,
        retainedAt: Date? = nil,
        plan: String? = "Max 5x",
        windows: [StatusSnapshot.Window] = [],
        todayCost: Double? = nil,
        weekCost: Double? = nil,
        apiEquivalent: Bool? = nil
    ) -> StatusSnapshot.Service {
        StatusSnapshot.Service(
            id: id, name: name, state: state, retained: retained, retainedAt: retainedAt,
            plan: plan, windows: windows, todayCost: todayCost, weekCost: weekCost,
            todayTokens: nil, apiEquivalent: apiEquivalent
        )
    }

    private func snapshot(
        _ services: [StatusSnapshot.Service],
        agents: StatusSnapshot.Agents = .none,
        updatedAt: Date? = nil
    ) -> StatusSnapshot {
        StatusSnapshot(version: 1, updatedAt: updatedAt ?? now, services: services, agents: agents)
    }

    private func usage(_ snapshot: StatusSnapshot) -> String {
        MCPSummary.usage(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
    }

    // MARK: - usage

    func testAHealthySubscriptionReadsAsOneParagraph() {
        let text = usage(snapshot([service(
            windows: [
                window("five_hour", "Session", 42, resetsIn: 100 * 60, kind: "session"),
                window("seven_day", "Weekly", 18, resetsIn: 4 * 86_400 + 175 * 60, kind: "weekly"),
            ],
            todayCost: 4.2, weekCost: 31.7, apiEquivalent: true
        )]))

        XCTAssertEqual(text, "Claude (Max 5x): session 42%, resets in 1h 40m (13:00); weekly 18%, resets in 4d 2h (Thu 14:15); $4.20 today, $31.70 this week (API-equivalent, not a subscription bill). Claude's session window is 42% used and resets in 1h 40m (13:00), so there is room to work. Numbers as of 11:20.")
    }

    func testAFullWindowSaysWhatToDoAboutIt() {
        let text = usage(snapshot([service(
            windows: [window("five_hour", "Session", 92, resetsIn: 25 * 60, kind: "session")]
        )]))

        XCTAssertTrue(
            text.contains("Claude's session window is 92% used and resets in 25m — heavy work should wait for the reset or move to a cheaper model."),
            text
        )
    }

    func testAWindowGettingFullSaysToPlanAroundIt() {
        let text = usage(snapshot([service(
            windows: [window("five_hour", "Session", 78, resetsIn: 25 * 60, kind: "session")]
        )]))

        XCTAssertTrue(text.contains("is 78% used and resets in 25m — plan the next stretch of work around it."), text)
    }

    func testPayAsYouGoDollarsAreNotCalledApiEquivalent() {
        let text = usage(snapshot([service(plan: "Claude Enterprise", weekCost: 31.7, apiEquivalent: false)]))

        XCTAssertTrue(text.contains("$31.70 this week."), text)
        XCTAssertFalse(text.contains("API-equivalent"), text)
    }

    func testRetainedNumbersSayTheyAreNotLive() {
        let text = usage(snapshot([service(
            name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: now.addingTimeInterval(-3600), plan: "Pro",
            windows: [window("pool", "Gemini models", 62)]
        )]))

        XCTAssertTrue(text.contains("last known at 10:20; the provider is not reporting now"), text)
    }

    func testAProviderWithNothingToShowStillSaysWhy() {
        let text = usage(snapshot([service(id: "codex", name: "Codex", state: "notSignedIn", plan: nil)]))
        XCTAssertTrue(text.hasPrefix("Codex: sign in needed."), text)
    }

    func testAnEmptySnapshotSaysSo() {
        let text = usage(snapshot([]))
        XCTAssertEqual(text, "No provider is reporting yet. No rate-limit window is reporting, so there is nothing to pace against. Numbers as of 11:20.")
    }

    func testStaleNumbersSayTheyAreStale() {
        let text = usage(snapshot(
            [service(windows: [window("five_hour", "Session", 42, kind: "session")])],
            updatedAt: now.addingTimeInterval(-3600)
        ))

        XCTAssertTrue(
            text.hasSuffix("Numbers are from 10:20 and Omelette may not be running, so treat them as the last thing it saw."),
            text
        )
    }

    func testAPromoPoolNeverDrivesTheAdvice() {
        let snapshot = snapshot([service(windows: [
            window("seven_day_promotional", "Promo pool", 99, kind: "weekly"),
            window("five_hour", "Session", 12, resetsIn: 30 * 60, kind: "session"),
        ])])

        XCTAssertEqual(MCPSummary.worstWindow(snapshot)?.window.id, "five_hour")
    }

    // MARK: - agents

    func testTheAgentsParagraphCountsAndThenLists() {
        let text = MCPSummary.agents(
            snapshot: snapshot([], agents: StatusSnapshot.Agents(
                needsYou: 1, working: 2,
                sessions: [
                    StatusSnapshot.Session(id: "claude:a", project: "Usage tracker", state: "needsYou", activity: "Remove build artifacts"),
                    StatusSnapshot.Session(id: "claude:b", project: "Orion", state: "working", activity: nil),
                ]
            )),
            now: now, calendar: calendar, locale: locale
        )

        XCTAssertEqual(text, "1 session needs a decision from you and 2 are working. Usage tracker — needs you: Remove build artifacts. Orion — working. Numbers as of 11:20.")
    }

    func testAQuietMachineSaysNothingIsRunning() {
        let text = MCPSummary.agents(snapshot: snapshot([]), now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(text, "No agent session is running. Numbers as of 11:20.")
    }

    func testTheCountPhrasePluralisesBothHalves() {
        XCTAssertEqual(MCPSummary.countPhrase(needsYou: 1, working: 1), "1 session needs a decision from you and 1 is working.")
        XCTAssertEqual(MCPSummary.countPhrase(needsYou: 0, working: 2), "0 sessions need a decision from you and 2 are working.")
    }
}
