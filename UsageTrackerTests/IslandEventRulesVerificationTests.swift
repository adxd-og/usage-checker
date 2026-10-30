import XCTest
@testable import Omelette

/// Verification of notch-island spec 2026-10-29 § 3.1 (Dismissal, Entry points, Focus) for
/// the pairs `IslandEventRulesTests` leaves out: the entry matrix across displays whole,
/// the ear on another display, child-window class names Omelette's own windows must not match,
/// and `forward` returning what the handler returned.
final class IslandEventRulesVerificationTests: XCTestCase {
    private let entries: [(String, IslandEntry)] = [
        ("statusItem", .statusItem(buttonFrame: .zero)), ("notch", .notch), ("ear", .ear),
        ("notification", .notification(pointer: .zero)),
    ]

    func testAClosedIslandOpensOnEveryEntryWhateverDisplaysAreNamed() {
        for (name, e) in entries {
            for (open, target) in [(nil, nil), (UInt32(1), UInt32(1)), (UInt32(1), UInt32(2)), (nil, UInt32(2))] as [(UInt32?, UInt32?)] {
                XCTAssertEqual(
                    IslandEventRules.entry(e, isOpen: false, openScreenID: open, entryScreenID: target), .open, name
                )
            }
        }
    }

    func testTheWholeMatrixOfAnOpenIsland() {
        // (entry, same display) -> verdict, (entry, other display) -> verdict
        let expected: [String: (same: IslandEventRules.EntryVerdict, other: IslandEventRules.EntryVerdict)] = [
            "statusItem": (.close, .close),
            "notch": (.close, .open),
            "ear": (.stay, .stay),
            "notification": (.stay, .open),
        ]
        for (name, e) in entries {
            XCTAssertEqual(IslandEventRules.entry(e, isOpen: true, openScreenID: 1, entryScreenID: 1), expected[name]?.same, "\(name) same")
            XCTAssertEqual(IslandEventRules.entry(e, isOpen: true, openScreenID: 1, entryScreenID: 2), expected[name]?.other, "\(name) other")
        }
    }

    func testOnlyTheEarAndTheNotificationLeaveAnOpenIslandOpenOnItsOwnDisplay() {
        let staying = entries.filter {
            IslandEventRules.entry($0.1, isOpen: true, openScreenID: 3, entryScreenID: 3) == .stay
        }.map(\.0)
        XCTAssertEqual(Set(staying), ["ear", "notification"])
    }

    func testOmeletteOwnWindowsAreNotTakenForTheIslandsChildren() {
        for name in [
            "SwiftUI.AppKitWindow", "NSStatusBarWindow", "RestingNotchPanel", "IslandWindow",
            "NSPanel", "FloatingPanel", "SPUStandardUpdaterWindow",
        ] {
            XCTAssertFalse(
                IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: name), name
            )
        }
    }

    func testAnyMenuOrPopoverWindowIsAChildWhoeverItsParentIs() {
        for name in ["_NSPopoverWindow", "NSPopoverWindow", "NSContextMenuWindow", "NSCarbonMenuWindow"] {
            XCTAssertTrue(IslandEventRules.isChildOfIsland(parentIsIsland: false, listedAsChild: false, className: name), name)
        }
    }

    func testEscapeFromAnyOtherKeyNeverClosesWhileTheIslandIsKey() {
        for code: UInt16 in [0, 36, 48, 51, 52, 54, 123, 126] {
            XCTAssertNil(
                IslandEventRules.navigationKey(
                    keyCode: code, command: false, shift: false, option: false, control: false, keyWindowIsIsland: true
                ),
                "\(code)"
            )
        }
        XCTAssertEqual(IslandEventRules.escapeKeyCode, 53)
    }

    @MainActor
    func testForwardHandsBackWhatTheHandlerReturnedNotTheOriginalEvent() {
        XCTAssertEqual(IslandEventRules.forward(1, to: { $0 + 41 }), 42)
        XCTAssertNil(IslandEventRules.forward("esc", to: { _ in String?.none }))
    }

    func testNoClickTargetClosesAndSwallowsExceptInsideTheNotchStripAndTheTransparentRest() {
        let targets: [IslandEventRules.ClickTarget] = [
            .island(.body), .island(.notchStrip), .island(.outside), .statusItem, .restingNotch,
            .childOfIsland, .otherWindow, .noWindow,
        ]
        let swallowing = targets.filter { IslandEventRules.localClick($0) == .closeAndSwallow }
        XCTAssertEqual(swallowing, [.island(.notchStrip), .island(.outside)])
        let closing = targets.filter { IslandEventRules.localClick($0) == .close }
        XCTAssertEqual(closing, [.otherWindow])
    }
}
