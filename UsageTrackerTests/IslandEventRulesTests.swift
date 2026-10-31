import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 (Clicks through the transparent part, Focus,
/// Dismissal, Entry points) and § 3.8: an outside click, Esc, the open island's notch strip,
/// the status item and another Brioche window close it; its child windows count as inside;
/// a status-item click is one action and one dismissal; a swallowed event stays swallowed;
/// the notch is a button VoiceOver can press.
final class IslandEventRulesTests: XCTestCase {
    private func entry(
        _ entry: IslandEntry, open: Bool = true, at openID: UInt32? = 1, to entryID: UInt32? = 1
    ) -> IslandEventRules.EntryVerdict {
        IslandEventRules.entry(entry, isOpen: open, openScreenID: openID, entryScreenID: entryID)
    }

    func testAClickInsideTheIslandIsLeftToTheContent() {
        XCTAssertEqual(IslandEventRules.localClick(.island(.body)), .pass)
    }

    func testAClickOnTheOpenIslandsNotchStripClosesIt() {
        XCTAssertEqual(IslandEventRules.localClick(.island(.notchStrip)), .closeAndSwallow)
    }

    func testAClickThatReachesTheTransparentPartIsAFallbackThatClosesAndSwallows() {
        XCTAssertEqual(IslandEventRules.localClick(.island(.outside)), .closeAndSwallow)
    }

    func testTheStatusItemAndTheNotchHandleTheirOwnClicks() {
        XCTAssertEqual(IslandEventRules.localClick(.statusItem), .pass, "its toggle closes: one action, one dismissal")
        XCTAssertEqual(IslandEventRules.localClick(.restingNotch), .pass)
    }

    func testAClickInTheIslandsChildWindowCountsAsInside() {
        XCTAssertEqual(IslandEventRules.localClick(.childOfIsland), .pass)
    }

    func testAClickInAnotherBriocheWindowClosesTheIslandAndStillReachesIt() {
        XCTAssertEqual(IslandEventRules.localClick(.otherWindow), .close)
    }

    func testAClickWithNoWindowIsLeftAlone() {
        XCTAssertEqual(IslandEventRules.localClick(.noWindow), .pass)
    }

    func testEveryEntryOpensAClosedIsland() {
        let entries: [IslandEntry] = [.statusItem(buttonFrame: .zero), .notch, .ear, .notification(pointer: .zero)]
        for e in entries {
            XCTAssertEqual(entry(e, open: false, at: nil), .open, "\(e)")
        }
    }

    func testTheStatusItemClosesAnOpenIslandWhereverItIs() {
        XCTAssertEqual(entry(.statusItem(buttonFrame: .zero)), .close)
        XCTAssertEqual(entry(.statusItem(buttonFrame: .zero), at: 2, to: 1), .close)
    }

    func testTheNotchClosesTheIslandOnItsDisplayAndMovesOneOpenElsewhere() {
        XCTAssertEqual(entry(.notch, at: 1, to: 1), .close)
        XCTAssertEqual(entry(.notch, at: 2, to: 1), .open)
    }

    func testANotificationKeepsTheIslandOpenOnItsDisplayAndMovesOneOpenElsewhere() {
        XCTAssertEqual(entry(.notification(pointer: .zero), at: 1, to: 1), .stay)
        XCTAssertEqual(entry(.notification(pointer: .zero), at: 1, to: 2), .open, "the pointer is on another display")
    }

    func testAnEarKeepsAnOpenIslandOpen() {
        XCTAssertEqual(entry(.ear), .stay)
    }

    /// Plan ruling R5, the ledger's open item: the real ears act as the notch does.
    func testAnEarMovesAnIslandOpenOnAnotherDisplay() {
        XCTAssertEqual(entry(.ear, at: 2, to: 1), .open)
    }

    func testAnotherWindowBecomingKeyClosesTheIsland() {
        XCTAssertTrue(IslandEventRules.closesOnKeyWindow(isIsland: false, isChildOfIsland: false))
    }

    func testTheIslandOrItsChildBecomingKeyKeepsItOpen() {
        XCTAssertFalse(IslandEventRules.closesOnKeyWindow(isIsland: true, isChildOfIsland: false))
        XCTAssertFalse(IslandEventRules.closesOnKeyWindow(isIsland: false, isChildOfIsland: true))
    }

    func testPopoversMenusAndAttachedWindowsAreTheIslandsChildren() {
        XCTAssertTrue(IslandEventRules.isChildOfIsland(parentIsIsland: true, listedAsChild: false, className: "NSWindow"))
        XCTAssertTrue(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: true, className: "NSWindow"))
        XCTAssertTrue(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: "_NSPopoverWindow"))
        XCTAssertTrue(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: "NSMenuWindowManagerWindow"))
    }

    func testOtherWindowsAreNotTheIslandsChildren() {
        XCTAssertFalse(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: "SwiftUI.AppKitWindow"))
        XCTAssertFalse(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: "NSPanel"))
    }

    /// Review finding 1: the spike's `self?.handleKey(event) ?? event` turned a swallowed Esc
    /// back into the event, which went on down the responder chain and beeped.
    @MainActor
    func testASwallowedEventStaysSwallowedAndAGoneControllerPassesEverythingOn() {
        XCTAssertNil(
            IslandEventRules.forward(7, to: { _ in nil }),
            "a nil verdict must stay nil, or the swallowed Esc reaches AppKit and beeps"
        )
        XCTAssertEqual(IslandEventRules.forward(7, to: { $0 }), 7)
        XCTAssertEqual(IslandEventRules.forward(7, to: nil), 7, "no controller: the event goes on")
    }

    func testVoiceOverReadsTheNotchAsBrioche() {
        XCTAssertEqual(IslandEventRules.notchAccessibilityLabel, "Brioche")
    }

    /// The P1 review's item 4, carried here: a label alone says nothing of what the button does.
    func testVoiceOverHearsWhatTheNotchDoes() {
        XCTAssertEqual(IslandEventRules.notchAccessibilityHelp, "Opens Brioche. Press again to close it.")
    }
}
