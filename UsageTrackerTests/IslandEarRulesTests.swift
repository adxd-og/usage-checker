import AppKit
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Alert selector, § 3.6, § 3.8, § 3.9, D2: the ears show only
/// for what needs attention, and ☾ while keep awake is on with the status item hidden; the head on
/// the left, the alert's number on the right through `PercentDisplay`; a neutral dot with the pet
/// off; nothing with the ears off; what a click does and what VoiceOver hears (plan OWNER 1, 3).
final class IslandEarRulesTests: XCTestCase {
    private let now = PetRuntimeFixture.t0
    private let locale = Locale(identifier: "en_GB")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func input(
        sessions: [AgentSession] = [], services: [ServiceSnapshot] = [], keepAwake: KeepAwakeState = .idle,
        mode: PercentDisplay.Mode = .used, pet: Bool = true, ears: Bool = true, itemShown: Bool = false,
        earHeight: CGFloat = 32
    ) -> IslandEarInput {
        IslandEarInput(
            mood: PetMoodInput(
                sessions: sessions, services: services, enabledIDs: ["claude", "codex"],
                claudeBinaryFound: true, keepAwake: keepAwake
            ),
            mode: mode, petOn: pet, showsEars: ears, statusItemShown: itemShown, earHeight: earHeight
        )
    }

    private func ears(_ input: IslandEarInput) -> IslandEars {
        IslandEarRules.ears(input, now: now, calendar: utc, locale: locale)
    }

    private func waiting(_ id: String, project: String = "Usage tracker") -> AgentSession {
        Fixture.agentSession(sessionID: id, projectName: project, state: .needsYou)
    }

