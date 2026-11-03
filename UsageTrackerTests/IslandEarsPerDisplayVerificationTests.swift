import CoreGraphics
import XCTest
@testable import Omelette

/// Spec 2026-11-03 § Ears and hint (P2) with its Amendment after the spike: every island display
/// gets the ears from the same ear model, set for that display's own notch height and backing scale;
/// the notched MacBook alone reads as it did in 4.0; an ear's display is the one it is keyed by.
final class IslandEarsPerDisplayVerificationTests: XCTestCase {
    private let now = PetRuntimeFixture.t0
    private let locale = Locale(identifier: "en_GB")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func mood(
        sessions: [AgentSession] = [], services: [ServiceSnapshot] = [], keepAwake: KeepAwakeState = .idle
    ) -> PetMoodInput {
        PetMoodInput(
            sessions: sessions, services: services, enabledIDs: ["claude", "codex"],
            claudeBinaryFound: true, keepAwake: keepAwake
        )
    }

    private func byDisplay(
        _ mood: PetMoodInput, on screens: [IslandScreen], mode: PercentDisplay.Mode = .remaining,
        petOn: Bool = true, earsOn: Bool = true, showInMenuBar: Bool? = nil
    ) -> [UInt32: IslandEars] {
        IslandEarRules.earsByDisplay(
            mood: mood, mode: mode, petOn: petOn, earsOn: earsOn, showInMenuBar: showInMenuBar,
            screens: screens, now: now, calendar: utc, locale: locale
        )
    }

