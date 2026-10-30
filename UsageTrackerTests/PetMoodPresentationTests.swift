import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Mood rule": one priority table → pose, mood line,
/// accessibility label, click action, row by row — every mood on the habitat's floor (owner
/// 2026-10-30, P5c plan: the mood shows through pose and line); D11: the click is the top mood's
/// action, a pat when idle. The idle loop runs in the calm rows, Idle and Agent working (owner
/// 2026-10-30; the spec's table gives it to Idle alone).
final class PetMoodPresentationTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Monday 2026-10-26 13:48 UTC.
    private let now = Date(timeIntervalSince1970: 1_793_022_480)

    private func shown(_ mood: PetMood) -> PetMoodPresentation {
        PetMoodRules.presentation(of: mood, petName: "Cat", mode: .used, now: now, calendar: utc, locale: locale)
    }

    /// One mood per row, both shapes of row 1 and every way out of row 2.
    private func moods() throws -> [PetMood] {
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
            Fixture.bucket(id: "codex_primary", label: "Current session", percent: 95, kind: .session),
        ], at: now)
        let alert = try XCTUnwrap(PetAlertSelector.alert(in: [codex], enabledIDs: nil))
        let one = Fixture.agentSession(sessionID: "s1", state: .needsYou)
        let two = Fixture.agentSession(sessionID: "s2", state: .needsYou)
        return [
            .needsYou([one]),
            .needsYou([one, two]),
            .claudeSignedOut(.signIn),
            .claudeSignedOut(.install),
            .claudeSignedOut(.keychainAccess),
            .claudeSignedOut(.noAction),
            .alert(alert),
            .keepAwakeNight(deadline: now.addingTimeInterval(3_600)),
            .working(count: 2),
            .nothingOn,
            .idle,
        ]
    }

    func testEachRowHasItsPoseAndClick() throws {
        let expected: [(PetPose, PetAction)] = [
            (.look, .jump(sessionID: "claude:s1")),
            (.look, .needsYouList),
            (.look, .claudeRecovery(.signIn)),
            (.look, .claudeRecovery(.install)),
            (.look, .claudeRecovery(.keychainAccess)),
            (.look, .nothing),
            (.look, .providerPage(serviceID: "codex")),
            (.sleep, .keepAwakeCard),
            (.idle, .agentsCard),
            (.sleep, .providersSettings),
            (.idle, .pat),
        ]
        let moods = try moods()
        XCTAssertEqual(moods.count, expected.count)
        for (mood, (pose, action)) in zip(moods, expected) {
            let presentation = shown(mood)
            XCTAssertEqual(presentation.pose, pose, "\(mood)")
            XCTAssertEqual(presentation.action, action, "\(mood)")
        }
    }

    func testTheIdleLoopRunsWhileIdleAndWhileAgentsWorkAndNowhereElse() throws {
        let looping = try moods().filter { shown($0).loops }
        XCTAssertEqual(looping, [.working(count: 2), .idle], "alerts hold still; night and nothing on sleep")
    }

    func testTheLineAndTheLabelAreTheMoodCopysAndTheLabelIsNeverEmpty() throws {
        for mood in try moods() {
            let presentation = shown(mood)
            XCTAssertEqual(
                presentation.line,
                PetMoodCopy.line(for: mood, mode: .used, now: now, calendar: utc, locale: locale), "\(mood)"
            )
            XCTAssertEqual(
                presentation.accessibilityLabel,
                PetMoodCopy.accessibilityLabel(for: mood, petName: "Cat", mode: .used, now: now, calendar: utc, locale: locale),
                "\(mood)"
            )
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty, "\(mood)")
        }
    }
}
