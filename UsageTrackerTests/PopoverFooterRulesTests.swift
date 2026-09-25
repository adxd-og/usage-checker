import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · All": "refresh button removed from
/// the header (⌘R)". `Main.dc.html`'s footer: Dashboard, floating window and Settings
/// on glass, then Quit.
final class PopoverFooterRulesTests: XCTestCase {
    func testRefreshIsAKeyboardShortcutNotAButton() {
        XCTAssertFalse(PopoverFooterRules.buttons.contains(.refresh))
        XCTAssertEqual(PopoverFooterRules.keyboardOnly, [.refresh])
        XCTAssertEqual(PopoverFooterRules.shortcutKey(.refresh), "r")
    }

    func testTheFooterButtonsAreDashboardFloatingWindowAndSettings() {
        XCTAssertEqual(PopoverFooterRules.buttons, [.dashboard, .floatingWindow, .settings])
        XCTAssertEqual(PopoverFooterRules.spacing, 8)
    }

    /// Past the spacer there is Quit and nothing else: the version and the GitHub link
    /// live in Settings → General, as the mockup's footer has neither.
    func testTheFooterEndsWithQuitAndCarriesNoVersion() {
        XCTAssertEqual(PopoverFooterRules.trailing, [.quit])
    }

    func testTheOtherShortcutsAreUnchanged() {
        XCTAssertEqual(PopoverFooterRules.shortcutKey(.dashboard), "d")
        XCTAssertEqual(PopoverFooterRules.shortcutKey(.settings), ",")
        XCTAssertEqual(PopoverFooterRules.shortcutKey(.quit), "q")
        XCTAssertNil(PopoverFooterRules.shortcutKey(.floatingWindow))
    }

    func testTheButtonsWearTheMockupsSymbols() {
        XCTAssertEqual(PopoverFooterRules.symbol(.dashboard), "sidebar.left")
        XCTAssertEqual(PopoverFooterRules.symbol(.floatingWindow, floatingWindowOpen: false), "pip.enter")
        XCTAssertEqual(PopoverFooterRules.symbol(.floatingWindow, floatingWindowOpen: true), "pip.exit")
        XCTAssertEqual(PopoverFooterRules.symbol(.settings), "slider.horizontal.3")
    }

    func testEveryActionHasATitleVoiceOverCanRead() {
        XCTAssertEqual(PopoverAction.allCases.map(PopoverFooterRules.title),
                       ["Dashboard", "Floating window", "Settings", "Refresh now", "Quit"])
    }

    func testTooltipsNameTheShortcut() {
        XCTAssertEqual(PopoverFooterRules.help(.dashboard), "Open dashboard (⌘D)")
        XCTAssertEqual(PopoverFooterRules.help(.settings), "Settings (⌘,)")
        XCTAssertEqual(PopoverFooterRules.help(.refresh), "Refresh now (⌘R)")
        XCTAssertEqual(PopoverFooterRules.help(.quit), "Quit Omelette (⌘Q)")
    }

    func testTheFloatingWindowsTooltipSaysWhatTheClickWillDo() {
        XCTAssertEqual(PopoverFooterRules.help(.floatingWindow, floatingWindowOpen: false), "Show floating mini window")
        XCTAssertEqual(PopoverFooterRules.help(.floatingWindow, floatingWindowOpen: true), "Close floating window")
    }
}
