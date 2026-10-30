import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5, "Owner 2026-10-30 (events)", "Animate only when": the keeper
/// hands its runtime the pet's events, a gate-off (close, sleep, lock, Reduce Motion) drops a running
/// one, and in Debug it plays them by hand only while the gate is on.
@MainActor
final class PetKeeperEventTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let climb = [PetEventFixture.climb]

    private func presentation(_ mood: PetMood) -> PetMoodPresentation {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return PetMoodRules.presentation(
            of: mood, petName: "Cat", mode: .used, now: t0, calendar: calendar, locale: Locale(identifier: "en_GB")
        )
    }

    private func frame(
        _ keeper: PetKeeper, _ seconds: TimeInterval, _ mood: PetMood = .idle, events: [PetEvent] = PetEventFixture.both,
        liftRoom: Int = PetContract.eventMaxLift
    ) -> PetFrame? {
        keeper.frame(
            at: t0 + seconds, presentation: presentation(mood),
            animations: PetRuntimeFixture.animations, roamBeads: PetRuntimeFixture.roam, events: events, liftRoom: liftRoom
        )
    }

    func testTheFramePlaysThePetsEventsAtADueSlot() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        keeper.setAnimating(true, at: t0)
        XCTAssertNil(frame(keeper, 0, events: climb)?.bit)
        XCTAssertEqual(frame(keeper, 2, events: climb)?.bit, .event("climb"))
        XCTAssertEqual(frame(keeper, 2.125, events: climb)?.yBeads, 2)
    }

    func testTheFramePassesTheColumnsRoom() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        let events = [PetEventFixture.climb80]
        keeper.setAnimating(true, at: t0)
        _ = frame(keeper, 0, events: events, liftRoom: 22)
        _ = frame(keeper, 2, events: events, liftRoom: 22)
        XCTAssertEqual(frame(keeper, 3.25, events: events, liftRoom: 22)?.yBeads, 22)
    }

    func testAGateOffDropsARunningEventAndTheNextOpenIsOnTheFloor() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        keeper.setAnimating(true, at: t0)
        _ = frame(keeper, 0, events: climb)
        _ = frame(keeper, 2, events: climb)
        XCTAssertEqual(frame(keeper, 2.375, events: climb)?.yBeads, 6)
        keeper.setAnimating(false, at: t0 + 2.4)
        XCTAssertNil(frame(keeper, 2.5, events: climb))
        keeper.setAnimating(true, at: t0 + 300)
        let open = frame(keeper, 300.1, events: climb)
        XCTAssertNil(open?.bit)
        XCTAssertEqual(open?.yBeads, 0)
    }

    #if DEBUG
    func testAHandPlayStartsOnTheNextFrameWhateverTheMood() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        keeper.setAnimating(true, at: t0)
        XCTAssertTrue(keeper.play(eventID: "climb"))
        XCTAssertEqual(frame(keeper, 0.5, .nothingOn)?.bit, .event("climb"), "asleep, in the quiet start")
    }

    func testNothingIsHandPlayedWhileTheGateIsOff() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        XCTAssertFalse(keeper.play(eventID: "climb"), "Reduce Motion, for one")
        XCTAssertFalse(keeper.playAll(eventIDs: ["flat", "climb"]))
        keeper.setAnimating(true, at: t0)
        XCTAssertNil(frame(keeper, 0.5, .nothingOn)?.bit)
    }

    func testPlayAllGoesInOrder() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        keeper.setAnimating(true, at: t0)
        XCTAssertTrue(keeper.playAll(eventIDs: ["flat", "climb"]))
        XCTAssertEqual(frame(keeper, 0.5, .nothingOn)?.bit, .event("flat"))
        XCTAssertEqual(frame(keeper, 2, .nothingOn)?.bit, .event("climb"))
    }

    func testDroppingEventsEndsARunningOne() {
        let keeper = PetKeeper(random: PetRandom { 0 })
        keeper.setAnimating(true, at: t0)
        keeper.play(eventID: "climb")
        XCTAssertEqual(frame(keeper, 0.5, .nothingOn)?.bit, .event("climb"))
        keeper.dropEvents()
        XCTAssertNil(frame(keeper, 0.625, .nothingOn)?.bit)
    }
    #endif
}
