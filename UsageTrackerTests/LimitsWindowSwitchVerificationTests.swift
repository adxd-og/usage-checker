import XCTest
@testable import Omelette

/// The Limits tab's window switch, at the edges: limit-analytics spec (2026-10-16) § The
/// tab, item 1 ("only the windows the account has: Codex Prolite shows Week alone"). There
/// is one choice for every provider; it falls back to what the selected account has.
final class LimitsWindowSwitchVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    func testUnreadableStoredChoicesFallBackToTheWeek() {
        for stored in ["", "Session", "WEEKLY", "week", "monthly", "other", "modelSpecific", "session ", "nonsense"] {
            XCTAssertEqual(
                LimitsRules.selectedKind(stored: stored, offered: [.session, .weekly]), .weekly,
                "stored \"\(stored)\""
            )
        }
    }

    func testAStoredChoiceThatIsNotACoreWindowIsNeverSelected() {
        XCTAssertEqual(LimitsRules.selectedKind(stored: "modelSpecific", offered: [.session, .weekly]), .weekly)
        XCTAssertEqual(LimitsRules.selectedKind(stored: "other", offered: [.session]), .session)
    }

    func testWithOnlyASessionOfferedTheSessionIsSelectedWhateverIsStored() {
        XCTAssertEqual(LimitsRules.selectedKind(stored: "", offered: [.session]), .session)
        XCTAssertEqual(LimitsRules.selectedKind(stored: "weekly", offered: [.session]), .session)
    }

    func testTheChoiceSurvivesAVisitToAnAccountThatLacksIt() {
        // The function is pure: a Codex Prolite visit does not rewrite what Claude kept.
        let stored = BucketKind.session.rawValue
        XCTAssertEqual(LimitsRules.selectedKind(stored: stored, offered: [.weekly]), .weekly)
        XCTAssertEqual(LimitsRules.selectedKind(stored: stored, offered: [.session, .weekly]), .session)
    }

    func testCodexWithBothWindowsOffersBothInOrder() {
        let codex = Fixture.snapshot(id: "codex", plan: "Plus", buckets: [
            Fixture.bucket(id: "codex_weekly", percent: 10, resetsAt: now.addingTimeInterval(day),
                           kind: .weekly, windowLength: 7 * day),
            Fixture.bucket(id: "codex_session", percent: 3, resetsAt: now.addingTimeInterval(3_600),
                           kind: .session, windowLength: 5 * 3_600),
        ])
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "codex", service: codex), [.session, .weekly])
    }

    func testAModelSpecificWindowAndABonusPoolAreNotOffered() {
        let claude = Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", percent: 40, resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
            Fixture.bucket(id: "seven_day_opus", percent: 10, resetsAt: now.addingTimeInterval(2 * day), kind: .modelSpecific),
            Fixture.cloudCredits,
        ])
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "claude", service: claude), [.weekly])
    }

    func testTheSwitchNamesFollowTheWindowsLength() {
        let free = Fixture.snapshot(id: "codex", plan: "Free", buckets: [
            Fixture.bucket(id: "codex_session", percent: 4, resetsAt: now.addingTimeInterval(day),
                           kind: .weekly, windowLength: 30 * day),
        ])
        let kinds = LimitsRules.switchKinds(serviceID: "codex", service: free)
        XCTAssertEqual(kinds.map { LimitsCopy.windowName(LimitsRules.span(of: $0, in: free)) }, ["Month"])
    }

    func testTheSpendModesHaveNoSwitchAndStillHaveAKind() {
        let team = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 1_240, utilization: 62),
            weekCost: 300
        )
        let kinds = LimitsRules.switchKinds(serviceID: "claude", service: team)
        XCTAssertEqual(kinds, [])
        XCTAssertEqual(LimitsRules.selectedKind(stored: "session", offered: kinds), .weekly)
    }
}
