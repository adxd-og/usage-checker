import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.5 "Mood rule" and "Alert selector" with
/// real snapshots and sessions: the priority table is checked as a whole (every subset of the
/// seven rows' conditions, so any two rows swapped fail), and the readings that must never
/// alarm (retained, signed out, switched off) are fed through the mood, not only the selector.
final class PetMoodRulesVerificationTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    /// Monday 2026-10-26 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_792_972_800)
    private var night: Date { midnight.addingTimeInterval(23 * 3_600) }
    private var tomorrowNoon: Date { midnight.addingTimeInterval(36 * 3_600) }
    private let all: Set<String> = ["claude", "codex", "antigravity", "grok"]

    private func mood(_ input: PetMoodInput, at date: Date) -> PetMood {
        PetMoodRules.mood(input, now: date, calendar: utc)
    }

    private func row(of mood: PetMood) -> Int {
        switch mood {
        case .needsYou: 1
        case .claudeSignedOut: 2
        case .alert: 3
        case .keepAwakeNight: 4
        case .working: 5
        case .nothingOn: 6
        case .idle: 7
        }
    }

    private func codex(_ percent: Double, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
            Fixture.bucket(id: "codex_primary", label: "Current session", percent: percent, kind: .session),
        ], state: state, at: midnight)
    }

    private func claude(week percent: Double, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: percent, kind: .weekly),
        ], state: state, at: midnight)
    }

    /// Every subset of rows 1…6 whose condition holds at once (row 7 is "none"): the lowest
    /// row of the subset is the mood. Rows 2 and 3 read providers, which row 6 switches off,
    /// so with row 6 in the subset they cannot hold.
    func testTheFirstRowThatHoldsWinsForEverySetOfRowsThatHoldTogether() {
        for bits in 0..<64 {
            let holds = (1...6).map { bits & (1 << ($0 - 1)) != 0 }
            func has(_ rowNumber: Int) -> Bool { holds[rowNumber - 1] }

            var sessions: [AgentSession] = []
            if has(1) { sessions.append(Fixture.agentSession(sessionID: "w", state: .needsYou)) }
            if has(5) { sessions.append(Fixture.agentSession(sessionID: "r", state: .working)) }
            var services: [ServiceSnapshot] = []
            if has(2) { services.append(ServiceSnapshot.notSignedIn(reason: .expired, message: "Signed out.", at: midnight)) }
            else { services.append(claude(week: 40)) }
            services.append(codex(has(3) ? 93 : 30))
            let input = PetMoodInput(
                sessions: sessions, services: services,
                enabledIDs: has(6) ? [] : all,
                claudeBinaryFound: true,
                keepAwake: has(4) ? .armed(deadline: tomorrowNoon, floorEnabled: true) : .idle
            )

            var effective = holds
            if has(6) { effective[1] = false; effective[2] = false }
            let expected = (0..<6).first { effective[$0] }.map { $0 + 1 } ?? 7
            XCTAssertEqual(row(of: mood(input, at: night)), expected, "rows holding: \(holds)")
        }
    }

    func testTheNightRowNeedsTheNight() {
        let input = PetMoodInput(
            sessions: [], services: [claude(week: 10)], enabledIDs: all, claudeBinaryFound: true,
            keepAwake: .armed(deadline: tomorrowNoon, floorEnabled: true)
        )
        XCTAssertEqual(row(of: mood(input, at: midnight.addingTimeInterval(13 * 3_600))), 7)
        XCTAssertEqual(row(of: mood(input, at: night)), 4)
    }

    func testNoReadingThatIsRetainedSignedOutOrSwitchedOffEverAlarms() {
        for state in [ServiceState.notSignedIn, .notRunning, .error] {
            let hot = [claude(week: 20), codex(99, state: state)]
            let input = PetMoodInput(
                sessions: [], services: hot, enabledIDs: all, claudeBinaryFound: true, keepAwake: .idle
            )
            XCTAssertEqual(mood(input, at: midnight), .idle, "codex \(state) with last-known 99 %")
        }
        let off = PetMoodInput(
            sessions: [], services: [claude(week: 20), codex(99)], enabledIDs: ["claude"],
            claudeBinaryFound: true, keepAwake: .idle
        )
        XCTAssertEqual(mood(off, at: midnight), .idle, "codex switched off")
        let nothing = PetMoodInput(
            sessions: [], services: [claude(week: 99), codex(99)], enabledIDs: [],
            claudeBinaryFound: true, keepAwake: .idle
        )
        XCTAssertEqual(mood(nothing, at: midnight), .nothingOn, "everything switched off, last-known numbers still in the snapshot")
    }

    func testASignedOutClaudeWithLastKnownNumbersIsSignedOutNotAnAlert() {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "seven_day", label: "All models", percent: 97, kind: .weekly)],
            state: .notSignedIn, at: midnight
        )
        XCTAssertTrue(service.isRetained)
        for enabled: Set<String>? in [all, nil] {
            let input = PetMoodInput(
                sessions: [], services: [service], enabledIDs: enabled, claudeBinaryFound: true, keepAwake: .idle
            )
            XCTAssertEqual(mood(input, at: midnight), .claudeSignedOut(.signIn), "enabled \(String(describing: enabled))")
        }
    }

    func testAPromotionalPoolAtNinetyNineDoesNotHideALiveWindowAtNinetyOne() {
        let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promotional", percent: 99, kind: .weekly)
        let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 91, kind: .session)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [promo, Fixture.cloudCredits, session], at: midnight)
        XCTAssertEqual(PetAlertSelector.alert(in: [service], enabledIDs: all)?.bucket.id, "five_hour")
    }

    func testTheAlertThresholdIsNinetyAndAboveAndATieWithAnEarlierDisabledProviderGoesToTheEnabledOne() {
        let services = [codex(93), claude(week: 93)]
        XCTAssertNil(PetAlertSelector.alert(in: [codex(89.999999)], enabledIDs: all))
        XCTAssertEqual(PetAlertSelector.alert(in: [codex(90)], enabledIDs: all)?.serviceID, "codex")
        XCTAssertEqual(PetAlertSelector.alert(in: services, enabledIDs: ["claude"])?.serviceID, "claude")
        XCTAssertEqual(PetAlertSelector.alert(in: services, enabledIDs: all)?.serviceID, "codex")
    }
}
