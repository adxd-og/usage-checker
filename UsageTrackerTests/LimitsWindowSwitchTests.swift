import XCTest
@testable import Omelette

/// The Limits tab's window switch: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 1 ("Window switch Session / Week (only the windows the account has:
/// Codex Prolite shows Week alone)"). The mockup opens on Week; the choice is kept across
/// launches. Codex Free's 30-day window is named a month.
final class LimitsWindowSwitchTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private var claudeMax: ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 9,
                           resetsAt: now.addingTimeInterval(3_600), kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    func testClaudeOffersSessionThenWeek() {
        let kinds = LimitsRules.switchKinds(serviceID: "claude", service: claudeMax)
        XCTAssertEqual(kinds, [.session, .weekly])
        XCTAssertEqual(
            kinds.map { LimitsCopy.windowName(LimitsRules.span(of: $0, in: claudeMax)) },
            ["Session", "Week"]
        )
    }

    func testCodexProliteOffersItsWeekAlone() {
        let weekly = Fixture.bucket(id: "codex_session", label: "Weekly", percent: 10,
                                    resetsAt: now.addingTimeInterval(day), kind: .weekly,
                                    windowLength: 10_080 * 60)
        let codex = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [weekly])
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "codex", service: codex), [.weekly])
        XCTAssertEqual(LimitsCopy.windowName(LimitsRules.span(of: .weekly, in: codex)), "Week")
    }

    func testCodexFreesThirtyDayWindowIsNamedMonth() {
        let monthly = Fixture.bucket(id: "codex_session", label: "Monthly", percent: 4,
                                     resetsAt: now.addingTimeInterval(10 * day), kind: .weekly,
                                     windowLength: 43_200 * 60)
        let codexFree = Fixture.snapshot(id: "codex", plan: "Free", buckets: [monthly])
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "codex", service: codexFree), [.weekly])
        XCTAssertEqual(LimitsCopy.windowName(LimitsRules.span(of: .weekly, in: codexFree)), "Month")
    }

    func testThereIsNoSwitchWithoutAWindowToMeasure() {
        let grok = Fixture.snapshot(id: "grok", buckets: [
            Fixture.bucket(id: "grok_weekly", percent: 3, resetsAt: now.addingTimeInterval(day), kind: .weekly),
        ])
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "grok", service: grok), [], "Grok's log names no chat")
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 412)
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "claude", service: api), [], "pay as you go has no window")
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "claude", service: nil), [])
    }

    func testTheStoredWindowStaysWhileTheAccountHasIt() {
        XCTAssertEqual(LimitsRules.selectedKind(stored: "session", offered: [.session, .weekly]), .session)
        XCTAssertEqual(LimitsRules.selectedKind(stored: "weekly", offered: [.session, .weekly]), .weekly)
    }

    func testTheWeekStandsInForAWindowTheAccountLacks() {
        XCTAssertEqual(LimitsRules.selectedKind(stored: "session", offered: [.weekly]), .weekly, "Codex Prolite")
        XCTAssertEqual(LimitsRules.selectedKind(stored: "", offered: [.session, .weekly]), .weekly, "the mockup opens on Week")
        XCTAssertEqual(LimitsRules.selectedKind(stored: "weekly", offered: [.session]), .session)
        XCTAssertEqual(LimitsRules.selectedKind(stored: "session", offered: []), .weekly, "the spend modes ignore it")
    }

    func testTheChoiceIsKeptUnderItsOwnKeyAsTheWindowsRawValue() {
        XCTAssertEqual(LimitsRules.windowKey, "limitsWindow")
        XCTAssertEqual(BucketKind.session.rawValue, "session")
        XCTAssertEqual(BucketKind.weekly.rawValue, "weekly")
        XCTAssertEqual(LimitsCopy.windowPickerLabel, "Limit window")
    }
}
