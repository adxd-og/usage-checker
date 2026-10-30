import SwiftUI
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.2 and § 3.9 (`IslandTransition`): closed → opening →
/// open → closing on an injected clock; the content in after the shape and out before it;
/// content hit-testable and exposed to accessibility only once its entrance has finished;
/// an interrupt turns around from the current value; a stale completion never revives
/// closing content; the answer depends on the times, not on which frames came; the panel's
/// content-only motion and Reduce Motion's 150 ms cross-fade. Times are literal seconds,
/// each `advance` one frame; a check sits 5 ms either side of a deadline.
final class IslandTransitionTests: XCTestCase {
    /// An island opened at `time` and run through its frames until it is open with its shape
    /// at rest: a frame at once, one just after the content's head start, one a second later.
    private func openIsland(at time: TimeInterval = 0, style: IslandMotion.Style = .spring) -> IslandTransition {
        var t = IslandTransition()
        t.open(style: style, at: time)
        t.advance(to: time)
        t.advance(to: time + 0.125)
        t.advance(to: time + 1)
        return t
    }

    // MARK: Open

    func testAClosedIslandShowsNothingAndNeedsNoFrames() {
        let t = IslandTransition()
        XCTAssertEqual(t.phase, .closed)
        XCTAssertEqual(t.stage, .closed)
        XCTAssertFalse(t.stage.contentShown)
        XCTAssertFalse(t.stage.interactive)
        XCTAssertFalse(t.stage.islandShown)
        XCTAssertFalse(t.isOpen)
        XCTAssertFalse(t.needsFrames)
        XCTAssertEqual(t.progress(at: 5), 0)
    }

    func testOpeningSpringsTheShapeOutOfTheNotchWithTheContentHeldBack() {
        var t = IslandTransition()
        t.open(style: .spring, at: 10)
        XCTAssertEqual(t.stage, .closed, "nothing changes on screen until the clock's next frame")
        t.advance(to: 10)
        XCTAssertEqual(t.phase, .opening)
        XCTAssertTrue(t.isOpen)
        XCTAssertTrue(t.needsFrames)
        XCTAssertTrue(t.stage.islandShown)
        XCTAssertNil(t.stage.islandFade)
        XCTAssertFalse(t.stage.contentShown)
        XCTAssertFalse(t.stage.interactive)
        XCTAssertEqual(t.progress(at: 10), 0, accuracy: 1e-12)
        XCTAssertEqual(t.progress(at: 10.12), IslandMotion.open.value(target: 1.0, time: 10.12 - 10), accuracy: 1e-9)
    }

    func testTheContentComesInAfterTheShapesHeadStart() {
        var t = IslandTransition()
        t.open(style: .spring, at: 10)
        t.advance(to: 10)
        t.advance(to: 10.115)
        XCTAssertFalse(t.stage.contentShown)
        t.advance(to: 10.125)
        XCTAssertTrue(t.stage.contentShown)
        XCTAssertEqual(t.stage.contentFade, IslandMotion.Fade(duration: 0.28, curve: .easeOut))
        XCTAssertFalse(t.stage.interactive, "fading in: not yet clickable or read by VoiceOver")
        XCTAssertEqual(t.phase, .opening)
    }

    func testTheIslandIsOpenOnlyOnceTheContentHasFinishedComingIn() {
        var t = IslandTransition()
        t.open(style: .spring, at: 10)
        t.advance(to: 10)
        t.advance(to: 10.125)
        // The content's fade began on the 10.125 frame: it is in at 10.405.
        t.advance(to: 10.4)
        XCTAssertEqual(t.phase, .opening)
        XCTAssertFalse(t.stage.interactive)
        t.advance(to: 10.41)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertTrue(t.stage.contentShown)
    }

