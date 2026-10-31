import AppKit
import XCTest
@testable import Omelette

/// Verification of the Cmd+Tab / Dock rule (`ActivationPolicyRules`) and of the reopen it changes
/// (`ReopenRules`): every combination of what AppKit reports for a window, several windows at
/// once, a hidden app, a whole life of the app fed decision into decision, and the activation
/// re-ask. Pure rules only: no window of the test host is ever ordered in.
final class ActivationPolicyVerificationTests: XCTestCase {
    private typealias Facts = ActivationPolicyRules.WindowFacts
    private typealias Policy = NSApplication.ActivationPolicy

    private static let allPolicies: [Policy] = [.regular, .accessory, .prohibited]

    private static let dashboard = Facts(
        isPanel: false, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: true, isVisible: true, isMiniaturized: false
    )
    private static let settings = dashboard
    private static let tour = dashboard
    /// What a window reads while ⌘H has ordered it out: not visible, not miniaturised.
    private static var hiddenByTheApp: Facts {
        var facts = dashboard
        facts.isVisible = false
        facts.canBecomeMain = false
        return facts
    }
    private static var inTheDock: Facts {
        var facts = dashboard
        facts.isVisible = false
        facts.canBecomeMain = false
        facts.isMiniaturized = true
        return facts
    }
    private static let island = Facts(
        isPanel: true, isTitled: false, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )
    private static let floating = Facts(
        isPanel: true, isTitled: true, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )
    private static let statusItemWindow = Facts(
        isPanel: false, isTitled: false, isSheet: false, hasParent: false,
        canBecomeMain: false, isVisible: true, isMiniaturized: false
    )

    private func policy(
        _ windows: [Facts], hidden: Bool = false, current: Policy = .accessory
    ) -> Policy {
        ActivationPolicyRules.policy(windows: windows, appIsHidden: hidden, current: current)
    }

    // MARK: - Every combination of a window's facts

    /// The spec's words, written out from scratch: a titled window that is not a panel, a sheet
    /// or a child counts when it is miniaturised, or when it is on screen and can be main.
    private func specSaysReal(_ f: Facts) -> Bool {
        guard f.isTitled else { return false }
        guard !f.isPanel else { return false }
        guard !f.isSheet && !f.hasParent else { return false }
        if f.isMiniaturized { return true }
        return f.isVisible && f.canBecomeMain
    }

    private func allFacts() -> [Facts] {
        (0..<128).map { bits in
            Facts(
                isPanel: bits & 1 != 0, isTitled: bits & 2 != 0, isSheet: bits & 4 != 0,
                hasParent: bits & 8 != 0, canBecomeMain: bits & 16 != 0,
                isVisible: bits & 32 != 0, isMiniaturized: bits & 64 != 0
            )
        }
    }

    func testEveryCombinationOfAWindowsFactsIsDecidedAsTheSpecSays() {
        for facts in allFacts() {
            XCTAssertEqual(ActivationPolicyRules.isRealWindow(facts), specSaysReal(facts), "\(facts)")
            XCTAssertEqual(policy([facts]), specSaysReal(facts) ? .regular : .accessory, "\(facts)")
        }
    }

    func testAMiniaturizedSheetOrChildStillDoesNotCount() {
        var sheet = Self.inTheDock
        sheet.isSheet = true
        var child = Self.inTheDock
        child.hasParent = true
        XCTAssertEqual(policy([sheet, child], current: .regular), .accessory)
    }

    func testAMiniaturizedUntitledWindowDoesNotCount() {
        var window = Self.inTheDock
        window.isTitled = false
        XCTAssertEqual(policy([window], current: .regular), .accessory)
    }

    // MARK: - Several windows at once

    /// The order of the list is nothing: the same windows, rotated, give the same answer.
    func testTheOrderOfTheWindowsIsNothing() {
        let windows = [Self.island, Self.floating, Self.statusItemWindow, Self.hiddenByTheApp, Self.inTheDock]
        for shift in 0..<windows.count {
            let rotated = Array(windows[shift...] + windows[..<shift])
            XCTAssertEqual(policy(rotated), .regular, "rotated by \(shift)")
        }
        let without = [Self.island, Self.floating, Self.statusItemWindow, Self.hiddenByTheApp]
        for shift in 0..<without.count {
            let rotated = Array(without[shift...] + without[..<shift])
            XCTAssertEqual(policy(rotated, current: .regular), .accessory, "rotated by \(shift)")
        }
    }

    func testTheDashboardSettingsAndTheTourLeaveOneByOneAndTheLastOneTakesTheSwitcherAway() {
        var open = [Self.dashboard, Self.settings, Self.tour]
        var current: Policy = .regular
        for _ in 0..<2 {
            open.removeLast()
            current = policy(open + [Self.island, Self.floating], current: current)
            XCTAssertEqual(current, .regular, "\(open.count) left")
        }
        open.removeLast()
        XCTAssertEqual(policy(open + [Self.island, Self.floating], current: current), .accessory)
    }

