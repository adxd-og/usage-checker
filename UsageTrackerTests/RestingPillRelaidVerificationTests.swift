import CoreGraphics
import XCTest
@testable import Omelette

/// 4.1.0 release review F1, F2, F3 (rulings A and B): an ear update lays only the pills there are
/// (`RestingPillRules.relaid`), the set changes only through `changes` at a re-place point, and a
/// changed set is what makes the status item read its visibility again. The controller's wiring is
/// a hand check; these tests pin the rules it is wired from, on the owner's measured setups.
final class RestingPillRelaidVerificationTests: XCTestCase {
    private let lidOpen = [ScreenFixture.builtIn, ScreenFixture.secondaryExternal]
    private let barsBoth = [MenuBarWindowFixture.builtIn, MenuBarWindowFixture.secondaryExternal]

    private func reading(_ screens: [IslandScreen], _ windows: [MenuBarWindow]) -> [IslandScreen] {
        IslandScreen.attached(screens, menuBarWindows: windows)
    }

    private func ids(_ screens: [IslandScreen]) -> Set<UInt32> {
        Set(RestingPillRules.pills(screens).map(\.displayID))
    }

    private func shown(_ setting: Bool?, _ screens: [IslandScreen]) -> Bool {
        StatusItemVisibilityRules.isShown(
            setting: setting, islandDisplayAttached: StatusItemVisibilityRules.islandDisplayAttached(screens)
        )
    }