    func testALateFirstFrameStillWaitsForTheContentsWholeEntrance() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0.7)
        XCTAssertTrue(t.stage.contentShown, "its fade begins on this frame")
        XCTAssertFalse(t.stage.interactive, "not clickable or read before it has appeared")
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 0.975)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 0.985)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
    }

    func testTheShapeSettlesAfterTheIslandIsOpenAndThenNeedsNoFrames() {
        var t = IslandTransition()
        t.open(style: .spring, at: 10)
        t.advance(to: 10)
        t.advance(to: 10.125)
        t.advance(to: 10.41)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.needsFrames, "the overshoot is still settling")
        XCTAssertGreaterThan(t.progress(at: 10.41), 1)
        t.advance(to: 10.7)
        XCTAssertFalse(t.needsFrames)
        XCTAssertEqual(t.progress(at: 10.7), 1)
        XCTAssertEqual(t.progress(at: 20), 1)
    }

    // MARK: Close

    func testACloseFadesTheContentOutBeforeTheShapeShrinks() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 2)
        XCTAssertEqual(t.phase, .closing)
        XCTAssertFalse(t.isOpen)
        XCTAssertFalse(t.stage.contentShown)
        XCTAssertEqual(t.stage.contentFade, IslandMotion.Fade(duration: 0.10, curve: .easeOut))
        XCTAssertFalse(t.stage.interactive, "from the first frame of a close")
        XCTAssertTrue(t.stage.islandShown)
        t.advance(to: 2.095)
        XCTAssertEqual(t.progress(at: 2.095), 1, "the shape waits for the content")
        t.advance(to: 2.105)
        XCTAssertEqual(t.progress(at: 2.2), 1 + IslandMotion.close.value(target: -1.0, time: 2.2 - 2.1), accuracy: 1e-6)
        XCTAssertEqual(t.progress(at: 2.2), 0.5078, accuracy: 0.001)
    }

    func testTheIslandIsClosedOnceTheShapeIsBackAtTheNotch() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 2)
        t.advance(to: 2.105)
        t.advance(to: 2.6)
        XCTAssertEqual(t.phase, .closing)
        XCTAssertTrue(t.needsFrames)
        t.advance(to: 2.8)
        XCTAssertEqual(t.phase, .closed)
        XCTAssertEqual(t.stage, .closed)
        XCTAssertEqual(t.progress(at: 2.8), 0)
        XCTAssertFalse(t.needsFrames)
    }

    // MARK: Interrupt

    func testACloseDuringTheOpenTurnsTheShapeAroundFromWhereItIs() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0.05)
        let before = t.progress(at: 0.05)
        t.close(style: .spring, at: 0.05)
        XCTAssertEqual(t.progress(at: 0.05), before, accuracy: 1e-12, "no jump")
        XCTAssertEqual(before, 0.1852, accuracy: 0.001)
        XCTAssertGreaterThan(t.progress(at: 0.06), before, "it carries its speed a moment before it turns")
        t.advance(to: 0.55)
        XCTAssertEqual(t.phase, .closing)
        t.advance(to: 0.65)
        XCTAssertEqual(t.phase, .closed)
    }

    func testAReopenDuringTheShrinkTurnsTheShapeAroundAndTheContentWaitsItsTurn() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 1)
        t.advance(to: 1.105)
        t.advance(to: 1.3)
        let before = t.progress(at: 1.3)
        XCTAssertEqual(before, 0.1578, accuracy: 0.001)
        t.open(style: .spring, at: 1.3)
        XCTAssertEqual(t.progress(at: 1.3), before, accuracy: 1e-12, "no jump")
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 1.415)
        XCTAssertFalse(t.stage.contentShown)
        t.advance(to: 1.425)
        XCTAssertTrue(t.stage.contentShown)
        t.advance(to: 1.7)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 1.71)
        XCTAssertEqual(t.phase, .open)
    }

    func testAReopenBeforeTheShapeShrinksBringsTheContentStraightBack() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 1)
        t.advance(to: 1.05)
        t.open(style: .spring, at: 1.05)
        t.advance(to: 1.05)
        XCTAssertTrue(t.stage.contentShown)
        XCTAssertEqual(t.stage.contentFade, IslandMotion.Fade(duration: 0.28, curve: .easeOut))
        XCTAssertEqual(t.progress(at: 1.2), 1, accuracy: 1e-12, "the shape never left")
        t.advance(to: 1.325)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 1.335)
        XCTAssertEqual(t.phase, .open)
    }

    // MARK: Stale completions and literal time

    func testAContentInFromAnOpenThatWasClosedNeverRevivesTheContent() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0.05)
        t.close(style: .spring, at: 0.05)
        for time in [0.12, 0.125, 0.2, 0.4, 0.405, 0.5] {
            t.advance(to: time)
            XCTAssertFalse(t.stage.contentShown, "\(time)")
            XCTAssertFalse(t.stage.interactive, "\(time)")
            XCTAssertNotEqual(t.phase, .open, "\(time)")
        }
    }

    func testACloseThatWasReversedNeverEndsTheReopenedIsland() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 1)
        t.advance(to: 1.105)
        t.advance(to: 1.3)
        t.open(style: .spring, at: 1.3)
        // The interrupted close would have had its shape back at the notch by 1.71.
        for time in [1.5, 1.71, 1.8, 2.0] {
            t.advance(to: time)
            XCTAssertNotEqual(t.phase, .closed, "\(time)")
        }
        XCTAssertEqual(t.phase, .open)
        XCTAssertEqual(t.progress(at: 2.0), 1, accuracy: 0.001)
    }

    func testAFrameFromBeforeTheLastChangeChangesNothing() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 1)
        let closing = t
        t.advance(to: 0.99)
        XCTAssertEqual(t, closing)
    }

    func testAnOverdueShrinkIsHonouredWhetherOrNotAFrameCameFirst() {
        var withFrame = openIsland(at: 0)
        withFrame.close(style: .spring, at: 1)
        withFrame.advance(to: 1.105)
        withFrame.open(style: .spring, at: 1.3)
        var withoutFrame = openIsland(at: 0)
        withoutFrame.close(style: .spring, at: 1)
        withoutFrame.open(style: .spring, at: 1.3)
        XCTAssertEqual(withFrame, withoutFrame)
        XCTAssertEqual(withoutFrame.progress(at: 1.3), 0.1578, accuracy: 0.001, "it had been shrinking since 1.1")
        withoutFrame.advance(to: 1.415)
        XCTAssertFalse(withoutFrame.stage.contentShown, "the shape was shrinking: the content waits its head start")
    }

    func testOpeningAnOpenIslandOrClosingAClosedOneChangesNothing() {
        var open = openIsland(at: 0)
        let before = open
        open.open(style: .spring, at: 2)
        XCTAssertEqual(open, before)
        var closed = IslandTransition()
        closed.close(style: .spring, at: 2)
        XCTAssertEqual(closed, IslandTransition())
        var closing = openIsland(at: 0)
        closing.close(style: .spring, at: 2)
        let once = closing
        closing.close(style: .spring, at: 2.05)
        XCTAssertEqual(closing, once, "a second close does not restart the first")
    }

    // MARK: The panel

    func testThePanelsContentFadesInAtOnceWithNoShapeToWaitFor() {
        var t = IslandTransition()
        t.open(style: .contentOnly, at: 0)
        t.advance(to: 0)
        XCTAssertTrue(t.stage.contentShown)
        XCTAssertEqual(t.stage.contentFade, IslandMotion.Fade(duration: 0.28, curve: .easeOut))
        XCTAssertTrue(t.stage.islandShown)
        XCTAssertEqual(t.progress(at: 0), 1, "the panel's shape is its body from the start")
        t.advance(to: 0.275)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 0.285)
        XCTAssertEqual(t.phase, .open)
        XCTAssertTrue(t.stage.interactive)
        XCTAssertFalse(t.needsFrames)
    }

    func testThePanelIsClosedOnceItsContentHasFadedOut() {
        var t = openIsland(at: 0, style: .contentOnly)
        t.close(style: .contentOnly, at: 1)
        XCTAssertFalse(t.stage.contentShown)
        XCTAssertEqual(t.stage.contentFade, IslandMotion.Fade(duration: 0.10, curve: .easeOut))
        t.advance(to: 1.095)
        XCTAssertEqual(t.phase, .closing)
        t.advance(to: 1.105)
        XCTAssertEqual(t.phase, .closed)
    }

    // MARK: Reduce Motion

    func testReduceMotionCrossFadesTheWholeIslandInAtFullSize() {
        var t = IslandTransition()
        t.open(style: .crossFade, at: 0)
        t.advance(to: 0)
        XCTAssertEqual(t.progress(at: 0), 1, "no spring: the island is at its open size")
        XCTAssertTrue(t.stage.islandShown)
        XCTAssertEqual(t.stage.islandFade, IslandMotion.Fade(duration: 0.15, curve: .linear))
        XCTAssertTrue(t.stage.contentShown)
        XCTAssertNil(t.stage.contentFade, "the content comes with the island, not after it")
        t.advance(to: 0.145)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 0.155)
        XCTAssertEqual(t.phase, .open)
        XCTAssertFalse(t.needsFrames)
    }

    func testReduceMotionClosesWithTheSameCrossFade() {
        var t = openIsland(at: 0, style: .crossFade)
        t.close(style: .crossFade, at: 1)
        XCTAssertFalse(t.stage.islandShown)
        XCTAssertEqual(t.stage.islandFade, IslandMotion.Fade(duration: 0.15, curve: .linear))
        XCTAssertTrue(t.stage.contentShown, "the content leaves with the island")
        XCTAssertFalse(t.stage.interactive)
        XCTAssertEqual(t.progress(at: 1.1), 1, "nothing shrinks")
        t.advance(to: 1.145)
        XCTAssertEqual(t.phase, .closing)
        t.advance(to: 1.155)
        XCTAssertEqual(t.phase, .closed)
    }

    func testACrossFadeCloseFreezesTheShapeWhereItIs() {
        var t = IslandTransition()
        t.open(style: .spring, at: 0)
        t.advance(to: 0.05)
        let before = t.progress(at: 0.05)
        // Reduce Motion turned on while the spring was still under way.
        t.close(style: .crossFade, at: 0.05)
        XCTAssertEqual(t.progress(at: 0.05), before, accuracy: 1e-12)
        XCTAssertEqual(t.progress(at: 0.15), before, accuracy: 1e-12, "it does not grow while it fades")
        XCTAssertFalse(t.stage.islandShown)
        t.advance(to: 0.195)
        XCTAssertEqual(t.phase, .closing)
        t.advance(to: 0.205)
        XCTAssertEqual(t.phase, .closed)
    }

    func testAReopenDuringAReducedMotionCloseFadesBackIn() {
        var t = openIsland(at: 0, style: .crossFade)
        t.close(style: .crossFade, at: 1)
        t.open(style: .crossFade, at: 1.05)
        t.advance(to: 1.05)
        XCTAssertTrue(t.stage.islandShown)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 1.195)
        XCTAssertEqual(t.phase, .opening)
        t.advance(to: 1.205)
        XCTAssertEqual(t.phase, .open)
    }

    // MARK: Routes and reset

    func testAnOpenFromClosedIsFreshAndAClosingIslandOnItsDisplayTurnsAround() {
        XCTAssertEqual(IslandTransition.route(phase: .closed, sameDisplay: true), .fresh)
        XCTAssertEqual(IslandTransition.route(phase: .closed, sameDisplay: false), .fresh)
        XCTAssertEqual(IslandTransition.route(phase: .closing, sameDisplay: true), .reverse)
        XCTAssertEqual(IslandTransition.route(phase: .closing, sameDisplay: false), .moveAndOpen)
        XCTAssertEqual(IslandTransition.route(phase: .opening, sameDisplay: false), .moveAndOpen)
        XCTAssertEqual(IslandTransition.route(phase: .open, sameDisplay: false), .moveAndOpen)
        XCTAssertEqual(IslandTransition.route(phase: .open, sameDisplay: true), .moveAndOpen)
    }

    func testAResetClosesAtOnceFromAnyPhase() {
        var opening = IslandTransition()
        opening.open(style: .spring, at: 0)
        opening.advance(to: 0.2)
        opening.reset()
        XCTAssertEqual(opening, IslandTransition())
        var closing = openIsland(at: 0, style: .contentOnly)
        closing.close(style: .contentOnly, at: 1)
        closing.reset()
        XCTAssertEqual(closing, IslandTransition())
    }

    // MARK: The keyboard

    func testAnEntryThatGivesKeyTakesItAndOneThatDoesNotHandsItBack() {
        XCTAssertEqual(IslandTransition.keyAction(entryBecomesKey: true, islandIsKey: false), .makeKey)
        XCTAssertEqual(IslandTransition.keyAction(entryBecomesKey: true, islandIsKey: true), .makeKey)
        XCTAssertEqual(IslandTransition.keyAction(entryBecomesKey: false, islandIsKey: false), .orderFront)
        XCTAssertEqual(
            IslandTransition.keyAction(entryBecomesKey: false, islandIsKey: true), .handBack,
            "an ear turning a key island around gives the keyboard back to the app behind"
        )
    }

    // MARK: Keys

    func testOnlyAClosingIslandSwallowsKeysAndOnlyItsOwn() {
        var t = IslandTransition()
        XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "closed")
        t.open(style: .spring, at: 0)
        t.advance(to: 0.05)
        XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "opening: Esc still closes")
        t.advance(to: 0.125)
        t.advance(to: 1)
        XCTAssertFalse(t.swallowsKey(inIsland: true, command: false), "open")
        t.close(style: .spring, at: 1)
        XCTAssertTrue(t.swallowsKey(inIsland: true, command: false), "closing")
        XCTAssertFalse(t.swallowsKey(inIsland: false, command: false), "another window's keys are its own")
    }

    func testACommandKeyPassesWhileTheIslandCloses() {
        var t = openIsland(at: 0)
        t.close(style: .spring, at: 2)
        XCTAssertTrue(t.swallowsKey(inIsland: true, command: false), "Esc or typing: swallowed")
        XCTAssertFalse(t.swallowsKey(inIsland: true, command: true), "⌘Q and other shortcuts go on")
    }
}
