import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.4 (Navigation, with the owner's 2026-10-30
/// P3b note) and § 3.9 (`IslandNavigation`): the reducer swept over every input × page × provider
/// count (0, 1, 2, 4, 9, 10 — the last two for the digits past the ninth), with the properties
/// the spec states as laws rather than examples; ⌘0–⌘9 including the keypad; a navigation key in
/// every phase of the island's own clock; providers removed while on their page, through the
/// model the controller drives; an open's home by route.
@MainActor
final class IslandNavigationVerificationTests: XCTestCase {
    private typealias Nav = IslandNavigation

    private let names = ["claude", "codex", "antigravity", "grok", "p5", "p6", "p7", "p8", "p9", "p10"]
    private func providers(_ count: Int) -> [String] { Array(names.prefix(count)) }

    /// Every page a count of providers can be on, and one whose provider is not on screen.
    private func pages(_ providers: [String]) -> [Nav.Page] {
        [.all] + providers.map { Nav.Page.provider($0) } + [.provider("gone")]
    }

    private func inputs(_ providers: [String]) -> [Nav.Input] {
        var all: [Nav.Input] = [.open(subject: nil), .open(subject: "gone"), .back, .escape, .providersChanged]
        for id in providers + ["gone"] {
            all += [.open(subject: id), .tile(id), .logo(id)]
        }
        all += (-2...12).map { .shortcut($0) }
        return all
    }

    // MARK: The laws

    func testEveryInputOnEveryPageOverEveryProviderCountObeysTheLaws() {
        for count in [0, 1, 2, 3, 4, 5, 9, 10] {
            let ids = providers(count)
            for page in pages(ids) {
                let settled = Nav.resolved(page, providers: ids) == page
                for input in inputs(ids) {
                    let tag = "count \(count), \(page), \(input)"
                    let out = Nav.reduce(page, input, providers: ids)

                    switch out.action {
                    case .go:
                        XCTAssertNotEqual(out.page, page, "a move changes the page: \(tag)")
                    case .stay, .pass, .close:
                        XCTAssertEqual(out.page, page, "no move leaves the page alone: \(tag)")
                    }
                    if case .close = out.action {
                        XCTAssertEqual(input, .escape, "only Esc closes: \(tag)")
                        XCTAssertFalse(Nav.isDrilledIn(page, providers: ids), tag)
                    }
                    if case .pass = out.action {
                        XCTAssertEqual(input, .back, "only Back is ever handed on: \(tag)")
                        XCTAssertFalse(Nav.isDrilledIn(page, providers: ids), tag)
                    }
                    if settled {
                        XCTAssertEqual(
                            Nav.resolved(out.page, providers: ids), out.page,
                            "a settled page never reduces to an unsettled one: \(tag)"
                        )
                    }
                    // A key never passes: it is the island's, swallowed if nothing moves.
                    switch input {
                    case .escape, .shortcut:
                        if case .pass = out.action { XCTFail("a key must never pass: \(tag)") }
                    default: break
                    }
                    // A ⌘ digit moves only between pages, never closes.
                    if case .shortcut = input, case .close = out.action { XCTFail("a digit closes: \(tag)") }
                }
            }
        }
    }

    func testDigitsMapToTheProvidersInDisplayOrderAndNothingElse() {
        for count in [0, 1, 2, 4, 9, 10] {
            let ids = providers(count)
            for from in pages(ids) {
                for digit in -2...12 {
                    let out = Nav.reduce(from, .shortcut(digit), providers: ids)
                    let tag = "count \(count), \(from), ⌘\(digit)"
                    if digit >= 1, digit <= min(9, count) {
                        XCTAssertEqual(out.page, .provider(ids[digit - 1]), tag)
                        if from == out.page {
                            XCTAssertEqual(out.action, .stay, tag)
                        } else {
                            XCTAssertEqual(out.action, .go(from == .all ? .drillWithoutTile : .sibling), tag)
                        }
                    } else if digit == 0, count > 1, Nav.isDrilledIn(from, providers: ids) {
                        XCTAssertEqual(out, Nav.Outcome(page: .all, action: .go(.back)), tag)
                    } else {
                        XCTAssertEqual(out, Nav.Outcome(page: from, action: .stay), "swallowed silently: \(tag)")
                    }
                }
            }
        }
    }

    func testATileDrillsOnlyFromAllWithSiblingsAndFromItsOwnProvider() {
        for count in [0, 1, 2, 4] {
            let ids = providers(count)
            for page in pages(ids) {
                for id in ids + ["gone"] {
                    let out = Nav.reduce(page, .tile(id), providers: ids)
                    if page == .all, count > 1, ids.contains(id) {
                        XCTAssertEqual(out, Nav.Outcome(page: .provider(id), action: .go(.drillFromTile)))
                    } else {
                        XCTAssertEqual(out, Nav.Outcome(page: page, action: .stay), "count \(count), \(page), \(id)")
                    }
                }
            }
        }
    }

    func testALogoSwitchesSiblingsOnlyFromAPageWithSiblings() {
        for count in [0, 1, 2, 4] {
            let ids = providers(count)
            for page in pages(ids) {
                for id in ids + ["gone"] {
                    let out = Nav.reduce(page, .logo(id), providers: ids)
                    let tag = "count \(count), \(page), \(id)"
                    if Nav.isDrilledIn(page, providers: ids), ids.contains(id) {
                        XCTAssertEqual(out.page, .provider(id), tag)
                        XCTAssertEqual(out.action, page == .provider(id) ? .stay : .go(.sibling), tag)
                    } else {
                        XCTAssertEqual(out, Nav.Outcome(page: page, action: .stay), "a logo off its page is ignored: \(tag)")
                    }
                }
            }
        }
    }

    func testALogoClickedWhilePageIsGoingBackToAllIsIgnored() {
        // The logos are still on screen for the first half of a Back; the reducer is already at All.
        let model = IslandNavigationModel()
        let four = providers(4)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0)
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 1)
        model.advance(to: 1.2)
        model.apply(.back, providers: four, reduceMotion: false, at: 1.2)
        let going = model.frame
        XCTAssertEqual(going.to, .all)
        XCTAssertEqual(model.apply(.logo("grok"), providers: four, reduceMotion: false, at: 1.21), .stay)
        XCTAssertEqual(model.frame.to, .all, "still going back")
        XCTAssertEqual(model.frame.from, going.from)
        model.advance(to: 5)
        XCTAssertEqual(model.frame, .resting(at: .all))
    }

    func testBackAndEscAgreeInAPageAndDifferAtAll() {
        for count in [0, 1, 2, 4] {
            let ids = providers(count)
            for page in pages(ids) {
                let back = Nav.reduce(page, .back, providers: ids)
                let esc = Nav.reduce(page, .escape, providers: ids)
                if Nav.isDrilledIn(page, providers: ids) {
                    XCTAssertEqual(back, esc, "count \(count), \(page)")
                    XCTAssertEqual(back, Nav.Outcome(page: .all, action: .go(.back)))
                } else {
                    XCTAssertEqual(back.action, .pass, "count \(count), \(page)")
                    XCTAssertEqual(esc.action, .close, "count \(count), \(page)")
                }
            }
        }
    }

    func testAProvidersChangeSettlesOnceAndSettlesToTheRightPage() {
        for count in [0, 1, 2, 4] {
            let ids = providers(count)
            for page in pages(ids) {
                let out = Nav.reduce(page, .providersChanged, providers: ids)
                XCTAssertEqual(out.page, Nav.resolved(page, providers: ids))
                XCTAssertEqual(out.action, out.page == page ? .stay : .go(.cut), "count \(count), \(page)")
                let again = Nav.reduce(out.page, .providersChanged, providers: ids)
                XCTAssertEqual(again, Nav.Outcome(page: out.page, action: .stay), "idempotent: count \(count), \(page)")
                if count == 1 { XCTAssertEqual(out.page, .provider(ids[0]), "the only provider's page is home") }
                if count == 0 { XCTAssertEqual(out.page, .all) }
                if count > 1, case .provider(let id) = page, !ids.contains(id) {
                    XCTAssertEqual(out, Nav.Outcome(page: .all, action: .go(.cut)))
                }
            }
        }
    }

    func testWithOneProviderNoInputEverLeavesItsPage() {
        let ids = providers(1)
        let home = Nav.Page.provider(ids[0])
        for input in inputs(ids) {
            let out = Nav.reduce(home, input, providers: ids)
            XCTAssertEqual(out.page, home, "\(input)")
            XCTAssertNotEqual(out.action, .go(.back), "\(input)")
        }
        XCTAssertEqual(Nav.reduce(home, .escape, providers: ids).action, .close)
        XCTAssertEqual(Nav.reduce(home, .shortcut(0), providers: ids).action, .stay, "no All to go to: swallowed")
    }

    func testAnOpenGoesToItsSubjectOnlyWhileItIsOnScreen() {
        for count in [0, 1, 2, 4] {
            let ids = providers(count)
            for page in pages(ids) {
                for subject in ids + ["gone"] {
                    let out = Nav.reduce(page, .open(subject: subject), providers: ids)
                    let target: Nav.Page = ids.contains(subject) ? .provider(subject) : Nav.home(providers: ids)
                    XCTAssertEqual(out.page, target, "count \(count), \(page), \(subject)")
                    XCTAssertEqual(out.action, target == page ? .stay : .go(.cut))
                }
            }
        }
    }

    func testOnlyAnInterruptedCloseKeepsItsPage() {
        XCTAssertTrue(Nav.opensAtHome(route: .fresh))
        XCTAssertTrue(Nav.opensAtHome(route: .moveAndOpen))
        XCTAssertFalse(Nav.opensAtHome(route: .reverse))
        // The route as the clock produces it, from every phase and either display.
        for phase in [IslandTransition.Phase.closed, .opening, .open, .closing] {
            for same in [true, false] {
                let route = IslandTransition.route(phase: phase, sameDisplay: same)
                XCTAssertEqual(
                    Nav.opensAtHome(route: route), !(phase == .closing && same),
                    "\(phase), same display \(same)"
                )
            }
        }
    }

    // MARK: Keys in every phase of the island's clock

    private func transition(in phase: IslandTransition.Phase) -> IslandTransition {
        var transition = IslandTransition()
        switch phase {
        case .closed: break
        case .opening: transition.open(style: .spring, at: 0)
        case .open:
            transition.open(style: .spring, at: 0)
            transition.advance(to: 0)
            transition.advance(to: 0.125)
            transition.advance(to: 1)
        case .closing:
            transition.open(style: .spring, at: 0)
            transition.advance(to: 0)
            transition.advance(to: 0.125)
            transition.advance(to: 1)
            transition.close(style: .spring, at: 2)
        }
        XCTAssertEqual(transition.phase, phase)
        return transition
    }

    private func route(
        _ code: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false,
        phase: IslandTransition.Phase, islandIsKey: Bool = true, eventInIsland: Bool = true
    ) -> IslandEventRules.KeyRoute {
        let clock = transition(in: phase)
        let key = IslandEventRules.navigationKey(
            keyCode: code, command: command, shift: shift, option: option, control: control,
            keyWindowIsIsland: islandIsKey
        )
        return IslandEventRules.keyRoute(
            key, isOpen: clock.isOpen,
            closingSwallows: clock.swallowsKey(inIsland: eventInIsland, command: command)
        )
    }

    func testNavigationKeysAreTheIslandsInEveryPhaseWhileItIsKey() {
        for phase in [IslandTransition.Phase.opening, .open] {
            XCTAssertEqual(route(53, phase: phase), .navigate(.escape), "Esc, \(phase)")
            XCTAssertEqual(route(18, command: true, phase: phase), .navigate(.shortcut(1)), "⌘1, \(phase)")
            XCTAssertEqual(route(29, command: true, phase: phase), .navigate(.shortcut(0)), "⌘0, \(phase)")
            XCTAssertEqual(route(92, command: true, phase: phase), .navigate(.shortcut(9)), "keypad ⌘9, \(phase)")
        }
        // Closing: swallowed, never passed on to beep.
        XCTAssertEqual(route(53, phase: .closing), .swallow)
        XCTAssertEqual(route(53, command: true, phase: .closing), .swallow)
        XCTAssertEqual(route(18, command: true, phase: .closing), .swallow)
        XCTAssertEqual(route(83, command: true, phase: .closing), .swallow, "keypad ⌘1")
        XCTAssertEqual(route(29, command: true, phase: .closing), .swallow)
        // Closed with the island still key (a stale key window): the island's, swallowed.
        XCTAssertEqual(route(18, command: true, phase: .closed), .swallow)
        XCTAssertEqual(route(53, phase: .closed), .swallow)
    }

    func testOtherShortcutsAndKeysKeepTheirOldRules() {
        for phase in [IslandTransition.Phase.opening, .open, .closed] {
            XCTAssertEqual(route(12, command: true, phase: phase), .pass, "⌘Q, \(phase)")
            XCTAssertEqual(route(0, phase: phase), .pass, "a letter, \(phase)")
            XCTAssertEqual(route(18, phase: phase), .pass, "a typed 1, \(phase)")
            XCTAssertEqual(route(18, command: true, shift: true, phase: phase), .pass, "⌘⇧1, \(phase)")
            XCTAssertEqual(route(18, command: true, option: true, phase: phase), .pass, "⌘⌥1, \(phase)")
            XCTAssertEqual(route(18, command: true, control: true, phase: phase), .pass, "⌘⌃1, \(phase)")
        }
        XCTAssertEqual(route(12, command: true, phase: .closing), .pass, "⌘Q still quits while it closes")
        XCTAssertEqual(route(8, command: true, phase: .closing), .pass, "⌘C goes on")
        XCTAssertEqual(route(18, command: true, shift: true, phase: .closing), .pass, "another shortcut")
        XCTAssertEqual(route(0, phase: .closing), .swallow, "a plain key at a closing island")
        XCTAssertEqual(route(18, phase: .closing), .swallow)
    }

    func testAnotherWindowsKeysAreItsOwnInEveryPhase() {
        for phase in [IslandTransition.Phase.closed, .opening, .open, .closing] {
            let command = phase == .closing
            XCTAssertEqual(
                route(53, phase: phase, islandIsKey: false, eventInIsland: false), .pass, "Esc in a help popover, \(phase)"
            )
            XCTAssertEqual(
                route(18, command: true, phase: phase, islandIsKey: false, eventInIsland: false), .pass,
                "⌘1 in Settings, \(phase) \(command)"
            )
        }
    }

    func testEveryKeyCodeOfADigitIsExactlyOneDigit() {
        var seen: [Int: Int] = [:]
        for (code, digit) in IslandEventRules.digitKeyCodes {
            seen[digit, default: 0] += 1
            XCTAssertEqual(
                IslandEventRules.navigationKey(
                    keyCode: code, command: true, shift: false, option: false, control: false, keyWindowIsIsland: true
                ),
                .digit(digit)
            )
        }
        XCTAssertEqual(Set(seen.keys), Set(0...9))
        XCTAssertTrue(seen.values.allSatisfy { $0 == 2 }, "one top-row code and one keypad code per digit")
    }

    // MARK: Providers removed while on their page, through the model

    func testRemovingTheProviderOfTheCurrentPageCutsBackToAll() {
        let model = IslandNavigationModel()
        let four = providers(4)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0)
        model.apply(.tile("antigravity"), providers: four, reduceMotion: false, at: 1)
        XCTAssertTrue(model.isMoving)
        // It goes away mid-drill.
        let three = ["claude", "codex", "grok"]
        let action = model.apply(.providersChanged, providers: three, reduceMotion: false, at: 1.05)
        XCTAssertEqual(action, .go(.cut))
        XCTAssertEqual(model.page, .all)
        XCTAssertFalse(model.isMoving, "the page is gone: no move to a page that is not there")
        XCTAssertEqual(model.frame, .resting(at: .all))
    }

    func testRemovingAnotherProviderLeavesThePageAndItsMoveAlone() {
        let model = IslandNavigationModel()
        let four = providers(4)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0)
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 1)
        let before = model.frame
        let action = model.apply(.providersChanged, providers: ["claude", "codex", "antigravity"], reduceMotion: false, at: 1)
        XCTAssertEqual(action, .stay)
        XCTAssertEqual(model.page, .provider("codex"))
        XCTAssertEqual(model.frame, before)
        XCTAssertTrue(model.isMoving)
    }

    func testDownToOneProviderItsPageIsHomeAtOnce() {
        let model = IslandNavigationModel()
        let four = providers(4)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0)
        model.apply(.tile("grok"), providers: four, reduceMotion: false, at: 1)
        model.advance(to: 5)
        XCTAssertEqual(model.page, .provider("grok"))
        // Down to Grok alone: its page stays, and is home (no All to go back to).
        XCTAssertEqual(model.apply(.providersChanged, providers: ["grok"], reduceMotion: false, at: 5), .stay)
        XCTAssertEqual(model.page, .provider("grok"))
        XCTAssertEqual(model.apply(.escape, providers: ["grok"], reduceMotion: false, at: 5), .close)
        // Down to Claude alone while on Grok's page: Claude's is home.
        XCTAssertEqual(
            model.apply(.providersChanged, providers: ["claude"], reduceMotion: false, at: 6), .go(.cut)
        )
        XCTAssertEqual(model.page, .provider("claude"))
        XCTAssertFalse(model.isMoving)
        // Everything switched off.
        model.apply(.providersChanged, providers: [], reduceMotion: false, at: 7)
        XCTAssertEqual(model.page, .all)
        XCTAssertEqual(model.apply(.shortcut(1), providers: [], reduceMotion: false, at: 7), .stay)
    }

    func testDigitsCountPastASwitchedOffProvider() {
        let model = IslandNavigationModel()
        let all4 = providers(4)
        model.apply(.open(subject: nil), providers: all4, reduceMotion: false, at: 0)
        let withoutCodex = ["claude", "antigravity", "grok"]
        XCTAssertEqual(model.apply(.shortcut(2), providers: withoutCodex, reduceMotion: false, at: 1), .go(.drillWithoutTile))
        XCTAssertEqual(model.page, .provider("antigravity"), "⌘2 is the second provider ON SCREEN")
        XCTAssertEqual(model.apply(.shortcut(4), providers: withoutCodex, reduceMotion: false, at: 1), .stay)
        XCTAssertEqual(model.page, .provider("antigravity"), "⌘4 has nothing behind it: swallowed")
    }

    func testAnEscThroughTheModelMidDrillTurnsTheMoveAround() {
        let model = IslandNavigationModel()
        let four = providers(4)
        model.apply(.open(subject: nil), providers: four, reduceMotion: false, at: 0)
        model.apply(.tile("codex"), providers: four, reduceMotion: false, at: 1)
        let mid = model.frame
        XCTAssertEqual(model.apply(.escape, providers: four, reduceMotion: false, at: 1.1), .go(.back))
        XCTAssertEqual(model.frame.to, .all)
        XCTAssertEqual(model.frame.from, .provider("codex"))
        XCTAssertEqual(mid.motion, model.frame.motion, "the reversal keeps its look")
        // A second Esc while it goes back is Esc at All: it closes.
        XCTAssertEqual(model.apply(.escape, providers: four, reduceMotion: false, at: 1.15), .close)
    }
}
