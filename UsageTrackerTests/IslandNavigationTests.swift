import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 (Navigation) and § 3.9 (`IslandNavigation`): every open
/// starts at All (an ear's at its subject), an interrupted close is not an open; a tile drills
/// into its page; in a page "‹ All", Esc, ⌘0 and a swipe go back and the logos switch
/// siblings; Esc at All closes; ⌘1–⌘5 are the providers on screen in display order, a
/// switched-off provider skipped; one provider's page is home; a page whose provider left falls
/// back. Owner 2026-10-30: nothing is kept between opens, and a ⌘ digit with no provider behind
/// it is swallowed silently.
final class IslandNavigationTests: XCTestCase {
    private let four = ["claude", "codex", "antigravity", "grok"]
    private let claude = IslandNavigation.Page.provider("claude")
    private let codex = IslandNavigation.Page.provider("codex")
    private let grok = IslandNavigation.Page.provider("grok")

    private func reduce(
        _ page: IslandNavigation.Page, _ input: IslandNavigation.Input, _ providers: [String]? = nil
    ) -> IslandNavigation.Outcome {
        IslandNavigation.reduce(page, input, providers: providers ?? four)
    }

    private func outcome(_ page: IslandNavigation.Page, _ action: IslandNavigation.Action) -> IslandNavigation.Outcome {
        IslandNavigation.Outcome(page: page, action: action)
    }

    // MARK: Opens

    func testEveryOpenStartsAtAllWhereverTheLastOneEnded() {
        XCTAssertEqual(reduce(codex, .open(subject: nil)), outcome(.all, .go(.cut)))
        XCTAssertEqual(reduce(.all, .open(subject: nil)), outcome(.all, .stay))
    }

    func testAnEarsOpenGoesToItsSubject() {
        XCTAssertEqual(reduce(.all, .open(subject: "claude")), outcome(claude, .go(.cut)))
        XCTAssertEqual(reduce(codex, .open(subject: "gemini")), outcome(.all, .go(.cut)), "a subject not on screen opens at All")
    }

    func testAFreshOpenOrAMoveToAnotherDisplayStartsAtHomeAndAnInterruptedCloseDoesNot() {
        XCTAssertTrue(IslandNavigation.opensAtHome(route: .fresh))
        XCTAssertTrue(IslandNavigation.opensAtHome(route: .moveAndOpen))
        XCTAssertFalse(IslandNavigation.opensAtHome(route: .reverse), "the content never left: it keeps its page")
    }

    func testOnceTheCloseHasEndedTheNextOpenStartsAtHome() {
        var transition = IslandTransition()
        transition.open(style: .spring, at: 0)
        transition.advance(to: 0)
        transition.advance(to: 0.125)
        transition.advance(to: 1)
        transition.close(style: .spring, at: 2)
        transition.advance(to: 2.05)
        XCTAssertEqual(transition.phase, .closing)
        XCTAssertFalse(
            IslandNavigation.opensAtHome(route: IslandTransition.route(phase: transition.phase, sameDisplay: true)),
            "an open while the close runs turns it around"
        )
        transition.advance(to: 4)
        XCTAssertEqual(transition.phase, .closed)
        XCTAssertTrue(
            IslandNavigation.opensAtHome(route: IslandTransition.route(phase: transition.phase, sameDisplay: true)),
            "the close has finished: the next open is a fresh one"
        )
    }

    func testWithOneProviderItsPageIsHome() {
        let one = ["grok"]
        XCTAssertEqual(reduce(.all, .open(subject: nil), one), outcome(grok, .go(.cut)))
        XCTAssertEqual(reduce(grok, .escape, one), outcome(grok, .close), "no All to go back to: Esc closes")
        XCTAssertEqual(reduce(grok, .back, one), outcome(grok, .pass))
        XCTAssertEqual(reduce(grok, .shortcut(0), one), outcome(grok, .stay), "⌘0 has no All to go to: swallowed, silent")
        XCTAssertEqual(reduce(grok, .shortcut(1), one), outcome(grok, .stay))
        XCTAssertEqual(reduce(grok, .logo("grok"), one), outcome(grok, .stay), "no logos to click")
    }

    // MARK: Drilling in and back

    func testATileAtAllDrillsIntoItsPage() {
        XCTAssertEqual(reduce(.all, .tile("codex")), outcome(codex, .go(.drillFromTile)))
    }

    func testATileThatCannotOpenChangesNothing() {
        XCTAssertEqual(reduce(.all, .tile("gemini")), outcome(.all, .stay), "not on screen")
        XCTAssertEqual(reduce(claude, .tile("codex")), outcome(claude, .stay), "no tiles in a page")
    }

    func testBackEscAndCommandZeroGoFromAPageToAll() {
        for input in [IslandNavigation.Input.back, .escape, .shortcut(0)] {
            XCTAssertEqual(reduce(codex, input), outcome(.all, .go(.back)), "\(input)")
        }
    }

