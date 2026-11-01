import AppKit
import XCTest
@testable import Omelette

/// While one of the app's real windows is up it is in Cmd+Tab, with a Dock icon and its menu
/// bar; when the last one goes it leaves them again (`ActivationPolicyRules`). Each window
/// kind below is described by what AppKit reports for it.
final class ActivationPolicyRulesTests: XCTestCase {
    private typealias Facts = ActivationPolicyRules.WindowFacts

    /// The Dashboard, Settings or the tour on screen: a titled window, hidden title bar or not.
    private static let realWindow = Facts(
        isPanel: false, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: true, isVisible: true, isMiniaturized: false
    )
    /// A SwiftUI `Window` after its close: hidden, not destroyed. AppKit reports it can't become main.
    private static let closedWindow = Facts(
        isPanel: false, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: false, isMiniaturized: false
    )
    /// In the Dock: not visible, and AppKit says it can't become main while it is there.
    private static let miniaturizedWindow = Facts(
        isPanel: false, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: false, isMiniaturized: true
    )
    /// The island and the resting notch panel, ears included: borderless panels.
    private static let overlayPanel = Facts(
        isPanel: true, isTitled: false, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )
    /// The floating mini window: a panel with a title bar.
    private static let floatingPanel = Facts(
        isPanel: true, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )
    /// The status item's window, a popover's and SwiftUI's helpers: borderless windows.
    private static let borderlessHelper = Facts(
        isPanel: false, isTitled: false, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )

    private func policy(
        _ windows: [Facts], appIsHidden: Bool = false, current: NSApplication.ActivationPolicy = .accessory
    ) -> NSApplication.ActivationPolicy {
        ActivationPolicyRules.policy(windows: windows, appIsHidden: appIsHidden, current: current)
    }

    func testWithNoWindowsTheAppStaysOutOfTheSwitcher() {
        XCTAssertEqual(policy([]), .accessory)
    }

    func testAVisibleRealWindowPutsTheAppInTheSwitcher() {
        XCTAssertEqual(policy([Self.realWindow]), .regular)
    }

    func testAClosedSwiftUIWindowDoesNotCount() {
        XCTAssertEqual(policy([Self.closedWindow], current: .regular), .accessory)
    }

    func testAMiniaturizedWindowKeepsTheAppInTheSwitcher() {
        XCTAssertEqual(policy([Self.miniaturizedWindow], current: .regular), .regular)
    }

    func testTheIslandAndTheRestingNotchDoNotCount() {
        XCTAssertEqual(policy([Self.overlayPanel, Self.overlayPanel]), .accessory)
    }

    func testTheFloatingMiniWindowDoesNotCountThoughItHasATitleBar() {
        XCTAssertEqual(policy([Self.floatingPanel]), .accessory)
    }

    func testTheStatusItemsWindowPopoversAndSwiftUIHelpersDoNotCount() {
        XCTAssertEqual(policy([Self.borderlessHelper]), .accessory)
    }

    func testASheetDoesNotCountOnItsOwn() {
        var sheet = Self.realWindow
        sheet.isSheet = true
        sheet.hasParent = true
        XCTAssertEqual(policy([sheet]), .accessory)
    }

    func testAChildWindowDoesNotCount() {
        var child = Self.realWindow
        child.hasParent = true
        XCTAssertEqual(policy([child]), .accessory)
    }

    func testATitledWindowThatRefusesToBecomeMainDoesNotCount() {
        var window = Self.realWindow
        window.canBecomeMain = false
        XCTAssertEqual(policy([window]), .accessory)
    }

    func testAPanelInTheDockDoesNotCount() {
        var panel = Self.miniaturizedWindow
        panel.isPanel = true
        XCTAssertEqual(policy([panel]), .accessory)
    }

    func testOneRealWindowAmongTheOthersIsEnough() {
        let windows = [
            Self.overlayPanel, Self.floatingPanel, Self.borderlessHelper, Self.closedWindow, Self.realWindow,
        ]
        XCTAssertEqual(policy(windows), .regular)
    }

    func testClosingTheLastRealWindowLeavesTheSwitcherWithTheOverlaysStillUp() {
        let windows = [Self.overlayPanel, Self.overlayPanel, Self.floatingPanel, Self.closedWindow]
        XCTAssertEqual(policy(windows, current: .regular), .accessory)
    }

    /// ⌘H orders every window out without closing it. Leaving the switcher then would take
    /// away the only ways back.
    func testAHiddenAppKeepsItsPlaceInTheSwitcher() {
        XCTAssertEqual(policy([Self.closedWindow], appIsHidden: true, current: .regular), .regular)
    }

    /// Hide Others from another app must not bring a Dock icon up, either.
    func testAHiddenAppWithoutAPlaceInTheSwitcherDoesNotGainOne() {
        XCTAssertEqual(policy([Self.realWindow], appIsHidden: true, current: .accessory), .accessory)
    }

    func testTheDecisionComesFromTheWindowsNotFromTheCurrentPolicy() {
        for current: NSApplication.ActivationPolicy in [.regular, .accessory] {
            XCTAssertEqual(policy([Self.realWindow], current: current), .regular)
            XCTAssertEqual(policy([Self.closedWindow], current: current), .accessory)
        }
    }

    // MARK: - Focus

    /// A window opened from the footer: the app was active before the policy changed, and asks
    /// again so its menu bar comes up with it.
    func testGainingADockIconWhileActiveAsksForActivationAgain() {
        XCTAssertTrue(ActivationPolicyRules.activatesAfterChange(to: .regular, appIsActive: true))
    }

    /// A window that showed by itself (restored at launch, an updater's alert) never takes the
    /// keyboard from the app in front.
    func testGainingADockIconWhileInactiveDoesNotStealFocus() {
        XCTAssertFalse(ActivationPolicyRules.activatesAfterChange(to: .regular, appIsActive: false))
    }

    func testLeavingTheSwitcherNeverAsksForActivation() {
        XCTAssertFalse(ActivationPolicyRules.activatesAfterChange(to: .accessory, appIsActive: true))
        XCTAssertFalse(ActivationPolicyRules.activatesAfterChange(to: .accessory, appIsActive: false))
    }
}
