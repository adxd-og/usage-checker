import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Mood rule": one priority table — 1 agent needs you,
/// 2 Claude signed out, 3 the alert selector fires, 4 keep awake on between 22:00 and 06:00,
/// 5 agent working, 6 all providers off, 7 idle. The first row that holds wins.
final class PetMoodRulesTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    /// Monday 2026-10-26 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_792_972_800)
    /// 13:48 that Monday.
    private var day: Date { midnight.addingTimeInterval(13 * 3_600 + 48 * 60) }
    /// 23:00 that Monday.
    private var night: Date { midnight.addingTimeInterval(23 * 3_600) }
    /// Tuesday 12:00: a keep-awake deadline past every night moment used here.
    private var tomorrowNoon: Date { midnight.addingTimeInterval(36 * 3_600) }
    private var armedAllNight: KeepAwakeState { .armed(deadline: tomorrowNoon, floorEnabled: true) }

    private func input(
        sessions: [AgentSession] = [],
        services: [ServiceSnapshot] = [],
        enabled: Set<String>? = ["claude", "codex", "antigravity", "grok"],
        binary: Bool = true,
        keepAwake: KeepAwakeState = .idle
    ) -> PetMoodInput {
        PetMoodInput(
            sessions: sessions, services: services, enabledIDs: enabled,
            claudeBinaryFound: binary, keepAwake: keepAwake
        )
    }

    private func mood(_ input: PetMoodInput, at date: Date? = nil) -> PetMood {
        PetMoodRules.mood(input, now: date ?? day, calendar: utc)
    }

    private func session(_ id: String, _ state: AgentState, lastEventAt: TimeInterval = 1_793_000_000) -> AgentSession {
        Fixture.agentSession(
            sessionID: id, projectName: "Usage tracker", state: state,
            lastEventAt: Date(timeIntervalSince1970: lastEventAt)
        )
    }

    private func claude(week percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: percent, kind: .weekly),
        ], at: day)
    }

    private func codex(session percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
            Fixture.bucket(id: "codex_primary", label: "Current session", percent: percent, kind: .session),
        ], at: day)
    }

    private func signedOutClaude(_ reason: SignedOutReason) -> ServiceSnapshot {
        ServiceSnapshot.notSignedIn(reason: reason, message: "Signed out.", at: day)
    }

    func testWithNothingToSayThePetIsIdle() {
        XCTAssertEqual(mood(input(services: [claude(week: 40)])), .idle)
    }

    func testAWaitingAgentOutranksEveryOtherRow() {
        let waiting = session("s1", .needsYou)
        let everything = input(
            sessions: [waiting, session("s2", .working)],
            services: [signedOutClaude(.expired), codex(session: 97)],
            keepAwake: armedAllNight
        )
        XCTAssertEqual(mood(everything, at: night), .needsYou([waiting]))
    }

    func testSeveralWaitingAgentsComeMostRecentFirst() {
        let older = session("s1", .needsYou, lastEventAt: 1_793_000_000)
        let newer = session("s2", .needsYou, lastEventAt: 1_793_000_600)
        XCTAssertEqual(mood(input(sessions: [older, newer])), .needsYou([newer, older]))
    }

    func testASignedOutClaudeOutranksTheAlertAndOffersItsWayOut() {
        let hot = codex(session: 97)
        XCTAssertEqual(mood(input(services: [signedOutClaude(.expired), hot])), .claudeSignedOut(.signIn))
        XCTAssertEqual(mood(input(services: [signedOutClaude(.notFound), hot], binary: false)), .claudeSignedOut(.install))
        XCTAssertEqual(mood(input(services: [signedOutClaude(.denied), hot])), .claudeSignedOut(.keychainAccess))
        XCTAssertEqual(mood(input(services: [signedOutClaude(.unreadable), hot])), .claudeSignedOut(.noAction))
    }

    func testASwitchedOffClaudeIsNeverSignedOutForThePet() {
        let services = [signedOutClaude(.expired), codex(session: 40)]
        XCTAssertEqual(mood(input(services: services, enabled: ["codex"])), .idle)
    }

    func testTheAlertOutranksKeepAwakeAtNight() {
        let services = [claude(week: 40), codex(session: 97)]
        guard case .alert(let alert) = mood(input(services: services, keepAwake: armedAllNight), at: night) else {
            return XCTFail("expected the alert")
        }
        XCTAssertEqual(alert.serviceID, "codex")
    }

    func testKeepAwakeSleepsThePetFrom22To06Only() {
        let on = input(keepAwake: armedAllNight)
        let asleep = PetMood.keepAwakeNight(deadline: tomorrowNoon)
        XCTAssertEqual(mood(on, at: midnight.addingTimeInterval(21 * 3_600 + 3_599)), .idle, "21:59:59")
        XCTAssertEqual(mood(on, at: midnight.addingTimeInterval(22 * 3_600)), asleep, "22:00")
        XCTAssertEqual(mood(on, at: midnight.addingTimeInterval(26 * 3_600)), asleep, "02:00 the next day")
        XCTAssertEqual(mood(on, at: midnight.addingTimeInterval(5 * 3_600 + 3_599)), asleep, "05:59:59")
        XCTAssertEqual(mood(on, at: midnight.addingTimeInterval(6 * 3_600)), .idle, "06:00")
    }

    func testKeepAwakePastItsDeadlineOrOffSaysNothing() {
        let passed = input(keepAwake: .armed(deadline: midnight.addingTimeInterval(22 * 3_600 + 1_800), floorEnabled: false))
        XCTAssertEqual(mood(passed, at: night), .idle, "the local countdown passed 22:30")
        XCTAssertEqual(mood(input(keepAwake: .idle), at: night), .idle)
        XCTAssertEqual(mood(input(keepAwake: .ended(at: night, reason: .cancelled)), at: night), .idle)
    }

    func testKeepAwakeAtNightOutranksWorkingAgents() {
        let busy = input(sessions: [session("s1", .working)], keepAwake: armedAllNight)
        XCTAssertEqual(mood(busy, at: night), .keepAwakeNight(deadline: tomorrowNoon))
        XCTAssertEqual(mood(busy, at: day), .working(count: 1))
    }

    func testWorkingAgentsAreCountedAndOutrankNothingOn() {
        let sessions = [session("s1", .working), session("s2", .working), session("s3", .done), session("s4", .idle)]
        XCTAssertEqual(mood(input(sessions: sessions, enabled: [])), .working(count: 2))
    }

    func testWithEveryProviderOffThePetSleepsButNotWhileLoading() {
        XCTAssertEqual(mood(input(enabled: [])), .nothingOn)
        XCTAssertEqual(mood(input(enabled: nil)), .idle, "no poll has started: loading, not nothing on")
    }

    func testTheNightFollowsTheCalendarsTimeZone() {
        var tokyo = utc
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertFalse(PetMoodRules.isNight(day, calendar: utc), "13:48 in UTC")
        XCTAssertTrue(PetMoodRules.isNight(day, calendar: tokyo), "22:48 in Tokyo")
    }
}