    func testEscAtAllClosesTheIsland() {
        XCTAssertEqual(reduce(.all, .escape), outcome(.all, .close))
        XCTAssertEqual(reduce(.all, .escape, []), outcome(.all, .close), "loading or nothing on, too")
    }

    func testBackAtAllIsNotTheIslandsAndCommandZeroIsAlreadyThere() {
        XCTAssertEqual(reduce(.all, .back), outcome(.all, .pass))
        XCTAssertEqual(reduce(.all, .shortcut(0)), outcome(.all, .stay))
    }

    // MARK: Siblings and shortcuts

    func testALogoSwitchesToItsSiblingPage() {
        XCTAssertEqual(reduce(claude, .logo("codex")), outcome(codex, .go(.sibling)))
        XCTAssertEqual(reduce(claude, .logo("claude")), outcome(claude, .stay))
        XCTAssertEqual(reduce(.all, .logo("codex")), outcome(.all, .stay), "no logos at All")
    }

    func testCommandOneToFourAreTheProvidersInDisplayOrder() {
        XCTAssertEqual(reduce(.all, .shortcut(1)), outcome(claude, .go(.drillWithoutTile)))
        XCTAssertEqual(reduce(.all, .shortcut(4)), outcome(grok, .go(.drillWithoutTile)))
        XCTAssertEqual(reduce(claude, .shortcut(2)), outcome(codex, .go(.sibling)))
        XCTAssertEqual(reduce(codex, .shortcut(2)), outcome(codex, .stay))
    }

    func testCommandFiveReachesAFifthProvider() {
        let five = four + ["anthropic-admin"]
        XCTAssertEqual(reduce(.all, .shortcut(5), five), outcome(.provider("anthropic-admin"), .go(.drillWithoutTile)))
    }

    func testASwitchedOffProviderIsSkipped() {
        // Codex switched off in Settings › Providers: not on screen, so not counted.
        let three = ["claude", "antigravity", "grok"]
        XCTAssertEqual(reduce(.all, .shortcut(2), three), outcome(.provider("antigravity"), .go(.drillWithoutTile)))
        XCTAssertEqual(reduce(.all, .shortcut(3), three), outcome(grok, .go(.drillWithoutTile)))
        XCTAssertEqual(reduce(.all, .shortcut(4), three), outcome(.all, .stay), "no fourth provider: swallowed, silent")
    }

    func testADigitWithNoProviderBehindItMovesNothingAndIsSwallowed() {
        // Owner 2026-10-30: no beep. `.stay` is the island's: the key goes no further.
        XCTAssertEqual(reduce(.all, .shortcut(5)), outcome(.all, .stay))
        XCTAssertEqual(reduce(codex, .shortcut(9)), outcome(codex, .stay))
        let ten = (1...10).map { "p\($0)" }
        XCTAssertEqual(reduce(.all, .shortcut(10), ten), outcome(.all, .stay), "only 1–9 name a provider")
        XCTAssertEqual(reduce(.all, .shortcut(-1)), outcome(.all, .stay))
    }

    // MARK: Providers changing

    func testAPageWhoseProviderLeftFallsBackToAll() {
        XCTAssertEqual(reduce(codex, .providersChanged, ["claude", "grok"]), outcome(.all, .go(.cut)))
        XCTAssertEqual(reduce(codex, .providersChanged), outcome(codex, .stay))
        XCTAssertEqual(reduce(.all, .providersChanged), outcome(.all, .stay))
    }

    func testWhenOneProviderIsLeftItsPageBecomesHome() {
        XCTAssertEqual(reduce(.all, .providersChanged, ["grok"]), outcome(grok, .go(.cut)))
        XCTAssertEqual(reduce(codex, .providersChanged, ["grok"]), outcome(grok, .go(.cut)))
    }

    func testWithNothingOnScreenEverythingStaysAtAll() {
        XCTAssertEqual(reduce(.all, .open(subject: nil), []), outcome(.all, .stay))
        XCTAssertEqual(reduce(.all, .tile("claude"), []), outcome(.all, .stay))
        XCTAssertEqual(reduce(.all, .shortcut(0), []), outcome(.all, .stay))
        XCTAssertEqual(reduce(.all, .shortcut(1), []), outcome(.all, .stay))
        XCTAssertEqual(reduce(claude, .providersChanged, []), outcome(.all, .go(.cut)))
    }

    func testAPageWithSiblingsIsDrilledInAndTheOnlyProvidersPageIsNot() {
        XCTAssertTrue(IslandNavigation.isDrilledIn(codex, providers: four))
        XCTAssertFalse(IslandNavigation.isDrilledIn(.all, providers: four))
        XCTAssertFalse(IslandNavigation.isDrilledIn(grok, providers: ["grok"]))
        XCTAssertFalse(IslandNavigation.isDrilledIn(.provider("gemini"), providers: four), "not on screen")
    }
}
