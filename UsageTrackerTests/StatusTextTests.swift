import XCTest
@testable import Omelette

/// Every character `omelette status` prints. UTC and en_GB throughout, the same
/// fixture `ResetCopyTests` uses, so the reset strings are the app's own words and not
/// whatever the machine's locale happens to be.
final class StatusTextTests: XCTestCase {
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
        _ services: [StatusSnapshot.Service], agents: StatusSnapshot.Agents = .none
    ) -> StatusSnapshot {
        StatusSnapshot(version: 1, updatedAt: now, services: services, agents: agents)
    }

    private func render(_ snapshot: StatusSnapshot) -> String {
        StatusText.render(snapshot: snapshot, now: now, calendar: calendar, locale: locale)
    }

    func testOneProviderWithWindowsCostsAndAgents() {
        let text = render(snapshot(
            [service(
                windows: [
                    window("five_hour", "Session", 42, resetsIn: 100 * 60, kind: "session"),
                    window("seven_day", "Weekly", 18, resetsIn: 4 * 86_400 + 175 * 60, kind: "weekly"),
                ],
                todayCost: 4.2, weekCost: 31.7, apiEquivalent: true
            )],
            agents: StatusSnapshot.Agents(needsYou: 1, working: 2, sessions: [])
        ))

        XCTAssertEqual(text, """
        Claude  Session 42%, resets in 1h 40m (13:00) · Weekly 18%, resets in 4d 2h (Thu 14:15) · $4.20 today · $31.70 this week
        Agents: 1 needs you, 2 working

        """)
    }

    func testTheNameColumnIsAsWideAsTheLongestName() {
        let text = render(snapshot([
            service(id: "claude", name: "Claude", windows: [window("five_hour", "Session", 42, kind: "session")]),
            service(id: "antigravity", name: "Antigravity", windows: [window("pool", "Gemini models", 31)]),
        ]))

        XCTAssertEqual(text, """
        Claude       Session 42%
        Antigravity  Gemini models 31%

        """)
    }

    func testAWindowWithNoResetPrintsJustThePercent() {
        // `.distantFuture` never reaches the file — StatusFileWriter drops it — so a
        // missing reset here means the provider genuinely reports none.
        let text = render(snapshot([service(windows: [window("seven_day", "Weekly", 18, kind: "weekly")])]))
        XCTAssertEqual(text, "Claude  Weekly 18%\n")
    }

    func testPercentsAreRoundedRatherThanTruncated() {
        XCTAssertEqual(
            StatusText.windowText(window("w", "Session", 42.6, kind: "session"), now: now, calendar: calendar, locale: locale),
            "Session 43%"
        )
        XCTAssertEqual(
            StatusText.windowText(window("w", "Spend limit", 104.2), now: now, calendar: calendar, locale: locale),
            "Spend limit 104%",
            "past the limit is a real answer, not something to clamp away"
        )
    }

    func testRetainedNumbersCarryTheirStamp() {
        let text = render(snapshot([service(
            name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: now.addingTimeInterval(-3600), plan: "Pro",
            windows: [window("pool", "Gemini models", 62)]
        )]))

        XCTAssertEqual(text, "Antigravity  Gemini models 62% · (last known 10:20)\n")
    }

    func testAProviderWithNothingToShowSaysWhy() {
        let text = render(snapshot([
            service(id: "codex", name: "Codex", state: "notSignedIn", plan: nil),
            service(id: "grok", name: "Grok", state: "error", plan: nil),
        ]))

        XCTAssertEqual(text, """
        Codex  Sign in needed
        Grok   Error

        """)
    }

    func testCostsAppearOnlyWhenThereIsMoneyToShow() {
        XCTAssertEqual(StatusText.costParts(service(todayCost: 4.2, weekCost: 31.7)), ["$4.20 today", "$31.70 this week"])
        XCTAssertEqual(StatusText.costParts(service(todayCost: 0, weekCost: 31.7)), ["$31.70 this week"])
        XCTAssertEqual(StatusText.costParts(service()), [])
    }

    func testTheAgentsLineDropsWhicheverHalfIsZero() {
        XCTAssertEqual(StatusText.agentsLine(.init(needsYou: 1, working: 2, sessions: [])), "Agents: 1 needs you, 2 working")
        XCTAssertEqual(StatusText.agentsLine(.init(needsYou: 0, working: 3, sessions: [])), "Agents: 3 working")
        XCTAssertEqual(StatusText.agentsLine(.init(needsYou: 2, working: 0, sessions: [])), "Agents: 2 needs you")
        XCTAssertNil(StatusText.agentsLine(.none), "nothing running is not worth a line")
    }

    func testAnEmptyFileStillSaysSomething() {
        XCTAssertEqual(render(snapshot([])), StatusText.emptyLine + "\n")
    }

    func testTheOutputEndsWithExactlyOneNewline() {
        let text = render(snapshot([service(windows: [window("five_hour", "Session", 42, kind: "session")])]))
        XCTAssertTrue(text.hasSuffix("%\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }
}
