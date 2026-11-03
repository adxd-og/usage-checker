import XCTest
@testable import Omelette

/// Tester's verification of spec 2026-11-03 § Resting pill, § Opening and § Status item (P1), plus
/// the plan's round-2 amendments (a stale pill gives the panel on its display; a vanished display
/// gives nothing). Fixtures differ from the coder's: a notched MacBook whose menu bar hides, a
/// display stacked above the main one, and whole scenarios (lid open, lid closed, only narrow
/// displays) run through every rule that reads the displays. The notched MacBook alone must come out
/// as in 4.0, whatever else is attached.
final class NotchlessEntryVerificationTests: XCTestCase {
    private let now = PetRuntimeFixture.t0
    private let locale = Locale(identifier: "en_GB")
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The 14-inch with its menu bar auto-hidden: the visible frame reaches the top. The notch is still there.
    private let builtInMenuBarHidden = IslandScreen(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 78, width: 1512, height: 904),
        safeAreaTop: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
    )

    /// 1920 x 1080 stacked above the main display, menu bar 24.
    private let above = IslandScreen(
        id: 6, frame: CGRect(x: 0, y: 982, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 982, width: 1920, height: 1056),
        safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
    )

    private func place(
        _ entry: IslandEntry, on screens: [IslandScreen], main: UInt32? = 1, item: CGRect? = nil
    ) -> IslandDisplayResolver.Placement? {
        IslandDisplayResolver.placement(
            for: entry, screens: IslandScreen.attached(screens), mainScreenID: main,
            statusItemFrame: item, panelWidth: 360, menuBarHeight: 24
        )
    }

    // MARK: - The notched MacBook alone is 4.0

    func testTheLoneMacBookOpensTheIslandOnItsCameraHousingAsIn40() {
        let expected = IslandDisplayResolver.Placement(
            kind: .island, screenID: 1,
            windowFrame: CGRect(x: 424, y: 86, width: 664, height: 896),
            anchorMidX: 756, notch: CGRect(x: 663.5, y: 950, width: 185, height: 32), bodyWidth: 640
        )
        for entry in [IslandEntry.notch(displayID: 1), .ear(displayID: 1)] {
            XCTAssertEqual(place(entry, on: [ScreenFixture.builtIn]), expected, "\(entry)")
        }
        XCTAssertEqual(place(.notification(pointer: CGPoint(x: 100, y: 100)), on: [ScreenFixture.builtIn]), expected)
    }

    func testAttachingDisplaysNeverMovesTheMacBooksIslandPillOrEars() {
        let alone = place(.notch(displayID: 1), on: [ScreenFixture.builtIn])
        let ears = { (screens: [IslandScreen]) in
            IslandEarRules.ears(
                mood: PetMoodInput(
                    sessions: [Fixture.agentSession(sessionID: "a", projectName: "p", state: .needsYou)],
                    services: [], enabledIDs: ["claude", "codex"], claudeBinaryFound: true, keepAwake: .idle
                ),
                mode: .used, petOn: true, earsOn: true, showInMenuBar: nil,
                screens: IslandScreen.attached(screens), now: self.now, calendar: self.utc, locale: self.locale
            )
        }
        let aloneEars = ears([ScreenFixture.builtIn])
        XCTAssertEqual(aloneEars.left?.mark, .head)
        for others in [
            [ScreenFixture.builtIn, ScreenFixture.externalRight],
            [ScreenFixture.externalRight, ScreenFixture.builtIn],
            [ScreenFixture.externalLeft, ScreenFixture.builtIn, ScreenFixture.narrow1279, above],
        ] {
            XCTAssertEqual(place(.notch(displayID: 1), on: others), alone)
            XCTAssertEqual(ears(others), aloneEars)
            XCTAssertEqual(
                IslandDisplayResolver.primaryIslandScreen(IslandScreen.attached(others))?.id, 1,
                "the ears and the first-launch open stay on the camera housing"
            )
            let pill = RestingPillRules.pills(IslandScreen.attached(others)).first { $0.displayID == 1 }
            XCTAssertEqual(pill?.notch, CGRect(x: 663.5, y: 950, width: 185, height: 32))
        }
    }

    func testTheMacBookWithItsMenuBarHiddenKeepsItsNotchPillAndItemDefault() {
        let screens = [builtInMenuBarHidden]
        XCTAssertEqual(RestingPillRules.pills(screens).map(\.notch), [CGRect(x: 663.5, y: 950, width: 185, height: 32)])
        XCTAssertEqual(place(.notch(displayID: 1), on: screens)?.kind, .island)
        XCTAssertTrue(StatusItemVisibilityRules.islandDisplayAttached(screens))
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: true))
    }

    func testTheLoneMacBooksItemIsOffByDefaultAndTheOneTimeOpenIsDue() {
        let attached = StatusItemVisibilityRules.islandDisplayAttached([ScreenFixture.builtIn])
        XCTAssertFalse(StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: attached))
        XCTAssertEqual(
            StatusItemVisibilityRules.firstLaunchAfterUpdate(
                alreadyMarked: false, hasSeenOnboarding: true, setting: nil, islandDisplayAttached: attached
            ),
            .openIsland
        )
    }

    // MARK: - Opening on the display clicked

    func testEveryIslandDisplaysEntryOpensItsOwnIslandCentredOnItsNotchInsideItsFrame() {
        let all = [ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.externalLeft, ScreenFixture.wide1280, above]
        for screen in all {
            for entry in [IslandEntry.notch(displayID: screen.id), .ear(displayID: screen.id)] {
                // main is a different display on purpose: the entry's id decides.
                let placed = place(entry, on: all, main: screen.id == 1 ? 2 : 1)
                XCTAssertEqual(placed?.kind, .island, "\(screen.id) \(entry)")
                XCTAssertEqual(placed?.screenID, screen.id)
                XCTAssertEqual(placed?.notch?.midX, screen.frame.midX)
                XCTAssertEqual(placed?.notch?.maxY, screen.frame.maxY)
                XCTAssertEqual(placed?.anchorMidX, screen.frame.midX)
                if let window = placed?.windowFrame {
                    XCTAssertTrue(screen.frame.contains(window), "\(screen.id): \(window) inside \(screen.frame)")
                    XCTAssertEqual(window.maxY, screen.frame.maxY, "the island hangs from the display's top")
                }
            }
        }
    }

    // MARK: - Stale pills

    func testAPillWhoseDisplayStoppedShowingItsMenuBarOpensThePanelOnThatDisplayInsideItsVisibleFrame() {
        let hiddenAbove = IslandScreen(
            id: 6, frame: above.frame, visibleFrame: above.frame,
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        let screens = [ScreenFixture.builtIn, hiddenAbove]
        for entry in [IslandEntry.notch(displayID: 6), .ear(displayID: 6)] {
            let placed = place(entry, on: screens)
            XCTAssertEqual(placed?.kind, .panel, "\(entry)")
            XCTAssertEqual(placed?.screenID, 6)
            XCTAssertNil(placed?.notch)
            XCTAssertTrue(hiddenAbove.visibleFrame.contains(placed?.windowFrame ?? .null), "\(String(describing: placed))")
            XCTAssertTrue(IslandDisplayResolver.clickedPillIsStale(entry, screens: screens))
        }
    }

    func testAPillWhoseDisplayShrankUnderTheFloorGivesThePanelNotTheMacBooksIsland() {
        let screens = [ScreenFixture.builtIn, ScreenFixture.narrow1279]
        let placed = place(.notch(displayID: 13), on: screens, main: 1)
        XCTAssertEqual(placed?.kind, .panel)
        XCTAssertEqual(placed?.screenID, 13)
    }

    func testAVanishedDisplayGivesNoPlacementWhateverTheStatusItemOrTheMainDisplay() {
        let screens = [ScreenFixture.builtIn, ScreenFixture.externalRight]
        let item = CGRect(x: 2700, y: 1416, width: 24, height: 24)
        XCTAssertNil(place(.notch(displayID: 3), on: screens, main: 1, item: item))
        XCTAssertNil(place(.ear(displayID: 3), on: screens, main: 3, item: item))
        XCTAssertNil(place(.notch(displayID: 3), on: [], main: nil))
        XCTAssertNil(IslandDisplayResolver.display(for: .notch(displayID: 3), screens: screens, mainScreenID: 1))
    }

    func testAPillThatIsStillCurrentIsNotStaleAndANotificationNeverIs() {
        let screens = IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.narrow1279])
        XCTAssertFalse(IslandDisplayResolver.clickedPillIsStale(.notch(displayID: 2), screens: screens))
        XCTAssertFalse(IslandDisplayResolver.clickedPillIsStale(.ear(displayID: 1), screens: screens))
        XCTAssertTrue(IslandDisplayResolver.clickedPillIsStale(.notch(displayID: 13), screens: screens))
        XCTAssertFalse(IslandDisplayResolver.clickedPillIsStale(.notification(pointer: CGPoint(x: -5, y: -5)), screens: screens))
    }

    func testAnOpenIslandWhoseDisplayLosesItsMenuBarBecomesThePanelThereAndAVanishedOneCloses() throws {
        let screens = IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRight])
        let entry = IslandEntry.notch(displayID: 2)
        let open = try XCTUnwrap(
            IslandDisplayResolver.placement(
                for: entry, screens: screens, mainScreenID: 1, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
            )
        )
        XCTAssertEqual(open.kind, .island)
        let hidden = IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.externalRightMenuBarHidden])
        let again = IslandDisplayResolver.replacement(
            for: open, entry: entry, screens: hidden, statusItemFrame: nil, panelWidth: 360, menuBarHeight: 24
        )
        XCTAssertEqual(again?.kind, .panel)
        XCTAssertEqual(again?.screenID, 2)
        XCTAssertNil(
            IslandDisplayResolver.replacement(
                for: open, entry: entry, screens: [ScreenFixture.builtIn], statusItemFrame: nil,
                panelWidth: 360, menuBarHeight: 24
            )
        )
    }

    // MARK: - Two notched displays: the first listed carries the ears

    func testWithTwoNotchedDisplaysThePrimaryAndTheEarsAreTheFirstListed() {
        let short = IslandScreen(
            id: 5, frame: CGRect(x: 2000, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 2000, y: 78, width: 1512, height: 905),
            safeAreaTop: 27, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
        XCTAssertEqual(IslandDisplayResolver.primaryIslandScreen([short, ScreenFixture.builtIn])?.id, 5)
        XCTAssertEqual(IslandDisplayResolver.primaryIslandScreen([ScreenFixture.builtIn, short])?.id, 1)
        let mood = PetMoodInput(
            sessions: [], services: [
                Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
                    Fixture.bucket(id: "seven_day", label: "All models", percent: 92, kind: .weekly),
                ], at: now),
            ],
            enabledIDs: ["claude", "codex"], claudeBinaryFound: true, keepAwake: .idle
        )
        func rightMark(_ screens: [IslandScreen]) -> IslandEars.RightMark? {
            IslandEarRules.ears(
                mood: mood, mode: .remaining, petOn: true, earsOn: true, showInMenuBar: nil,
                screens: IslandScreen.attached(screens), now: now, calendar: utc, locale: locale
            ).right?.mark
        }
        XCTAssertEqual(rightMark([short, ScreenFixture.builtIn]), .number(lines: ["8%"]), "27 pt ears: the first display's")
        XCTAssertEqual(rightMark([ScreenFixture.builtIn, short]), .number(lines: ["8%", "left"]), "32 pt ears: the first display's")
    }

    // MARK: - Pills

    func testEveryPillsWindowCoversItsNotchOnWholePointsEvenOnHalfPointCentres() {
        let screens = IslandScreen.attached([
            ScreenFixture.builtIn, ScreenFixture.externalRight, ScreenFixture.externalLeft, ScreenFixture.wide1280, above,
        ])
        let pills = RestingPillRules.pills(screens)
        XCTAssertEqual(pills.count, 5)
        for pill in pills {
            let window = RestingLayout.frame(notch: pill.notch, left: false, right: false, hintRoom: false)
            XCTAssertTrue(window.contains(pill.notch), "display \(pill.displayID)")
            XCTAssertEqual(window.minX, window.minX.rounded(), "display \(pill.displayID)")
            XCTAssertEqual(window.width, window.width.rounded())
            XCTAssertEqual(window.maxY, pill.notch.maxY, "flush with the top of its display")
            XCTAssertLessThanOrEqual(window.width, pill.notch.width + 2, "no more than the rounding")
        }
    }

    func testTheClamshellSwapMovesThePillWidthToTheFallbackAndOnlyThatDisplayKeepsAPill() {
        let open = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.builtIn, ScreenFixture.narrowNotched, ScreenFixture.externalRight]))
        XCTAssertEqual(open.map(\.displayID), [1, 4, 2])
        XCTAssertEqual(open.last?.notch.width, 185, "the first notch listed, the 14-inch's")
        let closed = RestingPillRules.pills(IslandScreen.attached([ScreenFixture.externalRight]))
        XCTAssertEqual(closed.map(\.displayID), [2])
        XCTAssertEqual(closed.first?.notch.width, 185)
        XCTAssertEqual(
            RestingPillRules.changes(kept: Set(open.map(\.displayID)), wanted: closed),
            RestingPillRules.Changes(create: [], drop: [1, 4])
        )
    }

    // MARK: - Status item: the setting x the displays

    private struct Scenario {
        let name: String
        let screens: [IslandScreen]
        let island: Bool
    }

    private var scenarios: [Scenario] {
        [
            Scenario(name: "MacBook alone", screens: [ScreenFixture.builtIn], island: true),
            Scenario(name: "MacBook + external", screens: [ScreenFixture.builtIn, ScreenFixture.externalRight], island: true),
            Scenario(name: "clamshell, external", screens: [ScreenFixture.externalRight], island: true),
            Scenario(name: "clamshell, 1280 pt external", screens: [ScreenFixture.wide1280], island: true),
            Scenario(name: "MacBook, menu bar hidden", screens: [builtInMenuBarHidden], island: true),
            Scenario(name: "MacBook + narrow external", screens: [ScreenFixture.builtIn, ScreenFixture.narrow1279], island: true),
            Scenario(name: "clamshell, 1279 pt external", screens: [ScreenFixture.narrow1279], island: false),
            Scenario(name: "clamshell, hidden menu bar", screens: [ScreenFixture.externalRightMenuBarHidden], island: false),
            Scenario(
                name: "only narrow and hidden",
                screens: [ScreenFixture.narrow1279, ScreenFixture.externalLeftMenuBarHidden], island: false
            ),
            Scenario(name: "no display", screens: [], island: false),
        ]
    }

    func testTheItemMatrixForEveryScenarioAndEverySetting() {
        for scenario in scenarios {
            let attached = StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.attached(scenario.screens))
            XCTAssertEqual(attached, scenario.island, scenario.name)
            XCTAssertEqual(StatusItemVisibilityRules.switchEnabled(islandDisplayAttached: attached), scenario.island, scenario.name)
            let expected: [(Bool?, Bool)] = scenario.island
                ? [(nil, false), (true, true), (false, false)]
                : [(nil, true), (true, true), (false, true)]
            for (setting, shown) in expected {
                XCTAssertEqual(
                    StatusItemVisibilityRules.isShown(setting: setting, islandDisplayAttached: attached), shown,
                    "\(scenario.name), setting \(String(describing: setting))"
                )
            }
        }
    }

    func testTheMoonMovesToTheEarExactlyWhereTheItemIsOffByDefault() {
        for scenario in scenarios {
            let attached = StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.attached(scenario.screens))
            let shown = StatusItemVisibilityRules.isShown(setting: nil, islandDisplayAttached: attached)
            XCTAssertEqual(StatusItemVisibilityRules.showsMoonEar(keepAwakeOn: true, itemShown: shown), scenario.island, scenario.name)
        }
    }

    func testAFourOhUserOnEveryScenarioGetsTheOneTimeOpenOnlyWhereTheItemWentAway() {
        for scenario in scenarios {
            let attached = StatusItemVisibilityRules.islandDisplayAttached(IslandScreen.attached(scenario.screens))
            XCTAssertEqual(
                StatusItemVisibilityRules.firstLaunchAfterUpdate(
                    alreadyMarked: false, hasSeenOnboarding: true, setting: nil, islandDisplayAttached: attached
                ),
                scenario.island ? .openIsland : .nothing, scenario.name
            )
            XCTAssertEqual(
                StatusItemVisibilityRules.firstLaunchAfterUpdate(
                    alreadyMarked: true, hasSeenOnboarding: true, setting: nil, islandDisplayAttached: attached
                ),
                .nothing, "\(scenario.name): once"
            )
            XCTAssertEqual(
                StatusItemVisibilityRules.firstLaunchAfterUpdate(
                    alreadyMarked: false, hasSeenOnboarding: true, setting: false, islandDisplayAttached: attached
                ),
                .markOnly, "\(scenario.name): someone who met the switch"
            )
        }
    }
}
