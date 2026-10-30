import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Animate only when" (island open ∧ window not occluded ∧
/// display awake ∧ screen not locked ∧ Reduce Motion off), § 3.8, and § 3.5 "Jump from the island":
/// what the island tells the pet — its phase, the habitat on screen, its window, the display, the
/// lock, Reduce Motion — published only on a change and moving the pet's visible clock at that
/// very moment, with no view in between (Codex review 4); and which jump's landing may close the
/// island: the latest of the same open (Codex review 3).
@MainActor
final class IslandPetModelTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0

    private func makeModel(at clock: @escaping @MainActor () -> Date = { PetRuntimeFixture.t0 }) -> IslandPetModel {
        IslandPetModel(keeper: PetKeeper(random: PetRandomFixture.sequence([0])), clock: clock)
    }

    /// Open, its habitat drawn, its window on screen.
    private func onScreen(_ model: IslandPetModel) {
        model.show(phase: .open)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
    }

    func testThePetAnimatesOnlyOnceTheIslandIsOpenAndItsHabitatOnScreen() {
        let model = makeModel()
        XCTAssertFalse(model.animates, "at launch: closed")
        model.show(phase: .opening)
        model.setHabitatShown(true)
        model.setWindowVisible(true)
        XCTAssertFalse(model.animates, "not while the shape grows and the content fades in")
        model.show(phase: .open)
        XCTAssertTrue(model.animates)
        model.setHabitatShown(false)
        XCTAssertFalse(model.animates, "a screen too narrow for the habitat")
        model.setHabitatShown(true)
        model.show(phase: .closing)
        XCTAssertFalse(model.animates, "not while it closes")
    }

    func testTheLockTheDisplayTheWindowAndReduceMotionEachStopIt() {
        let model = makeModel()
        onScreen(model)
        XCTAssertTrue(model.animates)
        model.setScreenLocked(true)
        XCTAssertFalse(model.animates, "locked")
        model.setScreenLocked(false)
        model.setDisplayAwake(false)
        XCTAssertFalse(model.animates, "display asleep")
        model.setDisplayAwake(true)
        model.setWindowVisible(false)
        XCTAssertFalse(model.animates, "window occluded")
        model.setWindowVisible(true)
        model.setReduceMotion(true)
        XCTAssertFalse(model.animates, "Reduce Motion")
        model.setReduceMotion(false)
        XCTAssertTrue(model.animates)
    }

    func testOnlyAChangePublishes() {
        let model = makeModel()
        var sends = 0
        let watching = model.objectWillChange.sink { sends += 1 }
        model.show(phase: .open)
        model.show(phase: .open)
        model.show(phase: .closing)
        XCTAssertEqual(sends, 2, "open, then not open")
        model.setDisplayAwake(true)
        model.setScreenLocked(false)
        model.setWindowVisible(false)
        model.setHabitatShown(false)
        model.setReduceMotion(false)
        XCTAssertEqual(sends, 2, "the values they already had")
        model.setHabitatShown(true)
        XCTAssertEqual(sends, 3)
        withExtendedLifetime(watching) {}
    }

    func testSleepAndTheLockStopTheVisibleClockAtOnceWithNoViewInBetween() {
        var now = t0
        let model = makeModel(at: { now })
        onScreen(model)
        XCTAssertTrue(model.keeper.isAnimating)
        now = t0 + 10
        model.setDisplayAwake(false)
        XCTAssertFalse(model.keeper.isAnimating)
        now = t0 + 3_610
        model.setDisplayAwake(true)
        XCTAssertTrue(model.keeper.isAnimating)
        XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: t0 + 3_610), 10, "an hour asleep added nothing")
        now = t0 + 3_620
        model.setScreenLocked(true)
        now = t0 + 7_220
        model.setScreenLocked(false)
        XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: t0 + 7_220), 20, "an hour locked added nothing")
    }

    func testClosingStopsTheVisibleClockOnItsFirstFrame() {
        var now = t0
        let model = makeModel(at: { now })
        onScreen(model)
        now = t0 + 5
        model.show(phase: .closing)
        XCTAssertFalse(model.keeper.isAnimating)
        XCTAssertEqual(model.keeper.runtime.clock.visibleTime(at: t0 + 100), 5)
    }

    func testAJumpThatLandedClosesTheIslandOnce() {
        let model = makeModel()
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let landed = model.jumpStarted()
        landed()
        XCTAssertEqual(closes, 1)
        landed()
        XCTAssertEqual(closes, 1, "a landing closes once")
    }

    func testAJumpFromAnEarlierOpenNeverClosesTheReopenedIsland() {
        let model = makeModel()
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let old = model.jumpStarted()
        model.islandClosed()
        model.islandOpened()
        old()
        XCTAssertEqual(closes, 0, "dismissed and reopened before it landed: the island stays open")
    }

    func testOnlyTheNewestJumpsLandingCloses() {
        let model = makeModel()
        var closes = 0
        model.closeIsland = { closes += 1 }
        model.islandOpened()
        let first = model.jumpStarted()
        let second = model.jumpStarted()
        first()
        XCTAssertEqual(closes, 0, "a newer jump is pending")
        second()
        XCTAssertEqual(closes, 1)
    }
}
