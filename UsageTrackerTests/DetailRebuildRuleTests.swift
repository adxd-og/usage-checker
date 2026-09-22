import XCTest
@testable import Omelette

/// The dashboard's detail column is rebuilt every time its window comes back on
/// screen, and snapshots that arrive while the window is hidden are not applied
/// to it: on macOS 27.0 a text created inside a hidden window is drawn upside
/// down once the window shows again.
final class DetailRebuildRuleTests: XCTestCase {
    func testAWindowThatStaysVisibleIsNeverRebuilt() {
        var rule = DetailRebuildRule()
        XCTAssertFalse(rule.windowVisibilityChanged(true))
        XCTAssertFalse(rule.windowVisibilityChanged(true))
    }

    func testAWindowComingBackOnScreenIsRebuiltOnce() {
        var rule = DetailRebuildRule()
        XCTAssertFalse(rule.windowVisibilityChanged(false))
        XCTAssertTrue(rule.windowVisibilityChanged(true))
        XCTAssertFalse(rule.windowVisibilityChanged(true))
    }

    func testEveryReturnToTheScreenEarnsItsOwnRebuild() {
        var rule = DetailRebuildRule()
        _ = rule.windowVisibilityChanged(false)
        XCTAssertTrue(rule.windowVisibilityChanged(true))
        _ = rule.windowVisibilityChanged(false)
        XCTAssertTrue(rule.windowVisibilityChanged(true))
    }

    func testSnapshotsAreAppliedOnlyWhileTheWindowIsVisible() {
        var rule = DetailRebuildRule()
        XCTAssertTrue(rule.appliesSnapshots)
        _ = rule.windowVisibilityChanged(false)
        XCTAssertFalse(rule.appliesSnapshots)
        _ = rule.windowVisibilityChanged(true)
        XCTAssertTrue(rule.appliesSnapshots)
    }
}