    /// Readings of the owner's setups, with a decoy display whose id no pill ever stood on.
    private var readings: [[IslandScreen]] {
        let stranger = IslandScreen(
            id: 9, frame: CGRect(x: 4072, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 4072, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
        )
        return [
            reading(lidOpen, barsBoth),
            reading(lidOpen, [MenuBarWindowFixture.builtIn]),
            reading(lidOpen, []),
            reading([ScreenFixture.builtIn], [MenuBarWindowFixture.builtIn]),
            reading([ScreenFixture.lidClosedExternal], [MenuBarWindowFixture.lidClosedExternal]),
            reading([ScreenFixture.lidClosedExternal], []),
            reading(lidOpen + [stranger], barsBoth + [MenuBarWindow(
                ownerName: "Window Server", layer: 24, boundsCG: CGRect(x: 4072, y: 0, width: 2560, height: 30)
            )]),
            [],
        ]
    }

    // MARK: - relaid

    func testRelaidNeverYieldsADisplayOutsideKeptWhateverTheReadingAndTheKeptSet() {
        let kepts: [Set<UInt32>] = [[], [1], [2], [9], [1, 2], [2, 9], [1, 2, 9], [77], [1, 77]]
        for screens in readings {
            for kept in kepts {
                let laid = RestingPillRules.relaid(kept: kept, screens: screens).map(\.displayID)
                XCTAssertTrue(Set(laid).isSubset(of: kept), "kept \(kept) laid \(laid)")
                XCTAssertTrue(Set(laid).isSubset(of: ids(screens)), "kept \(kept) laid \(laid) beyond the reading's islands")
                XCTAssertEqual(Set(laid), kept.intersection(ids(screens)), "kept \(kept)")
                XCTAssertEqual(laid.count, Set(laid).count, "no pill laid twice")
            }
        }
    }

    func testRelaidWithEveryPillOfTheReadingKeptIsTheReadingsPillsWhole() {
        for screens in readings {
            XCTAssertEqual(
                RestingPillRules.relaid(kept: ids(screens), screens: screens), RestingPillRules.pills(screens)
            )
        }
    }

    func testRelaidKeepsTheDisplaysOrderNotTheIdOrder() {
        func wide(_ id: UInt32, x: CGFloat) -> IslandScreen {
            IslandScreen(
                id: id, frame: CGRect(x: x, y: 0, width: 2560, height: 1440),
                visibleFrame: CGRect(x: x, y: 0, width: 2560, height: 1416),
                safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil
            )
        }
        let screens = [wide(7, x: 0), wide(4, x: 2560), wide(9, x: 5120)]
        XCTAssertEqual(RestingPillRules.relaid(kept: [4, 7, 9], screens: screens).map(\.displayID), [7, 4, 9])
        XCTAssertEqual(RestingPillRules.relaid(kept: [9, 7], screens: screens).map(\.displayID), [7, 9])
    }

    func testRelaidOfNothingIsNothing() {
        XCTAssertEqual(RestingPillRules.relaid(kept: [], screens: []), [])
        XCTAssertEqual(RestingPillRules.relaid(kept: [1, 2], screens: []), [])
        XCTAssertEqual(RestingPillRules.relaid(kept: [], screens: reading(lidOpen, barsBoth)), [])
    }

    func testRelaidLaysAKeptPillOverItsNotchInTheStoredReadingNotInAnyNewerOne() {
        // The pill on the external stood at the bar-up reading; the stored reading is what it is laid on.
        let stored = reading(lidOpen, barsBoth)
        let laid = RestingPillRules.relaid(kept: [2], screens: stored)
        XCTAssertEqual(laid.count, 1)
        XCTAssertEqual(laid.first?.notch, stored.first { $0.id == 2 }?.islandNotch)
        XCTAssertNotNil(laid.first?.notch)
    }

    func testRelaidIsNotAChangeSoAKeptSetStaysTheSetAfterAnyNumberOfEarUpdates() {
        // `changes` is what a re-place point asks; an ear update asks `relaid` and never changes `kept`.
        let stored = reading(lidOpen, [MenuBarWindowFixture.builtIn])
        var kept: Set<UInt32> = [1]
        for _ in 0..<3 {
            let laid = RestingPillRules.relaid(kept: kept, screens: stored)
            kept.formUnion(laid.map(\.displayID))
            XCTAssertEqual(kept, [1])
        }
    }

    // MARK: - The pill set and the status item, through the real rules

    /// The re-place point (`placePills`): the changes against the pills kept, and the status item
    /// read on the same reading.
    private func replace(
        kept: Set<UInt32>, onto screens: [IslandScreen], setting: Bool? = nil
    ) -> (changes: RestingPillRules.Changes, kept: Set<UInt32>, itemShown: Bool) {
        let changes = RestingPillRules.changes(kept: kept, wanted: RestingPillRules.pills(screens))
        let next = kept.subtracting(changes.drop).union(changes.create)
        return (changes, next, shown(setting, screens))
    }

    func testAFullScreenAppOnTheLidClosedExternalTakesTheLastPillAndForcesTheItemOn() {
        let bar = reading([ScreenFixture.lidClosedExternal], [MenuBarWindowFixture.lidClosedExternal])
        let fullScreen = reading([ScreenFixture.lidClosedExternal], [])
        let atLaunch = replace(kept: [], onto: bar)
        XCTAssertEqual(atLaunch.kept, [2])
        XCTAssertFalse(atLaunch.itemShown, "the item is off by default while a pill stands")

        let entering = replace(kept: atLaunch.kept, onto: fullScreen)
        XCTAssertFalse(entering.changes.isEmpty, "the set changed, so the item reads its visibility again")
        XCTAssertEqual(entering.changes, RestingPillRules.Changes(create: [], drop: [2]))
        XCTAssertEqual(entering.kept, [])
        for setting: Bool? in [nil, false, true] {
            XCTAssertTrue(replace(kept: [2], onto: fullScreen, setting: setting).itemShown, "setting \(String(describing: setting))")
        }

        let leaving = replace(kept: entering.kept, onto: bar)
        XCTAssertFalse(leaving.changes.isEmpty)
        XCTAssertEqual(leaving.changes, RestingPillRules.Changes(create: [2], drop: []))
        XCTAssertFalse(leaving.itemShown, "the pill is back, the item goes again")
        XCTAssertTrue(replace(kept: [2], onto: bar, setting: true).itemShown, "unless Show in menu bar is on")
    }

    func testAFullScreenAppOnTheExternalBesideTheMacBookDropsOnlyItsPillAndMovesNoItem() {
        let up = reading(lidOpen, barsBoth)
        let external = reading(lidOpen, [MenuBarWindowFixture.builtIn])
        let entering = replace(kept: [1, 2], onto: external)
        XCTAssertEqual(entering.changes, RestingPillRules.Changes(create: [], drop: [2]))
        XCTAssertEqual(entering.kept, [1])
        XCTAssertFalse(entering.itemShown, "the MacBook still shows the island: the item stays where it was")
        XCTAssertEqual(shown(nil, up), shown(nil, external))
        let leaving = replace(kept: entering.kept, onto: up)
        XCTAssertEqual(leaving.changes, RestingPillRules.Changes(create: [2], drop: []))
        XCTAssertEqual(leaving.kept, [1, 2])
        XCTAssertFalse(leaving.itemShown)
    }

    func testTheNotchedMacBookAloneChangesNoSetAcrossAnyReadingOfItsMenuBar() {
        let bar = reading([ScreenFixture.builtIn], [MenuBarWindowFixture.builtIn])
        let fullScreen = reading([ScreenFixture.builtIn], [])
        let rename = reading([ScreenFixture.builtIn], [MenuBarWindow(
            ownerName: "WindowServer", layer: 24, boundsCG: CGRect(x: 0, y: 0, width: 1512, height: 33)
        )])
        for next in [bar, fullScreen, rename] {
            let step = replace(kept: [1], onto: next)
            XCTAssertTrue(step.changes.isEmpty, "a notched MacBook alone never changes the set")
            XCTAssertEqual(step.kept, [1])
            XCTAssertFalse(step.itemShown)
            XCTAssertTrue(replace(kept: [1], onto: next, setting: true).itemShown)
        }
    }

    func testTheItemChangesOnlyWhenTheSetDoes() {
        // Whatever the transition between two of the readings: if the item's forced state differs,
        // `changes` is not empty, so the re-place point that sees an empty change need not re-read it.
        for before in readings {
            for after in readings {
                let attachedBefore = StatusItemVisibilityRules.islandDisplayAttached(before)
                let attachedAfter = StatusItemVisibilityRules.islandDisplayAttached(after)
                let changes = RestingPillRules.changes(kept: ids(before), wanted: RestingPillRules.pills(after))
                if attachedBefore != attachedAfter {
                    XCTAssertFalse(changes.isEmpty)
                }
                if changes.isEmpty {
                    XCTAssertEqual(ids(before), ids(after))
                    XCTAssertEqual(attachedBefore, attachedAfter)
                }
            }
        }
    }

    func testAnEarUpdateAfterAnAutoHiddenBarSlidDownLeavesNoPillBehindOnceItSlidsBackUp() {
        // F2: the pills were placed with the external's bar away; the bar slides down while the ears
        // move (the window list now has it), then back up. Ear updates lay on the stored reading only.
        let stored = reading(lidOpen, [MenuBarWindowFixture.builtIn])
        var kept = ids(stored)
        XCTAssertEqual(kept, [1])
        let slidDown = reading(lidOpen, barsBoth)
        XCTAssertEqual(ids(slidDown), [1, 2])
        // The ear update: relaid on the stored reading, not on slidDown.
        kept.formUnion(RestingPillRules.relaid(kept: kept, screens: stored).map(\.displayID))
        XCTAssertEqual(kept, [1])
        // The bar slides up; the next re-place point finds the set as it stood.
        let slidUp = reading(lidOpen, [MenuBarWindowFixture.builtIn])
        XCTAssertTrue(RestingPillRules.changes(kept: kept, wanted: RestingPillRules.pills(slidUp)).isEmpty)
    }
}