    func testOneWindowInTheDockHoldsTheSwitcherWhileTheOthersAreClosed() {
        XCTAssertEqual(policy([Self.hiddenByTheApp, Self.inTheDock, Self.island], current: .regular), .regular)
    }

    func testOverlaysAndPanelsBySizeNeverCountHoweverManyThereAre() {
        let crowd = Array(repeating: Self.island, count: 30) + Array(repeating: Self.floating, count: 30)
            + Array(repeating: Self.statusItemWindow, count: 30)
        XCTAssertEqual(policy(crowd, current: .regular), .accessory)
    }

    // MARK: - A hidden app

    func testAHiddenAppKeepsWhateverPolicyItHasWhateverTheWindowsSay() {
        let sets: [[Facts]] = [
            [], [Self.hiddenByTheApp], [Self.dashboard], [Self.inTheDock], [Self.island, Self.floating],
        ]
        for current in Self.allPolicies {
            for windows in sets {
                XCTAssertEqual(policy(windows, hidden: true, current: current), current)
            }
        }
    }

    // MARK: - A life of the app, each decision fed into the next

    func testFromFirstWindowToLastCloseTheSwitcherFollowsTheWindows() {
        var current: Policy = .accessory
        func step(_ windows: [Facts], hidden: Bool = false, expecting expected: Policy, _ what: String) {
            current = policy(windows, hidden: hidden, current: current)
            XCTAssertEqual(current, expected, what)
        }
        let chrome = [Self.island, Self.floating, Self.statusItemWindow]
        step(chrome, expecting: .accessory, "launch: nothing real")
        step(chrome + [Self.dashboard], expecting: .regular, "the footer opens the Dashboard")
        step(chrome + [Self.dashboard, Self.settings], expecting: .regular, "Settings joins")
        step(chrome + [Self.hiddenByTheApp, Self.hiddenByTheApp], hidden: true, expecting: .regular, "⌘H")
        step(chrome + [Self.dashboard, Self.settings], expecting: .regular, "unhidden")
        step(chrome + [Self.inTheDock, Self.settings], expecting: .regular, "Dashboard minimised")
        step(chrome + [Self.inTheDock, Self.hiddenByTheApp], expecting: .regular, "Settings closed")
        step(chrome + [Self.dashboard, Self.hiddenByTheApp], expecting: .regular, "Dashboard restored")
        step(chrome + [Self.hiddenByTheApp, Self.hiddenByTheApp], expecting: .accessory, "the last one closed")
        step(chrome + [Self.hiddenByTheApp, Self.hiddenByTheApp], hidden: true, expecting: .accessory,
             "Hide Others from another app does not bring a Dock icon")
    }

    // MARK: - Asking for activation again

    func testOnlyGainingTheSwitcherWhileActiveAsksForActivationWhateverThePolicy() {
        for target in Self.allPolicies {
            for active in [true, false] {
                XCTAssertEqual(
                    ActivationPolicyRules.activatesAfterChange(to: target, appIsActive: active),
                    target == .regular && active,
                    "\(target.rawValue) active \(active)"
                )
            }
        }
    }

    // MARK: - Reopen with the Dock icon the rule gives

    /// A Dashboard in the Dock reads as no visible window to AppKit and as a Dock icon to the
    /// rule: a reopen then goes to AppKit, which brings the window back, and not to the island.
    func testAReopenWithTheDashboardInTheDockLeavesTheIslandClosed() {
        let windows = [Self.island, Self.inTheDock]
        let icon = policy(windows, current: .regular) == .regular
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false, hasDockIcon: icon), .leaveAlone)
    }

    func testAReopenWithOnlyOverlaysUpStillOpensTheIsland() {
        let windows = [Self.island, Self.floating, Self.statusItemWindow, Self.hiddenByTheApp]
        let icon = policy(windows, current: .accessory) == .regular
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false, hasDockIcon: icon), .openIsland)
        XCTAssertFalse(ReopenRules.action(hasVisibleWindows: false, hasDockIcon: icon).appKitHandlesReopen)
    }

    /// The same, from a hidden app that has a Dock icon: the click returns it, the island stays shut.
    func testAReopenOfAHiddenAppWithADockIconLeavesItToAppKit() {
        let current = policy([Self.hiddenByTheApp], hidden: true, current: .regular)
        XCTAssertEqual(current, .regular)
        XCTAssertEqual(ReopenRules.action(hasVisibleWindows: false, hasDockIcon: current == .regular), .leaveAlone)
    }

    // MARK: - Overlays stay up when the app is hidden

    /// ⌘H hides every window that can hide. The island and the resting notch must not be among
    /// them: a hidden app keeps its Dock icon, and an island that vanished with it would not
    /// come back with the click on the icon. Windows built, never ordered in.
    @MainActor
    func testTheIslandAndTheRestingNotchPanelsAreNotHiddenWithTheApp() {
        XCTAssertFalse(IslandWindow.make().canHide)
        XCTAssertFalse(RestingNotchPanel.make().canHide)
    }
}
