import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Jump from the island, § 3.6, plan ruling R6, Codex's plan review
/// 3: a jump from an ear may answer late. Landed or not, its answer counts only while no newer jump
/// started and the island has not opened or closed since, so a late failure never overrides a newer
/// open or reopens a dismissed island.
@MainActor
final class IslandPetModelEarJumpTests: XCTestCase {
    @MainActor
    private final class Log {
        var closes = 0
        var fallbacks = 0
    }

    private func make() -> (model: IslandPetModel, log: Log) {
        let log = Log()
        let model = IslandPetModel(keeper: PetKeeper(random: PetRandom { 0 }), clock: { PetRuntimeFixture.t0 })
        model.closeIsland = { log.closes += 1 }
        return (model, log)
    }

    private func start(_ model: IslandPetModel, _ log: Log) -> @MainActor @Sendable (Bool) -> Void {
        model.earJumpStarted(orElse: { log.fallbacks += 1 })
    }

    func testALandedJumpClosesAsAnyJumpDoes() {
        let (model, log) = make()
        start(model, log)(true)
        XCTAssertEqual(log.closes, 1)
        XCTAssertEqual(log.fallbacks, 0)
    }

    func testAFailedJumpFallsBack() {
        let (model, log) = make()
        start(model, log)(false)
        XCTAssertEqual(log.fallbacks, 1)
        XCTAssertEqual(log.closes, 0)
    }

    func testALateFailureAfterANewerOpenDoesNothing() {
        let (model, log) = make()
        let answer = start(model, log)
        model.islandOpened()
        answer(false)
        XCTAssertEqual(log.fallbacks, 0)
    }

    func testALateFailureAfterADismissalDoesNothing() {
        let (model, log) = make()
        let answer = start(model, log)
        model.islandClosed()
        answer(false)
        XCTAssertEqual(log.fallbacks, 0)
    }

    func testALateFailureAfterANewerJumpDoesNothing() {
        let (model, log) = make()
        let answer = start(model, log)
        _ = model.jumpStarted()
        answer(false)
        XCTAssertEqual(log.fallbacks, 0)
    }

    /// Codex's re-review, plan ruling R20: an ear on the island's own display stays, which calls no
    /// `islandOpened`; the verdict the controller switches on is what takes the ticket.
    func testAnEarOpenThatStaysVoidsAnOlderJumpsLateFailure() {
        let (model, log) = make()
        let answer = start(model, log)
        XCTAssertEqual(model.entryVerdict(.ear(displayID: 1), isOpen: true, openScreenID: 1, entryScreenID: 1), .stay)
        answer(false)
        XCTAssertEqual(log.fallbacks, 0)
    }

    func testAnEarOpenThatStaysVoidsAnOlderJumpsLanding() {
        let (model, log) = make()
        let answer = start(model, log)
        XCTAssertEqual(model.entryVerdict(.ear(displayID: 1), isOpen: true, openScreenID: 1, entryScreenID: 1), .stay)
        answer(true)
        XCTAssertEqual(log.closes, 0, "it opened on the user's newer word")
    }

    func testANotificationThatStaysLeavesAJumpAlone() {
        let (model, log) = make()
        let answer = start(model, log)
        XCTAssertEqual(
            model.entryVerdict(.notification(pointer: .zero), isOpen: true, openScreenID: 1, entryScreenID: 1), .stay
        )
        answer(false)
        XCTAssertEqual(log.fallbacks, 1)
    }
}
