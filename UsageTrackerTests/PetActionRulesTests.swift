import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Mood rule" (the Click column), § 3.8 (the habitat's action
/// is the click), D11 (the top mood's action, a pat when idle): what a click on the pet does in the
/// island, for the page it shows and the providers on screen, and when a card it asks for can be
/// brought into view (Codex review 2).
final class PetActionRulesTests: XCTestCase {
    private let four = ["claude", "codex", "antigravity", "grok"]
    private let codex = IslandNavigation.Page.provider("codex")

    private func effects(
        _ action: PetAction, on page: IslandNavigation.Page = .all, providers: [String]? = nil
    ) -> [PetEffect] {
        PetActionRules.effects(of: action, page: page, providers: providers ?? four)
    }

    func testOneWaitingSessionIsAJump() {
        XCTAssertEqual(effects(.jump(sessionID: "claude:s1")), [.jump(sessionID: "claude:s1")])
        XCTAssertEqual(effects(.jump(sessionID: "claude:s1"), on: codex), [.jump(sessionID: "claude:s1")])
    }

    func testTheNeedsYouListAndTheWorkingAgentsAreAllsAgentsCard() {
        for action in [PetAction.needsYouList, .agentsCard] {
            XCTAssertEqual(effects(action), [.reveal(.agents)], "\(action) at All")
            XCTAssertEqual(effects(action, on: codex), [.navigate(.back), .reveal(.agents)], "\(action) from a page")
            XCTAssertEqual(
                effects(action, on: .provider("grok"), providers: ["grok"]), [.reveal(.agents)],
                "\(action): one provider's page is home"
            )
        }
    }

    func testClaudesSignInAndInstallLinkLeaveTheIslandForTheirApp() {
        XCTAssertEqual(effects(.claudeRecovery(.signIn)), [.closeIsland, .signIn])
        XCTAssertEqual(effects(.claudeRecovery(.install), on: codex), [.closeIsland, .openInstallPage])
    }

    func testKeychainAccessOpensAdvancedSettings() {
        XCTAssertEqual(effects(.claudeRecovery(.keychainAccess)), [.openSettings(.advanced)])
    }

    func testAnAlertOpensItsProvidersPage() {
        XCTAssertEqual(effects(.providerPage(serviceID: "claude")), [.navigate(.tile("claude"))], "from All its tile grows into the page")
        XCTAssertEqual(effects(.providerPage(serviceID: "claude"), on: codex), [.navigate(.logo("claude"))], "from a sibling's page")
        XCTAssertEqual(effects(.providerPage(serviceID: "claude"), on: .provider("claude")), [], "already there")
        XCTAssertEqual(effects(.providerPage(serviceID: "cursor")), [], "not on screen")
    }

    func testTheSleepingPetShowsKeepAwake() {
        XCTAssertEqual(effects(.keepAwakeCard), [.reveal(.keepAwake)])
        XCTAssertEqual(effects(.keepAwakeCard, on: codex), [.reveal(.keepAwake)], "keep awake is on every page")
    }

    func testNothingOnOpensProvidersSettings() {
        XCTAssertEqual(effects(.providersSettings, providers: []), [.openSettings(.providers)])
    }

    func testTheIdlePetIsPattedAndAnUnreadableSignInDoesNothing() {
        XCTAssertEqual(effects(.pat), [.pat])
        XCTAssertEqual(effects(.nothing), [])
        XCTAssertEqual(effects(.claudeRecovery(.noAction)), [])
    }

    func testOnlyAClickThatDoesSomethingMakesTheHabitatAButton() {
        XCTAssertFalse(PetActionRules.isActionable(.nothing))
        XCTAssertFalse(PetActionRules.isActionable(.claudeRecovery(.noAction)))
        let acting: [PetAction] = [
            .jump(sessionID: "claude:s1"), .needsYouList, .claudeRecovery(.signIn), .claudeRecovery(.install),
            .claudeRecovery(.keychainAccess), .providerPage(serviceID: "claude"), .keepAwakeCard, .agentsCard,
            .providersSettings, .pat,
        ]
        for action in acting {
            XCTAssertTrue(PetActionRules.isActionable(action), "\(action)")
        }
    }

    func testACardIsBroughtIntoViewOnlyOnceItIsOnScreenAndThePageHasSettled() {
        XCTAssertFalse(PetActionRules.revealReady(.agents, agentsCardShown: false, moving: false), "Grok's page: no agents card yet")
        XCTAssertFalse(PetActionRules.revealReady(.agents, agentsCardShown: true, moving: true), "Back to All still moving")
        XCTAssertTrue(PetActionRules.revealReady(.agents, agentsCardShown: true, moving: false))
        XCTAssertFalse(PetActionRules.revealReady(.keepAwake, agentsCardShown: false, moving: true))
        XCTAssertTrue(PetActionRules.revealReady(.keepAwake, agentsCardShown: false, moving: false), "keep awake is on every page")
    }

    /// Codex's re-review of the plan: a reveal belongs to the page it was asked for. Click the
    /// working pet on Grok's page (Back to All, then All's agents card), press ⌘1 before Back has
    /// settled: the destination is Claude's page now, whose own agents card must not be scrolled to.
    func testANewerNavigationDropsAPendingReveal() {
        XCTAssertTrue(PetActionRules.revealStillWanted(askedOn: .all, destination: .all), "Back to All still under way or settled")
        XCTAssertFalse(
            PetActionRules.revealStillWanted(askedOn: .all, destination: .provider("claude")),
            "⌘1 before Back settled: dropped"
        )
        XCTAssertTrue(
            PetActionRules.revealStillWanted(askedOn: .provider("grok"), destination: .provider("grok")),
            "keep awake asked on Grok's page, still there"
        )
        XCTAssertFalse(
            PetActionRules.revealStillWanted(askedOn: .provider("grok"), destination: .all),
            "any move away drops it"
        )
    }
}
