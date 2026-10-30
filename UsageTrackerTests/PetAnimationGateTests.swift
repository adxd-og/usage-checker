import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Animate only when": island open (transition state
/// `open`) ∧ window not occluded ∧ display awake ∧ screen not locked ∧ Reduce Motion off;
/// otherwise the still frame. § 3.8: collapsed, no timers and no wakeups; open, one
/// `TimelineView` at the mood's fps.
final class PetAnimationGateTests: XCTestCase {
    private let on = PetAnimationGate.Conditions(
        surfaceOpen: true, windowVisible: true, displayAwake: true, screenLocked: false, reduceMotion: false
    )

    func testThePetAnimatesOnlyWhenEveryConditionHolds() {
        var animating = 0
        for bits in 0..<32 {
            let conditions = PetAnimationGate.Conditions(
                surfaceOpen: bits & 1 != 0,
                windowVisible: bits & 2 != 0,
                displayAwake: bits & 4 != 0,
                screenLocked: bits & 8 != 0,
                reduceMotion: bits & 16 != 0
            )
            XCTAssertEqual(PetAnimationGate.animates(conditions), conditions == on, "\(conditions)")
            if PetAnimationGate.animates(conditions) { animating += 1 }
        }
        XCTAssertEqual(animating, 1)
    }

    func testOnlyAnOpenIslandCounts() {
        XCTAssertTrue(PetAnimationGate.islandOpen(.open))
        for phase in [IslandTransition.Phase.closed, .opening, .closing] {
            XCTAssertFalse(PetAnimationGate.islandOpen(phase), "\(phase)")
        }
    }

    func testWithTheGateOffThereIsNoTimelineAndOnItRunsAtTheAnimationsRate() {
        var off = on
        off.reduceMotion = true
        XCTAssertNil(PetAnimationGate.framePeriod(off, fps: 8))
        XCTAssertEqual(PetAnimationGate.framePeriod(on, fps: 2), 0.5)
        XCTAssertEqual(PetAnimationGate.framePeriod(on, fps: 8), 0.125)
        for fps in [0, -1, Double.nan, .infinity] {
            XCTAssertNil(PetAnimationGate.framePeriod(on, fps: fps), "\(fps)")
        }
    }
}
