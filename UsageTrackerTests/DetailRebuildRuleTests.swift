import XCTest
@testable import Omelette

/// The dashboard's detail column is rebuilt once after every resume from sleep or
/// screen lock, on the first snapshot that follows it — never on an ordinary
/// snapshot, and never twice for one resume.
final class DetailRebuildRuleTests: XCTestCase {
    func testASnapshotWithoutAResumeDoesNotRebuild() {
        var rule = DetailRebuildRule()
        XCTAssertFalse(rule.snapshotArrived())
        XCTAssertFalse(rule.snapshotArrived())
    }

    func testTheFirstSnapshotAfterAResumeRebuildsOnce() {
        var rule = DetailRebuildRule()
        rule.resumed()
        XCTAssertTrue(rule.snapshotArrived())
        XCTAssertFalse(rule.snapshotArrived())
    }

    func testTwoResumesBeforeASnapshotRebuildOnce() {
        var rule = DetailRebuildRule()
        rule.resumed()
        rule.resumed()
        XCTAssertTrue(rule.snapshotArrived())
        XCTAssertFalse(rule.snapshotArrived())
    }

    func testEveryResumeEarnsItsOwnRebuild() {
        var rule = DetailRebuildRule()
        rule.resumed()
        XCTAssertTrue(rule.snapshotArrived())
        rule.resumed()
        XCTAssertTrue(rule.snapshotArrived())
    }
}
