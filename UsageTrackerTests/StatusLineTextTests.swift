import XCTest
@testable import Omelette

/// The one line Claude Code shows. Exact strings throughout: this is a format other
/// people's scripts will grep.
final class StatusLineTextTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
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

    private func snapshot(
        id: String = "claude",
        windows: [StatusSnapshot.Window],
        todayCost: Double? = nil,
        needsYou: Int = 0,
        updatedAt: Date? = nil
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: 1,
            updatedAt: updatedAt ?? now,
            services: [
                StatusSnapshot.Service(
                    id: id, name: id.capitalized, state: "ok", retained: false, retainedAt: nil,
                    plan: nil, windows: windows, todayCost: todayCost, weekCost: nil,
                    todayTokens: nil, apiEquivalent: true
                ),
            ],
            agents: StatusSnapshot.Agents(needsYou: needsYou, working: 0, sessions: [])
        )
    }

    func testTheWholeLine() {
        let text = StatusLineText.render(
            snapshot: snapshot(
                windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                todayCost: 4.2, needsYou: 1
            ),
            now: now
        )

        XCTAssertEqual(text, "◐ 42% · resets in 1h 10m · $4.20 today · ⚑ 1")
    }

    func testEveryPartCanBeAbsent() {
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(windows: [window("five_hour", "Session", 42, kind: "session")]), now: now
            ),
            "◐ 42%",
            "no reset, no cost, no waiting agent"
        )
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(windows: [], todayCost: 4.2, needsYou: 2), now: now
            ),
            "$4.20 today · ⚑ 2",
            "a pay-as-you-go account has no window to lead with"
        )
        XCTAssertEqual(
            StatusLineText.render(snapshot: snapshot(windows: [], todayCost: 0), now: now),
            "",
            "nothing to say is an empty line, not a placeholder"
        )
    }

    func testTheSessionWindowLeadsEvenWhenAnotherIsFuller() {
        let text = StatusLineText.render(
            snapshot: snapshot(windows: [
                window("seven_day", "Weekly", 91, resetsIn: 4 * 86_400, kind: "weekly"),
                window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session"),
            ]),
            now: now
        )

        XCTAssertEqual(text, "◐ 42% · resets in 1h 10m")
    }

    func testWithoutASessionWindowTheFullestCoreWindowLeads() {
        // The widget's ring makes the same choice: promo pools and model-scoped caps
        // inform their own row and never lead.
        let text = StatusLineText.render(
            snapshot: snapshot(windows: [
                window("seven_day_promotional", "Promo pool", 99, kind: "weekly"),
                window("seven_day_fable", "Fable only", 95, kind: "modelSpecific"),
                window("seven_day", "All models", 31, resetsIn: 2 * 86_400, kind: "weekly"),
            ]),
            now: now
        )

        XCTAssertEqual(text, "◐ 31% · resets in 2d 0h")
    }

    func testAPromoPoolLeadsOnlyWhenItIsAllThereIs() {
        let promo = window("seven_day_promotional", "Promo pool", 77, kind: "weekly")
        XCTAssertEqual(StatusLineText.headlineWindow(
            StatusSnapshot.Service(
                id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                plan: nil, windows: [promo], todayCost: nil, weekCost: nil,
                todayTokens: nil, apiEquivalent: nil
            )
        )?.id, "seven_day_promotional")
    }

    func testAnotherProviderIsOneFlagAway() {
        let text = StatusLineText.render(
            snapshot: snapshot(id: "codex", windows: [window("codex_session", "Session", 7, resetsIn: 45 * 60, kind: "session")]),
            provider: "codex", now: now
        )
        XCTAssertEqual(text, "◐ 7% · resets in 45m")
    }

    func testAnUnknownProviderStillShowsTheFlagCount() {
        // The agent count is not any one provider's, so a typo in --provider loses the
        // numbers and keeps the thing you most need to see.
        let text = StatusLineText.render(
            snapshot: snapshot(windows: [window("five_hour", "Session", 42, kind: "session")], needsYou: 3),
            provider: "gemini", now: now
        )
        XCTAssertEqual(text, "⚑ 3")
    }

    func testNoSnapshotAndAStaleSnapshotAreBothEmpty() {
        XCTAssertEqual(StatusLineText.render(snapshot: nil, now: now), "")
        XCTAssertEqual(
            StatusLineText.render(
                snapshot: snapshot(
                    windows: [window("five_hour", "Session", 42, kind: "session")],
                    updatedAt: now.addingTimeInterval(-601)
                ),
                now: now
            ),
            "",
            "ten minutes of silence and the numbers are a guess"
        )
    }

    func testAWindowPastItsResetSaysSo() {
        let text = StatusLineText.render(
            snapshot: snapshot(windows: [window("five_hour", "Session", 98, resetsIn: -5, kind: "session")]),
            now: now
        )
        XCTAssertEqual(text, "◐ 98% · resets now")
    }
}
