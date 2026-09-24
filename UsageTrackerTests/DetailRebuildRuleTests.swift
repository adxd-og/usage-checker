import XCTest
@testable import Omelette

/// The dashboard's detail column is rebuilt when its window comes back on screen
/// after a poll reached it while hidden, and snapshots that arrive while the window
/// is hidden are not applied by it: on macOS 27.0 a text created inside a hidden
/// window is drawn upside down once the window shows again.
final class DetailRebuildRuleTests: XCTestCase {
    func testTheFirstShowingOfAWindowIsNotARebuild() {
        var rule = DetailRebuildRule()
        XCTAssertFalse(rule.windowVisibilityChanged(true))
        XCTAssertFalse(rule.windowVisibilityChanged(true))
    }

    func testAWindowCoveredForAMomentKeepsItsColumn() {
        var rule = DetailRebuildRule()
        _ = rule.windowVisibilityChanged(true)
        XCTAssertFalse(rule.windowVisibilityChanged(false))
        XCTAssertFalse(rule.windowVisibilityChanged(true), "no poll while hidden: nothing was inserted, nothing to rebuild")
    }

    func testAWindowThatWasPolledWhileHiddenIsRebuiltOnceWhenItShows() {
        var rule = DetailRebuildRule()
        _ = rule.windowVisibilityChanged(true)
        _ = rule.windowVisibilityChanged(false)
        XCTAssertFalse(rule.snapshotArrived())
        XCTAssertTrue(rule.windowVisibilityChanged(true))
        XCTAssertFalse(rule.windowVisibilityChanged(true))
    }

    func testEveryHiddenPollCycleEarnsItsOwnRebuild() {
        var rule = DetailRebuildRule()
        _ = rule.windowVisibilityChanged(true)
        _ = rule.windowVisibilityChanged(false)
        _ = rule.snapshotArrived()
        _ = rule.snapshotArrived()
        XCTAssertTrue(rule.windowVisibilityChanged(true))
        _ = rule.windowVisibilityChanged(false)
        XCTAssertFalse(rule.windowVisibilityChanged(true))
        _ = rule.windowVisibilityChanged(false)
        _ = rule.snapshotArrived()
        XCTAssertTrue(rule.windowVisibilityChanged(true))
    }

    func testSnapshotsAreAppliedOnlyWhileTheWindowIsVisible() {
        var rule = DetailRebuildRule()
        XCTAssertFalse(rule.snapshotArrived(), "not attached to a visible window yet")
        _ = rule.windowVisibilityChanged(true)
        XCTAssertTrue(rule.snapshotArrived())
        _ = rule.windowVisibilityChanged(false)
        XCTAssertFalse(rule.snapshotArrived())
        _ = rule.windowVisibilityChanged(true)
        XCTAssertTrue(rule.snapshotArrived())
    }

    func testASnapshotThatArrivedBeforeTheWindowEverShowedDoesNotForceARebuild() {
        var rule = DetailRebuildRule()
        _ = rule.snapshotArrived()
        XCTAssertTrue(rule.windowVisibilityChanged(true), "polled before the first showing: the column was built hidden, rebuild it")
    }
}
