import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 2. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Status
/// line: a retained provider keeps its window but the text says how old it is (via
/// `RetainedCopy`), and the `resets …` part is dropped once `resetsAt <= now`. Today's
/// dollars stay: they are local and live."
///
/// The executor's `StatusLineRetainedTests` covers the single-window, `.used`-mode
/// cases. This file drives combinations it does not: a retained service with no window
/// at all (so "today's dollars stay" has to hold with nothing else on the line), the
/// `.remaining` mode crossed with a past reset, and headline selection among several
/// windows on a retained service.
final class StatusLineRetentionVerificationTests: XCTestCase {
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

    private func line(_ service: StatusSnapshot.Service, showsRemaining: Bool = false) -> String {
        StatusLineText.render(
            snapshot: StatusSnapshot(
                version: StatusSnapshot.currentVersion, updatedAt: now, services: [service],
                agents: .none, showsRemaining: showsRemaining
            ),
            now: now, colour: false, calendar: calendar, locale: locale
        )
    }

    func testARetainedServiceWithNoWindowKeepsOnlyTodaysDollars() {
        // Nothing to carry a window from — a provider that reported no rate-limit
        // windows before it started failing (e.g. Codex identified with no limits,
        // report item 6) — but the local, live spend for today is unrelated data and
        // must not vanish with it.
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: now.addingTimeInterval(-1800), windows: [], todayCost: 4.2, apiEquivalent: false
        )
        XCTAssertEqual(line(service), "$4.20 today")
        XCTAssertEqual(
            StatusLineText.windowParts(service, mode: .used, now: now, calendar: calendar, locale: locale), [],
            "no window means no gauge and no stamp, retained or not"
        )
    }

    func testRemainingModeWithARetainedWindowPastItsResetDropsTheResetButKeepsRemaining() {
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 9, minute: 20))!,
            windows: [StatusSnapshot.Window(
                id: "five_hour", label: "Session", percent: 90,
                resetsAt: now.addingTimeInterval(-120), kind: "session"
            )]
        )
        XCTAssertEqual(line(service, showsRemaining: true), "◐ 10% left (as of 09:20)")
    }

    func testHeadlineSelectionAmongSeveralWindowsIsUnaffectedByRetention() {
        // The session window leads even though the weekly one is fuller — the same
        // choice `headlineWindow` makes for a live service — and it carries its own
        // reset, not the weekly's.
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: now.addingTimeInterval(-3600),
            windows: [
                StatusSnapshot.Window(
                    id: "seven_day", label: "Weekly", percent: 95,
                    resetsAt: now.addingTimeInterval(3 * 86_400), kind: "weekly"
                ),
                StatusSnapshot.Window(
                    id: "five_hour", label: "Session", percent: 50,
                    resetsAt: now.addingTimeInterval(1800), kind: "session"
                ),
            ]
        )
        XCTAssertEqual(line(service), "◐ 50% (as of 10:20) · resets in 30m")
    }

    func testAPromotionalWindowIsTheOnlyOneAndStillCarriesTheStamp() {
        // A retained provider whose only window is a bonus pool: promo windows lead
        // when they are all there is (existing, unrelated rule); the retained stamp
        // still has to apply to it.
        let service = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: now.addingTimeInterval(-600),
            windows: [StatusSnapshot.Window(
                id: "promo_pool", label: "Promo bonus", percent: 12, resetsAt: nil, kind: "other"
            )]
        )
        XCTAssertEqual(line(service), "◐ 12% (as of 11:10)")
    }
}
