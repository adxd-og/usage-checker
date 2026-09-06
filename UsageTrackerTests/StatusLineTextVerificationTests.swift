import XCTest
@testable import Omelette

/// Independent verification of `StatusLineText`, derived from the spec's `omelette
/// statusline` example and the plan's Task 7, not from `StatusLineTextTests`. Focus:
/// needsYou == 0 (no flag at all, even with a session window present), a weekly-only
/// window pinned exactly, and structural guarantees (no embedded newline, no trailing
/// whitespace) the CLI's final `+ "\n"` depends on.
final class StatusLineTextVerificationTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 11, minute: 20))!
    }

    private func window(
        _ id: String, _ label: String, _ percent: Double, resetsIn: TimeInterval? = nil, kind: String? = nil
    ) -> StatusSnapshot.Window {
        StatusSnapshot.Window(id: id, label: label, percent: percent, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func snapshot(
        id: String = "claude", windows: [StatusSnapshot.Window], todayCost: Double? = nil, needsYou: Int = 0
    ) -> StatusSnapshot {
        StatusSnapshot(
            version: 1, updatedAt: now,
            services: [StatusSnapshot.Service(
                id: id, name: id.capitalized, state: "ok", retained: false, retainedAt: nil,
                plan: nil, windows: windows, todayCost: todayCost, weekCost: nil, todayTokens: nil, apiEquivalent: true
            )],
            agents: StatusSnapshot.Agents(needsYou: needsYou, working: 0, sessions: [])
        )
    }

    /// needsYou == 0 with every other part present: the flag must be entirely absent,
    /// not printed as "⚑ 0".
    func testNeedsYouZeroOmitsTheFlagEntirely() {
        let text = StatusLineText.render(
            snapshot: snapshot(
                windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                todayCost: 4.2, needsYou: 0
            ),
            now: now
        )
        XCTAssertEqual(text, "◐ 42% · resets in 1h 10m · $4.20 today")
        XCTAssertFalse(text.contains("⚑"))
    }

    /// A provider with only a weekly window (no session bucket at all) — the fullest
    /// core window leads, pinned exactly, including its own reset text.
    func testAWeeklyOnlyProviderLeadsWithTheWeeklyWindow() {
        let text = StatusLineText.render(
            snapshot: snapshot(
                id: "codex",
                windows: [window("seven_day", "Weekly", 18, resetsIn: 4 * 86_400 + 175 * 60, kind: "weekly")]
            ),
            provider: "codex", now: now
        )
        XCTAssertEqual(text, "◐ 18% · resets in 4d 2h")
    }

    /// The rendered line must never itself contain a newline — the CLI appends exactly
    /// one, and a newline embedded in the middle would print as two status-bar lines.
    func testTheRenderedLineNeverContainsANewline() {
        let text = StatusLineText.render(
            snapshot: snapshot(
                windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                todayCost: 4.2, needsYou: 1
            ),
            now: now
        )
        XCTAssertFalse(text.contains("\n"))
    }

    /// No trailing (or leading) whitespace — every joined part is trimmed material, and
    /// a status bar that padded its own line would look broken beside Claude Code's.
    func testNoLeadingOrTrailingWhitespace() {
        let text = StatusLineText.render(
            snapshot: snapshot(
                windows: [window("five_hour", "Session", 42, resetsIn: 70 * 60, kind: "session")],
                todayCost: 4.2, needsYou: 1
            ),
            now: now
        )
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespaces))
    }

    /// Percent is always rounded, never truncated — 42.9% must read "43%", not "42%".
    func testPercentIsRoundedNotTruncated() {
        let text = StatusLineText.render(
            snapshot: snapshot(windows: [window("five_hour", "Session", 42.9, kind: "session")]), now: now
        )
        XCTAssertEqual(text, "◐ 43%")
    }
}
