import XCTest
@testable import Omelette

/// Verifier for notch-island spec 2026-10-29 § 3.5 "Mood rule" (the Click column), § 3.8 and D11:
/// every action on every page the island can show, the page-less cases (one provider's home, a
/// page whose provider has gone), the button trait against what the click does, and the full
/// truth tables of the two reveal rules.
final class PetActionRulesVerificationTests: XCTestCase {
    private let four = ["claude", "codex", "antigravity", "grok"]

    private var allActions: [PetAction] {
        [
            .jump(sessionID: "claude:s1"), .needsYouList, .claudeRecovery(.signIn), .claudeRecovery(.install),
            .claudeRecovery(.keychainAccess), .claudeRecovery(.noAction), .providerPage(serviceID: "claude"),
            .keepAwakeCard, .providersSettings, .pat, .nothing,
        ]
    }

    private func pages(for providers: [String]) -> [IslandNavigation.Page] {
        [.all] + providers.map { .provider($0) }
    }

    /// The button trait and the click agree: a habitat that says "button" does something from All.
    func testTheHabitatIsAButtonExactlyWhenItsClickDoesSomethingFromAll() {
        for action in allActions {
            let effects = PetActionRules.effects(of: action, page: .all, providers: four)
            XCTAssertEqual(PetActionRules.isActionable(action), !effects.isEmpty, "\(action): \(effects)")
        }
    }

    /// Back is only asked of a page that has a Back: never from All, never from the only provider's home.
    func testBackIsNeverAskedWhereThereIsNothingToGoBackTo() {
        let sets: [[String]] = [four, ["claude", "codex"], ["grok"], ["claude"], []]
        for providers in sets {
            for page in pages(for: providers) + [.provider("gone")] {
                for action in allActions {
                    let effects = PetActionRules.effects(of: action, page: page, providers: providers)
                    if effects.contains(.navigate(.back)) {
                        XCTAssertTrue(
                            IslandNavigation.isDrilledIn(page, providers: providers),
                            "\(action) on \(page) with \(providers)"
                        )
                        XCTAssertEqual(effects, [.navigate(.back), .reveal(.agents)], "Back, then the card, in that order")
                    }
                }
            }
        }
    }

    func testTheAgentsCardIsAlwaysAskedLastAndOnlyByTheNeedsYouList() {
        for providers in [four, ["claude", "codex"], ["grok"]] {
            for page in pages(for: providers) {
                for action in allActions {
                    let effects = PetActionRules.effects(of: action, page: page, providers: providers)
                    let asks = effects.contains(.reveal(.agents))
                    switch action {
                    case .needsYouList:
                        XCTAssertTrue(asks, "\(action) on \(page)")
                        XCTAssertEqual(effects.last, .reveal(.agents), "\(action) on \(page)")
                    default:
                        XCTAssertFalse(asks, "\(action) on \(page)")
                    }
                }
            }
        }
    }

    func testTheOnlyProvidersHomeHasNoBackAndNoSelfNavigation() {
        for id in ["claude", "grok", "antigravity"] {
            let home = IslandNavigation.Page.provider(id)
            XCTAssertEqual(PetActionRules.effects(of: .providerPage(serviceID: id), page: home, providers: [id]), [.pat])
            XCTAssertEqual(PetActionRules.effects(of: .needsYouList, page: home, providers: [id]), [.reveal(.agents)])
            XCTAssertEqual(PetActionRules.effects(of: .keepAwakeCard, page: home, providers: [id]), [.reveal(.keepAwake)])
        }
    }

    func testAnAlertForAProviderThatIsNotOnScreenGoesNowhereFromEveryPage() {
        for page in pages(for: four) {
            XCTAssertEqual(PetActionRules.effects(of: .providerPage(serviceID: "cursor"), page: page, providers: four), [])
        }
    }

    func testAnAlertOpensItsPageFromEverySiblingByLogoAndFromAllByTile() {
        for id in four {
            for page in pages(for: four) {
                let effects = PetActionRules.effects(of: .providerPage(serviceID: id), page: page, providers: four)
                switch page {
                case .all: XCTAssertEqual(effects, [.navigate(.tile(id))])
                case .provider(id): XCTAssertEqual(effects, [.pat])
                case .provider: XCTAssertEqual(effects, [.navigate(.logo(id))])
                }
            }
        }
    }

    func testTheRecoveryActionsLeaveTheIslandBeforeTheirAppAndSettingsOpenOnTheirTab() {
        for page in pages(for: four) {
            XCTAssertEqual(PetActionRules.effects(of: .claudeRecovery(.signIn), page: page, providers: four), [.closeIsland, .signIn])
            XCTAssertEqual(PetActionRules.effects(of: .claudeRecovery(.install), page: page, providers: four), [.closeIsland, .openInstallPage])
            XCTAssertEqual(PetActionRules.effects(of: .claudeRecovery(.keychainAccess), page: page, providers: four), [.openSettings(.advanced)])
            XCTAssertEqual(PetActionRules.effects(of: .providersSettings, page: page, providers: four), [.openSettings(.providers)])
            XCTAssertEqual(PetActionRules.effects(of: .pat, page: page, providers: four), [.pat])
        }
    }

    func testTheRevealRulesFullTruthTables() {
        for shown in [false, true] {
            for moving in [false, true] {
                XCTAssertEqual(
                    PetActionRules.revealReady(.agents, agentsCardShown: shown, moving: moving), shown && !moving,
                    "agents card shown \(shown), moving \(moving)"
                )
                XCTAssertEqual(
                    PetActionRules.revealReady(.keepAwake, agentsCardShown: shown, moving: moving), !moving,
                    "keep awake with the agents card shown \(shown), moving \(moving)"
                )
            }
        }
        let pagesToTry: [IslandNavigation.Page] = [.all, .provider("claude"), .provider("grok")]
        for asked in pagesToTry {
            for destination in pagesToTry {
                XCTAssertEqual(PetActionRules.revealStillWanted(askedOn: asked, destination: destination), asked == destination)
            }
        }
    }
}
