import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.1 Notch hint, D13: hover over the notch, after ≈ 150 ms the shape
/// breathes 4–6 pt down and a little wider, a spring; leaving reverses it from where it is; hover
/// never opens; Reduce Motion is a brighter outline only. The P0 spike's numbers: 5 down, 3 a side.
final class NotchHintTests: XCTestCase {
    private func up(at time: TimeInterval = 100) -> NotchHint {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.delayElapsed(at: time, islandClosed: true, reduceMotion: false)
        return hint
    }

    func testTheNumbersAreTheSpecs() {
        XCTAssertEqual(IslandMotion.hintDelay, 0.15)
        XCTAssertTrue((4...6).contains(IslandMotion.hintDown))
        XCTAssertEqual(IslandMotion.hintWiden, 3)
    }

    func testEnteringAsksForTheWaitAndNothingShowsYet() {
        var hint = NotchHint()
        XCTAssertTrue(hint.pointerEntered())
        XCTAssertEqual(hint.look(at: 100), .rest)
        XCTAssertFalse(hint.needsFrames)
        XCTAssertTrue(hint.isAtRest)
    }

    func testASecondEnterWhileInsideAsksNothing() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        XCTAssertFalse(hint.pointerEntered())
        var upHint = up()
        XCTAssertFalse(upHint.pointerEntered(), "already up")
    }

    func testAfterTheWaitTheShapeBreathesFiveDownAndThreeWider() {
        let hint = up()
        XCTAssertTrue(hint.isUp)
        XCTAssertTrue(hint.needsFrames)
        XCTAssertFalse(hint.isAtRest)
        let moving = hint.look(at: 100.1)
        XCTAssertGreaterThan(moving.down, 0)
        XCTAssertLessThan(moving.down, 5)
        let settled = hint.look(at: 103)
        XCTAssertEqual(settled.down, 5, accuracy: 0.01)
        XCTAssertEqual(settled.widen, 3, accuracy: 0.01)
        XCTAssertFalse(settled.outlined)
    }

    func testLeavingBeforeTheWaitIsOverCancelsIt() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.pointerLeft(at: 100.05)
        hint.delayElapsed(at: 100.15, islandClosed: true, reduceMotion: false)
        XCTAssertFalse(hint.isUp)
        XCTAssertTrue(hint.isAtRest)
        XCTAssertEqual(hint.look(at: 100.2), .rest)
    }

    func testLeavingReversesFromWhereItIsAndEndsAtRest() {
        var hint = up()
        let before = hint.look(at: 100.25).down
        hint.pointerLeft(at: 100.25)
        XCTAssertEqual(hint.look(at: 100.25).down, before, accuracy: 1e-9, "no jump")
        XCTAssertFalse(hint.isUp)
        XCTAssertTrue(hint.needsFrames)
        XCTAssertFalse(hint.isAtRest, "still on its way back")
        XCTAssertEqual(hint.look(at: 104).down, 0, accuracy: 0.01)
        hint.advance(to: 104)
        XCTAssertFalse(hint.needsFrames)
        XCTAssertTrue(hint.isAtRest)
    }

    func testComingBackDuringTheReturnWaitsThenRisesFromThere() {
        var hint = up()
        hint.pointerLeft(at: 100.25)
        XCTAssertTrue(hint.pointerEntered())
        let before = hint.look(at: 100.4).down
        hint.delayElapsed(at: 100.4, islandClosed: true, reduceMotion: false)
        XCTAssertEqual(hint.look(at: 100.4).down, before, accuracy: 1e-9)
        XCTAssertEqual(hint.look(at: 104).down, 5, accuracy: 0.01)
    }

    func testThereIsNoHintOverAnOpenIsland() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.delayElapsed(at: 100, islandClosed: false, reduceMotion: false)
        XCTAssertFalse(hint.isUp)
        XCTAssertTrue(hint.isAtRest)
    }

    func testTheIslandOpeningEndsItAtOnceAndAPointerLeftInsideDoesNotBringItBack() {
        var hint = up()
        hint.end()
        XCTAssertFalse(hint.needsFrames)
        XCTAssertTrue(hint.isAtRest)
        XCTAssertEqual(hint.look(at: 100.5), .rest)
        XCTAssertFalse(hint.pointerEntered(), "still inside")
        hint.pointerLeft(at: 101)
        XCTAssertTrue(hint.pointerEntered(), "a new visit asks again")
    }

    func testReduceMotionIsABrighterOutlineOnly() {
        var hint = NotchHint()
        _ = hint.pointerEntered()
        hint.delayElapsed(at: 100, islandClosed: true, reduceMotion: true)
        XCTAssertFalse(hint.needsFrames)
        XCTAssertFalse(hint.isAtRest, "the outline needs its room")
        XCTAssertEqual(hint.look(at: 100), NotchHint.Look(down: 0, widen: 0, outlined: true))
        hint.pointerLeft(at: 101)
        XCTAssertEqual(hint.look(at: 101), .rest)
        XCTAssertTrue(hint.isAtRest)
    }
}