    private func claude(week percent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: percent, kind: .weekly),
        ], at: now)
    }

    private func waiting(_ id: String) -> AgentSession {
        Fixture.agentSession(sessionID: id, projectName: "Usage tracker", state: .needsYou)
    }

    /// A wide display whose island notch is `height` tall: a menu bar measured at `height`.
    private func virtual(id: UInt32, height: CGFloat, backingScale: CGFloat = 2, x: CGFloat = 1512) -> IslandScreen {
        var screen = IslandScreen(
            id: id,
            frame: CGRect(x: x, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: x, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil,
            backingScale: backingScale
        )
        screen.measuredMenuBarHeight = height
        return screen
    }

    // MARK: - The notched MacBook alone is the 4.0 island

    func testTheNotchedMacBookAloneHasOneDisplaysEarsAsIn40() {
        let state = mood(sessions: [waiting("a")], services: [claude(week: 92)])
        let alone = IslandScreen.attached([ScreenFixture.builtIn], menuBarWindows: [MenuBarWindowFixture.builtIn])
        let ears = byDisplay(state, on: alone)
        XCTAssertEqual(Set(ears.keys), [1])
        // The 4.0 input for the 14-inch: ear 32 pt, head at 2x, "8%" over "left".
        let expected = IslandEarRules.ears(
            IslandEarInput(
                mood: state, mode: .remaining, petOn: true, showsEars: true, statusItemShown: false,
                earHeight: 32, backingScale: 2
            ),
            now: now, calendar: utc, locale: locale
        )
        XCTAssertEqual(ears[1], expected)
        XCTAssertEqual(ears[1]?.left?.mark, .head)
        XCTAssertEqual(ears[1]?.right?.mark, .number(lines: ["8%", "left"]))
    }

    /// A full-screen space on the MacBook takes its menu bar window away; the camera housing is still
    /// there, so its ears are the same as with the bar showing.
    func testTheMacBooksEarsDoNotDependOnItsMenuBarWindow() {
        let state = mood(sessions: [waiting("a")], services: [claude(week: 92)])
        let shown = byDisplay(
            state, on: IslandScreen.attached([ScreenFixture.builtIn], menuBarWindows: [MenuBarWindowFixture.builtIn])
        )
        let hidden = byDisplay(state, on: IslandScreen.attached([ScreenFixture.builtIn], menuBarWindows: []))
        let unmeasured = byDisplay(state, on: IslandScreen.attached([ScreenFixture.builtIn]))
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(hidden, shown)
        XCTAssertEqual(unmeasured, shown)
    }

    // MARK: - Each display's own notch height

    func testEachDisplayTakesTheNumberInItsOwnNotchHeight() {
        let screens = [
            ScreenFixture.builtIn,                 // camera housing, 32
            virtual(id: 2, height: 30),           // the owner's external
            virtual(id: 3, height: 28, x: 4072),  // the two-line floor
            virtual(id: 4, height: 27, x: 6632),
            virtual(id: 5, height: 24, x: 9192),
        ]
        let ears = byDisplay(mood(services: [claude(week: 92)]), on: IslandScreen.attached(screens))
        let two = IslandEars.RightMark.number(lines: ["8%", "left"])
        let one = IslandEars.RightMark.number(lines: ["8%"])
        XCTAssertEqual(ears[1]?.right?.mark, two)
        XCTAssertEqual(ears[2]?.right?.mark, two, "30 pt holds two lines")
        XCTAssertEqual(ears[3]?.right?.mark, two)
        XCTAssertEqual(ears[4]?.right?.mark, one)
        XCTAssertEqual(ears[5]?.right?.mark, one)
    }

    func testTheMeasuredMenuBarHeightNotTheVisibleFrameSetsTheEarHeight() {
        // Setup 1 of the spike: the external's visible frame is its frame; its menu bar is 30 pt.
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        let ears = byDisplay(mood(services: [claude(week: 92)]), on: screens)
        XCTAssertEqual(Set(ears.keys), [1, 2])
        XCTAssertEqual(ears[2]?.right?.mark, .number(lines: ["8%", "left"]), "30 pt, not the 24 pt a default would give")
    }

    // MARK: - The head where it fits

    /// 26 beads, one whole pixel each at the least: 26 pt on a 1x display, 13 pt on 2x, 8.7 pt on 3x.
    func testTheHeadFitsOnEveryHeightAndScaleButTheShortPillsOn1x() {
        for height: CGFloat in [24, 25, 26, 30, 32] {
            for scale: CGFloat in [1, 2, 3] {
                let expected = scale >= 2 || height >= 26
                XCTAssertEqual(
                    IslandEarRules.headFits(earHeight: height, backingScale: scale), expected,
                    "\(height) pt at \(scale)x"
                )
            }
        }
    }

    func testTheLeftEarMarkFollowsEachDisplaysOwnHeightAndScale() {
        let screens = IslandScreen.attached([
            virtual(id: 1, height: 24, backingScale: 1, x: 0),
            virtual(id: 2, height: 25, backingScale: 1, x: 2560),
            virtual(id: 3, height: 26, backingScale: 1, x: 5120),
            virtual(id: 4, height: 30, backingScale: 1, x: 7680),
            virtual(id: 5, height: 24, backingScale: 2, x: 10240),
            virtual(id: 6, height: 24, backingScale: 3, x: 12800),
        ])
        let ears = byDisplay(mood(sessions: [waiting("a")]), on: screens)
        XCTAssertEqual(ears.mapValues { $0.left?.mark }, [
            1: .neutralDot, 2: .neutralDot, 3: .head, 4: .head, 5: .head, 6: .head,
        ])
    }

    func testTheDotStillDoesWhatTheEarSaysOnEveryDisplay() {
        let session = waiting("a")
        let ears = byDisplay(
            mood(sessions: [session]),
            on: IslandScreen.attached([ScreenFixture.builtIn, virtual(id: 2, height: 24, backingScale: 1)])
        )
        XCTAssertEqual(ears[1]?.left?.mark, .head)
        XCTAssertEqual(ears[2]?.left?.mark, .neutralDot)
        XCTAssertEqual(ears[1]?.left?.action, .jump(sessionID: session.id))
        XCTAssertEqual(ears[2]?.left?.action, ears[1]?.left?.action)
        XCTAssertEqual(ears[2]?.left?.label, ears[1]?.left?.label)
    }

    func testWithThePetOffEveryDisplayShowsTheDot() {
        let ears = byDisplay(
            mood(sessions: [waiting("a")]),
            on: IslandScreen.attached([ScreenFixture.builtIn, virtual(id: 2, height: 30)]), petOn: false
        )
        XCTAssertEqual(ears.mapValues { $0.left?.mark }, [1: .neutralDot, 2: .neutralDot])
    }

    // MARK: - An ear belongs to its display

    func testAnEarsDisplayIsTheKeyItIsReadUnderAndTheIslandOpensThere() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        let ears = byDisplay(mood(services: [claude(week: 92)]), on: screens)
        for id: UInt32 in [1, 2] {
            XCTAssertEqual(ears[id]?.right?.action, .open(subject: "claude", reveal: nil))
            // The controller hands this id to `.ear(displayID:)`: the island opens on that display.
            let placement = IslandDisplayResolver.placement(
                for: .ear(displayID: id), screens: screens, mainScreenID: 1,
                statusItemFrame: nil, panelWidth: 360, menuBarHeight: 0
            )
            XCTAssertEqual(placement?.screenID, id)
            XCTAssertEqual(placement?.kind, .island)
            XCTAssertEqual(placement?.notch, screens.first { $0.id == id }?.islandNotch)
        }
    }

    func testAnEarOnAnExternalNeverOpensTheIslandOnTheMacBook() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal],
            menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]
        )
        let placement = IslandDisplayResolver.placement(
            for: .ear(displayID: 2), screens: screens, mainScreenID: 1,
            statusItemFrame: nil, panelWidth: 360, menuBarHeight: 0
        )
        XCTAssertEqual(placement?.screenID, 2)
        XCTAssertEqual(placement.map { $0.anchorMidX }, 2792, "centred on the external's own notch")
    }

    // MARK: - Displays that lose and keep their island

    func testADisplayWithoutMenuBarWindowHasNoEarsAndTheMacBookKeepsItsOwn() {
        let screens = IslandScreen.attached(
            [ScreenFixture.builtIn, ScreenFixture.secondaryExternal], menuBarWindows: [MenuBarWindowFixture.builtIn]
        )
        let ears = byDisplay(mood(sessions: [waiting("a")]), on: screens)
        XCTAssertEqual(Set(ears.keys), [1])
        XCTAssertEqual(ears[1]?.left?.mark, .head)
    }

    func testWithTheLidClosedTheExternalAsMainGetsTheEars() {
        let screens = IslandScreen.attached(
            [ScreenFixture.lidClosedExternal], menuBarWindows: [MenuBarWindowFixture.lidClosedExternal]
        )
        let ears = byDisplay(mood(sessions: [waiting("a")], services: [claude(week: 92)]), on: screens)
        XCTAssertEqual(Set(ears.keys), [2])
        XCTAssertEqual(ears[2]?.left?.mark, .head)
        XCTAssertEqual(ears[2]?.right?.mark, .number(lines: ["8%", "left"]))
    }

    func testTheOneDisplayViewIsTheMacBooksWhicheverOrderTheDisplaysComeIn() {
        let state = mood(services: [claude(week: 92)])
        let a = IslandScreen.attached([ScreenFixture.secondaryExternal, ScreenFixture.builtIn],
                                      menuBarWindows: [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal])
        let primary = IslandEarRules.ears(
            mood: state, mode: .remaining, petOn: true, earsOn: true, showInMenuBar: nil,
            screens: a, now: now, calendar: utc, locale: locale
        )
        XCTAssertEqual(primary, byDisplay(state, on: a)[1])
    }

    // MARK: - The same marks, words and moon everywhere

    func testTheMoonShowsOnEveryIslandDisplayWhileTheStatusItemIsHidden() {
        let armed = KeepAwakeState.armed(deadline: now + 3_600, floorEnabled: true)
        let screens = IslandScreen.attached([ScreenFixture.builtIn, virtual(id: 2, height: 30)])
        let hiddenItem = byDisplay(mood(keepAwake: armed), on: screens, showInMenuBar: nil)
        XCTAssertEqual(hiddenItem.mapValues { $0.right?.mark }, [1: .moon, 2: .moon])
        XCTAssertEqual(hiddenItem[2]?.right?.action, .open(subject: nil, reveal: .keepAwake))
        XCTAssertEqual(hiddenItem[1]?.right?.label, hiddenItem[2]?.right?.label)
        let shownItem = byDisplay(mood(keepAwake: armed), on: screens, showInMenuBar: true)
        XCTAssertEqual(shownItem, [1: .none, 2: .none])
    }

    func testTheEarsOffLeavesEveryIslandDisplayItsPillWithNoEar() {
        let screens = IslandScreen.attached([ScreenFixture.builtIn, virtual(id: 2, height: 30)])
        XCTAssertEqual(
            byDisplay(mood(sessions: [waiting("a")], services: [claude(week: 92)]), on: screens, earsOn: false),
            [1: .none, 2: .none]
        )
    }
}
