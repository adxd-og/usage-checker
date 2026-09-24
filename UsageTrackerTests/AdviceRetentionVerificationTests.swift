import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 3. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "`get_usage`: `worstWindow` prefers live services; with only retained windows the
/// advice states last-known with its time and gives no wait/room verdict; a retained
/// window past its reset is never used."
///
/// The executor's `MCPSummaryRetainedTests` pins the headline two-tier split with one
/// live and one retained service. This file drives scenarios it does not: a live
/// service that reports zero windows (falling through to the retained tier), and a
/// retained tier whose only non-expired window is a promotional pool sitting beside an
/// expired core window.
final class AdviceRetentionVerificationTests: XCTestCase {
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
        _ id: String, _ percent: Double, resetsIn: TimeInterval? = nil, kind: String? = nil
    ) -> StatusSnapshot.Window {
        StatusSnapshot.Window(id: id, label: id, percent: percent, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, kind: kind)
    }

    private func snapshot(_ services: [StatusSnapshot.Service]) -> StatusSnapshot {
        StatusSnapshot(version: StatusSnapshot.currentVersion, updatedAt: now, services: services, agents: .none)
    }

    func testALiveServiceReportingNoWindowsStillFallsThroughToTheRetainedTier() {
        // A pay-as-you-go Claude is live and .ok but windowless; it must not make
        // `worstWindow` stop at the "live" tier and return nil outright when a
        // retained provider beside it does have a window.
        let livePayAsYouGo = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false, windows: [], weekCost: 31.7
        )
        let retainedAntigravity = StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: now.addingTimeInterval(-1800),
            windows: [window("antigravity_gemini", 88, resetsIn: 3600, kind: "weekly")]
        )
        let worst = MCPSummary.worstWindow(snapshot([livePayAsYouGo, retainedAntigravity]), now: now)
        XCTAssertEqual(worst?.service.id, "antigravity", "no live window exists, so the retained one is the answer")
        XCTAssertTrue(
            MCPSummary.advice(for: snapshot([livePayAsYouGo, retainedAntigravity]), now: now, calendar: calendar, locale: locale)
                .hasPrefix("Nothing is reporting live:"),
            "a windowless live service is not itself a live window to pace against"
        )
    }

    func testARetainedTiersPromoWindowLeadsOnceItsCoreSiblingHasExpired() {
        // Within the retained tier the reset filter runs first: the expired weekly
        // (core) window is dropped before the promo/core tiering decides what is left,
        // so the surviving promo pool — not nothing — is the answer.
        let retained = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: now.addingTimeInterval(-3600),
            windows: [
                window("seven_day", 70, resetsIn: -60, kind: "weekly"),
                window("promo_pool", 45, resetsIn: 1800, kind: "other"),
            ]
        )
        let worst = MCPSummary.worstWindow(snapshot([retained]), now: now)
        XCTAssertEqual(worst?.window.id, "promo_pool", "the expired core window is gone; the live-ish promo pool is all that is left")
    }

    func testTwoRetainedServicesPickTheFullerOne() {
        let a = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "error", retained: true,
            retainedAt: now.addingTimeInterval(-1800), windows: [window("five_hour", 30, resetsIn: 3600, kind: "session")]
        )
        let b = StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: now.addingTimeInterval(-900), windows: [window("antigravity_gemini", 77, resetsIn: 3600, kind: "weekly")]
        )
        let worst = MCPSummary.worstWindow(snapshot([a, b]), now: now)
        XCTAssertEqual(worst?.service.id, "antigravity")
        XCTAssertEqual(worst?.window.percent, 77)
    }

    func testEveryLiveWindowExpiredStillBeatsAFullerRetainedOne() {
        // "Live providers first" is unconditional: a live window past its reset (which
        // still counts, per the report) outranks a fuller retained one.
        let liveButExpired = StatusSnapshot.Service(
            id: "claude", name: "Claude", state: "ok", retained: false,
            windows: [window("five_hour", 40, resetsIn: -30, kind: "session")]
        )
        let retainedFuller = StatusSnapshot.Service(
            id: "antigravity", name: "Antigravity", state: "notRunning", retained: true,
            retainedAt: now.addingTimeInterval(-1800), windows: [window("antigravity_gemini", 95, resetsIn: 3600, kind: "weekly")]
        )
        let worst = MCPSummary.worstWindow(snapshot([liveButExpired, retainedFuller]), now: now)
        XCTAssertEqual(worst?.service.id, "claude")
        XCTAssertEqual(worst?.window.percent, 40)
    }
}