    private func claude(week percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: percent, kind: .weekly),
        ], at: now)
    }

    func testNothingToSayMeansNoEars() {
        XCTAssertEqual(ears(input()), IslandEars.none)
        XCTAssertEqual(ears(input(services: [claude(week: 40)])), IslandEars.none)
        XCTAssertEqual(ears(input(sessions: [Fixture.agentSession(state: .working)])), IslandEars.none, "working needs nobody")
    }

    func testOneWaitingAgentPutsTheHeadOnTheLeftAndAClickJumps() {
        let session = waiting("a")
        let shown = ears(input(sessions: [session]))
        XCTAssertEqual(shown.left?.mark, .head)
        XCTAssertEqual(shown.left?.action, .jump(sessionID: session.id))
        XCTAssertNil(shown.right)
    }

    func testSeveralWaitingOpenAtTheAgentsCard() {
        let shown = ears(input(sessions: [waiting("a"), waiting("b")]))
        XCTAssertEqual(shown.left?.action, .open(subject: nil, reveal: .agents))
    }

    func testASignedOutClaudeOpensClaudesPage() {
        let shown = ears(input(services: [ServiceSnapshot.notSignedIn(reason: .notFound, message: "Signed out.", at: now)]))
        XCTAssertEqual(shown.left?.mark, .head)
        XCTAssertEqual(shown.left?.action, .open(subject: "claude", reveal: nil))
    }

    func testAnAlertShowsTheHeadAndItsNumberBothOpeningThatProvider() {
        let shown = ears(input(services: [claude(week: 92)]))
        XCTAssertEqual(shown.left?.mark, .head)
        XCTAssertEqual(shown.left?.action, .open(subject: "claude", reveal: nil))
        XCTAssertEqual(shown.right?.mark, .number(lines: ["92%"]))
        XCTAssertEqual(shown.right?.action, .open(subject: "claude", reveal: nil))
    }

    /// OWNER 1: each ear does what it shows.
    func testWithAnAgentWaitingTheNumberStillOpensItsProvider() {
        let session = waiting("a")
        let shown = ears(input(sessions: [session], services: [claude(week: 92)]))
        XCTAssertEqual(shown.left?.action, .jump(sessionID: session.id))
        XCTAssertEqual(shown.right?.action, .open(subject: "claude", reveal: nil))
    }

    /// OWNER 3: "8% left" sets 38 pt wide at the text floor; the ear is 34.
    func testRemainingModeSetsNumberAndWordOnTwoLines() {
        XCTAssertEqual(ears(input(services: [claude(week: 92)], mode: .remaining)).right?.mark, .number(lines: ["8%", "left"]))
    }

    func testAnEarTooShortForTwoLinesKeepsTheNumber() {
        XCTAssertEqual(
            ears(input(services: [claude(week: 92)], mode: .remaining, earHeight: 27)).right?.mark,
            .number(lines: ["8%"])
        )
    }

    func testThePetOffShowsANeutralDotInsteadOfTheHead() {
        let shown = ears(input(services: [claude(week: 92)], pet: false))
        XCTAssertEqual(shown.left?.mark, .neutralDot)
        XCTAssertEqual(shown.right?.mark, .number(lines: ["92%"]))
    }

    func testTheEarsOffShowNothing() {
        XCTAssertEqual(
            ears(input(
                sessions: [waiting("a")], services: [claude(week: 92)],
                keepAwake: .armed(deadline: now + 3_600, floorEnabled: true), ears: false
            )),
            IslandEars.none
        )
    }

    func testTheMoonShowsWhileKeepAwakeIsOnAndTheItemHidden() {
        let shown = ears(input(keepAwake: .armed(deadline: now + 3_600, floorEnabled: true)))
        XCTAssertNil(shown.left, "the moon alone needs no head")
        XCTAssertEqual(shown.right?.mark, .moon)
        XCTAssertEqual(shown.right?.action, .open(subject: nil, reveal: .keepAwake))
    }

    func testTheMoonGivesWayToTheAlertsNumber() {
        let shown = ears(input(services: [claude(week: 92)], keepAwake: .armed(deadline: now + 3_600, floorEnabled: true)))
        XCTAssertEqual(shown.right?.mark, .number(lines: ["92%"]))
    }

    func testNoMoonWithTheItemShownOrPastTheDeadline() {
        let armed = KeepAwakeState.armed(deadline: now + 3_600, floorEnabled: true)
        XCTAssertNil(ears(input(keepAwake: armed, itemShown: true)).right)
        XCTAssertNil(ears(input(keepAwake: .armed(deadline: now - 1, floorEnabled: true))).right)
        XCTAssertTrue(StatusItemVisibilityRules.showsMoonEar(keepAwakeOn: true, itemShown: false))
        XCTAssertFalse(StatusItemVisibilityRules.showsMoonEar(keepAwakeOn: false, itemShown: false))
        XCTAssertFalse(StatusItemVisibilityRules.showsMoonEar(keepAwakeOn: true, itemShown: true))
    }

    func testEveryEarHasItsOwnWordsForVoiceOver() {
        XCTAssertEqual(ears(input(sessions: [waiting("a")])).left?.label, "Usage tracker is waiting, go to it")
        XCTAssertEqual(ears(input(sessions: [waiting("a"), waiting("b")])).left?.label, "2 agents are waiting, open Omelette")
        XCTAssertEqual(
            ears(input(services: [ServiceSnapshot.notSignedIn(reason: .notFound, message: "Signed out.", at: now)])).left?.label,
            "\(ClaudeSignInCopy.petLine(.signIn)), open Claude"
        )
        let alert = ears(input(services: [claude(week: 92)]))
        XCTAssertEqual(alert.left?.label, "Claude week 92 percent used, open Claude")
        XCTAssertEqual(alert.right?.label, "Claude week 92 percent used, open Claude")
        XCTAssertEqual(
            ears(input(services: [claude(week: 92)], mode: .remaining)).right?.label,
            "Claude week 8 percent left, open Claude"
        )
        let deadline = now + 3_600
        XCTAssertEqual(
            ears(input(keepAwake: .armed(deadline: deadline, floorEnabled: true))).right?.label,
            "Keep awake until \(KeepAwakeCopy.clock(deadline, now: now, calendar: utc, locale: locale)), open Omelette"
        )
    }

    /// § 3.6: at most 34 pt, § 3.3: the text floor is 11. Measured in the font the ear draws.
    func testEveryNumberFitsTheEarInItsOwnFont() {
        let room = IslandEarRules.earWidth - 2 * IslandEarRules.numberInset
        XCTAssertLessThanOrEqual(IslandEarRules.earWidth, 34)
        for used in stride(from: 90.0, through: 100.0, by: 1.0) {
            for mode in [PercentDisplay.Mode.used, .remaining] {
                let lines = IslandEarCopy.numberLines(used, mode: mode, earHeight: 32)
                let size = IslandEarRules.numberSize(lines: lines)
                XCTAssertGreaterThanOrEqual(size, 11)
                let font = IslandEarRules.numberFont(size: size)
                for line in lines {
                    let width = (line as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertLessThanOrEqual(width, room, "\(line) at \(size)")
                }
            }
        }
    }

    private func ears(
        _ state: IslandEarInput, onDisplays screens: [IslandScreen], earsOn: Bool = true, showInMenuBar: Bool? = nil
    ) -> IslandEars {
        IslandEarRules.ears(
            mood: state.mood, mode: state.mode, petOn: state.petOn, earsOn: earsOn, showInMenuBar: showInMenuBar,
            screens: screens, now: now, calendar: utc, locale: locale
        )
    }

    /// A lid opening or a notched display arriving changes nothing but the displays (Codex's plan
    /// review 4).
    func testAnEarShowsOnceANotchedDisplayArrivesWithNothingElseChanged() {
        let state = input(sessions: [waiting("a")])
        XCTAssertEqual(ears(state, onDisplays: [ScreenFixture.externalRight]), IslandEars.none)
        XCTAssertEqual(ears(state, onDisplays: [ScreenFixture.externalRight, ScreenFixture.builtIn]).left?.mark, .head)
        XCTAssertEqual(ears(state, onDisplays: [ScreenFixture.builtIn], earsOn: false), IslandEars.none)
    }

    func testTheDisplaysDecideTheItemAndTheEarsHeight() {
        let armed = input(keepAwake: .armed(deadline: now + 3_600, floorEnabled: true))
        XCTAssertEqual(ears(armed, onDisplays: [ScreenFixture.builtIn]).right?.mark, .moon, "hidden by default beside a notch")
        XCTAssertNil(ears(armed, onDisplays: [ScreenFixture.builtIn], showInMenuBar: true).right)
        let short = IslandScreen(
            id: 5, frame: ScreenFixture.builtIn.frame, visibleFrame: ScreenFixture.builtIn.visibleFrame, safeAreaTop: 27,
            auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        XCTAssertEqual(
            ears(input(services: [claude(week: 92)], mode: .remaining), onDisplays: [short]).right?.mark,
            .number(lines: ["8%"])
        )
    }

    func testTheHeadIsDrawnOnWholePixelsInsideTheEar() {
        let retina = IslandEarRules.headScale(earHeight: 32, backingScale: 2)
        XCTAssertEqual(retina.pixelsPerBead, 3, "the pet's own bead")
        XCTAssertEqual(retina.points(beads: PetContract.earSize), 24)
        XCTAssertEqual(IslandEarRules.headScale(earHeight: 22, backingScale: 2).points(beads: PetContract.earSize), 16)
        let rect = IslandEarRules.headRect(in: CGRect(x: 10.5, y: 0, width: 34, height: 32), scale: retina)
        XCTAssertEqual(rect, CGRect(x: 15.5, y: 4, width: 24, height: 24))
    }
}
