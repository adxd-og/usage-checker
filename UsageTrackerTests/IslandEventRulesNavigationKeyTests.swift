import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 and § 3.8: the keys the island's navigation answers —
/// Esc, and ⌘ alone with a digit of the top row or the keypad — while the island is the key
/// window. A digit typed into a field, another shortcut and another window's keys are not its.
/// A navigation key is never handed on while the island is key, in any phase: applied while
/// open, swallowed while it closes, so it never beeps (owner 2026-10-30; Codex review finding 2).
final class IslandEventRulesNavigationKeyTests: XCTestCase {
    private func key(
        _ code: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false,
        control: Bool = false, islandIsKey: Bool = true
    ) -> IslandEventRules.NavigationKey? {
        IslandEventRules.navigationKey(
            keyCode: code, command: command, shift: shift, option: option, control: control,
            keyWindowIsIsland: islandIsKey
        )
    }

    func testEscIsTheIslandsWhileItIsTheKeyWindow() {
        XCTAssertEqual(key(53), .escape)
        XCTAssertEqual(key(53, command: true), .escape)
        XCTAssertNil(key(53, islandIsKey: false), "a key help popover takes its own Esc")
    }

    func testCommandAndADigitOfTheTopRowIsThatDigit() {
        let row: [(UInt16, Int)] = [(29, 0), (18, 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7), (28, 8), (25, 9)]
        for (code, digit) in row {
            XCTAssertEqual(key(code, command: true), .digit(digit), "\(code)")
        }
    }

    func testTheKeypadsDigitsCountToo() {
        let pad: [(UInt16, Int)] = [(82, 0), (83, 1), (84, 2), (85, 3), (86, 4), (87, 5), (88, 6), (89, 7), (91, 8), (92, 9)]
        for (code, digit) in pad {
            XCTAssertEqual(key(code, command: true), .digit(digit), "\(code)")
        }
    }

    func testADigitWithoutCommandIsTypingNotNavigation() {
        XCTAssertNil(key(18), "1 into keep awake's hours field")
        XCTAssertNil(key(83))
    }

    func testCommandWithAnotherModifierIsAnotherShortcut() {
        XCTAssertNil(key(18, command: true, shift: true))
        XCTAssertNil(key(18, command: true, option: true))
        XCTAssertNil(key(18, command: true, control: true))
    }

    func testTheFootersAndTheFieldsCommandKeysAreNotNavigation() {
        // ⌘A, ⌘D, ⌘Q, ⌘R, ⌘,
        for code: UInt16 in [0, 2, 12, 15, 43] {
            XCTAssertNil(key(code, command: true), "\(code)")
        }
    }

    func testAnotherWindowsKeysAreItsOwn() {
        XCTAssertNil(key(18, command: true, islandIsKey: false))
    }

    func testEachKeyTellsNavigationItsInput() {
        XCTAssertEqual(IslandEventRules.NavigationKey.escape.input, .escape)
        XCTAssertEqual(IslandEventRules.NavigationKey.digit(3).input, .shortcut(3))
    }

    func testWhileTheIslandIsOpenANavigationKeyNavigates() {
        XCTAssertEqual(IslandEventRules.keyRoute(.escape, isOpen: true, closingSwallows: false), .navigate(.escape))
        XCTAssertEqual(
            IslandEventRules.keyRoute(.digit(7), isOpen: true, closingSwallows: false), .navigate(.shortcut(7)),
            "bound or not: the reducer says, and the key stops here"
        )
    }

    func testWhileTheIslandClosesCommandOneAndCommandEscAreSwallowedNotBeeped() {
        var transition = IslandTransition()
        transition.open(style: .spring, at: 0)
        transition.advance(to: 0)
        transition.advance(to: 0.125)
        transition.advance(to: 1)
        transition.close(style: .spring, at: 2)
        XCTAssertEqual(transition.phase, .closing)
        // P2's rule lets every ⌘ key through a close (so ⌘Q works) …
        let commandPasses = transition.swallowsKey(inIsland: true, command: true)
        XCTAssertFalse(commandPasses)
        // … but the island is still key, so a navigation key must stop here.
        XCTAssertEqual(
            IslandEventRules.keyRoute(key(18, command: true), isOpen: transition.isOpen, closingSwallows: commandPasses),
            .swallow, "⌘1"
        )
        XCTAssertEqual(
            IslandEventRules.keyRoute(key(53, command: true), isOpen: transition.isOpen, closingSwallows: commandPasses),
            .swallow, "⌘Esc"
        )
        XCTAssertEqual(
            IslandEventRules.keyRoute(key(12, command: true), isOpen: transition.isOpen, closingSwallows: commandPasses),
            .pass, "⌘Q goes on"
        )
    }

    func testAnyOtherKeyFollowsTheClosingRule() {
        XCTAssertEqual(
            IslandEventRules.keyRoute(nil, isOpen: false, closingSwallows: true), .swallow,
            "a plain key aimed at a closing island"
        )
        XCTAssertEqual(IslandEventRules.keyRoute(nil, isOpen: true, closingSwallows: false), .pass, "⌘C in a field")
        XCTAssertEqual(IslandEventRules.keyRoute(nil, isOpen: false, closingSwallows: false), .pass, "⌘Q while it closes")
    }
}
