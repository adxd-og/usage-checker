import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Mood rule" (mood line, accessibility label per row;
/// "Accessibility label is its own string per mood … never empty") and § 3.8 (the habitat is
/// one accessibility element). Percentages through `PercentDisplay`: used or left.
final class PetMoodCopyTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_792_972_800)
    /// 13:48 that Monday.
    private var day: Date { midnight.addingTimeInterval(13 * 3_600 + 48 * 60) }

    private func line(_ mood: PetMood, mode: PercentDisplay.Mode = .used, at date: Date? = nil) -> String? {
        PetMoodCopy.line(for: mood, mode: mode, now: date ?? day, calendar: utc, locale: locale)
    }

    private func label(_ mood: PetMood, mode: PercentDisplay.Mode = .used, at date: Date? = nil) -> String {
        PetMoodCopy.accessibilityLabel(for: mood, petName: "Cat", mode: mode, now: date ?? day, calendar: utc, locale: locale)
    }

    private func waiting(_ project: String, id: String = "s1") -> AgentSession {
        Fixture.agentSession(sessionID: id, projectName: project, state: .needsYou)
    }

    /// The alert a provider with one hot window raises, as the selector hands it over.
    private func alert(_ name: String, _ bucket: UsageBucket) throws -> PetMood {
        let service = Fixture.snapshot(id: name.lowercased(), displayName: name, buckets: [bucket], at: day)
        return .alert(try XCTUnwrap(PetAlertSelector.alert(in: [service], enabledIDs: nil)))
    }

    private func claudeWeek() throws -> PetMood {
        try alert("Claude", Fixture.bucket(id: "seven_day", label: "All models", percent: 92, kind: .weekly))
    }

    func testOneWaitingAgentIsNamedAndSeveralAreCounted() {
        XCTAssertEqual(line(.needsYou([waiting("Usage tracker")])), "Usage tracker is waiting")
        let three = [waiting("Usage tracker"), waiting("Orion Gate", id: "s2"), waiting("Movie", id: "s3")]
        XCTAssertEqual(line(.needsYou(three)), "3 waiting")
        XCTAssertEqual(line(.needsYou([waiting("  ")])), "An agent is waiting")
    }

    func testASignedOutClaudeSaysItsSignInLine() {
        for recovery in [ClaudeRecovery.signIn, .install, .keychainAccess, .noAction] {
            XCTAssertEqual(line(.claudeSignedOut(recovery)), ClaudeSignInCopy.petLine(recovery), "\(recovery)")
        }
    }

    func testTheAlertNamesTheProviderAndTheWindowInThePercentModeChosen() throws {
        let week = try claudeWeek()
        XCTAssertEqual(line(week), "Claude week 92%")
        XCTAssertEqual(line(week, mode: .remaining), "Claude week 8% left")
    }

    func testPlainWindowWordsAreLowerCaseAndModelNamesAreKept() throws {
        let session = try alert("Codex", Fixture.bucket(id: "codex_primary", label: "Current session", percent: 95, kind: .session))
        XCTAssertEqual(line(session), "Codex session 95%")
        let weekly = try alert("Codex", Fixture.bucket(id: "codex_secondary", label: "Weekly", percent: 91, kind: .weekly))
        XCTAssertEqual(line(weekly), "Codex weekly 91%")
        let credits = try alert("Grok", Fixture.bucket(id: "grok_credits", label: "Credits", percent: 90, kind: .weekly))
        XCTAssertEqual(line(credits), "Grok credits 90%")
        let opus = try alert("Claude", Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 93, kind: .modelSpecific))
        XCTAssertEqual(line(opus), "Claude Opus 93%")
        let argon = try alert(
            "Antigravity",
            Fixture.bucket(id: "antigravity_model-gemini-4-argon", label: "Gemini 4 Argon", percent: 96, kind: .modelSpecific)
        )
        XCTAssertEqual(line(argon), "Antigravity Gemini 4 Argon 96%")
    }

    func testKeepAwakeSaysTheDeadlineAsTheCardDoes() {
        let tuesdayTwo = midnight.addingTimeInterval(26 * 3_600)
        XCTAssertEqual(line(.keepAwakeNight(deadline: tuesdayTwo), at: midnight.addingTimeInterval(25 * 3_600)), "Awake until 2:00")
        XCTAssertEqual(line(.keepAwakeNight(deadline: tuesdayTwo), at: midnight.addingTimeInterval(23 * 3_600)), "Awake until Tue 2:00")
    }

    func testWorkingNothingOnAndIdle() {
        XCTAssertEqual(line(.working(count: 1)), "1 working")
        XCTAssertEqual(line(.working(count: 2)), "2 working")
        XCTAssertEqual(line(.nothingOn), "Nothing on")
        XCTAssertNil(line(.idle))
    }

    func testVoiceOverHearsWhoWhatAndWhatADoubleTapDoes() throws {
        XCTAssertEqual(label(.needsYou([waiting("Usage tracker")])), "Cat: Usage tracker is waiting, double-tap to go to it")
        XCTAssertEqual(label(.needsYou([waiting("A"), waiting("B", id: "s2")])), "Cat: 2 agents are waiting, double-tap to see them")
        XCTAssertEqual(label(.claudeSignedOut(.signIn)), "Cat: Claude is signed out, double-tap to sign in")
        XCTAssertEqual(label(.claudeSignedOut(.install)), "Cat: Claude Code isn't installed, double-tap to install it")
        XCTAssertEqual(label(.claudeSignedOut(.keychainAccess)), "Cat: Claude needs keychain access, double-tap to open Advanced settings")
        XCTAssertEqual(label(.claudeSignedOut(.noAction)), "Cat: Claude's sign-in can't be read")
        let week = try claudeWeek()
        XCTAssertEqual(label(week), "Cat: Claude week 92 percent used, double-tap to open Claude")
        XCTAssertEqual(label(week, mode: .remaining), "Cat: Claude week 8 percent left, double-tap to open Claude")
        XCTAssertEqual(
            label(.keepAwakeNight(deadline: midnight.addingTimeInterval(26 * 3_600)), at: midnight.addingTimeInterval(25 * 3_600)),
            "Cat is asleep, the Mac stays awake until 2:00, double-tap to open keep awake"
        )
        XCTAssertEqual(label(.working(count: 2)), "Cat: 2 working, double-tap to see the agents")
        XCTAssertEqual(label(.nothingOn), "Cat is asleep, nothing is on, double-tap to open Providers settings")
        XCTAssertEqual(label(.idle), "Cat, double-tap to pat")
    }

    func testTheLabelIsNeverEmptyAndAlwaysNamesThePet() throws {
        let week = try claudeWeek()
        let moods: [PetMood] = [
            .needsYou([waiting("")]), .claudeSignedOut(.noAction), week,
            .keepAwakeNight(deadline: day), .working(count: 1), .nothingOn, .idle,
        ]
        for mood in moods {
            let text = label(mood)
            XCTAssertTrue(text.hasPrefix("Cat"), text)
            XCTAssertGreaterThan(text.count, "Cat".count, text)
        }
    }
}
