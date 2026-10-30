import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime: "One stretch per limit reset seen in a live
/// poll (deduplicated by window id + reset time; never on relaunch or a retained refresh)". The
/// stretch is a bit of the idle loop (Idle, and Agent working by the owner's ruling of
/// 2026-10-30): it takes the next due bit's slot (7–10 s of visible time after the last bit,
/// an open's first 2–4 s into it, never in an open's first 1.5 s), waits while the user is busy,
/// never plays in an alert or asleep, and resets seen together or while it waits make one
/// stretch (R22).
final class PetRuntimeStretchTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private var firstReset: Date { t0.addingTimeInterval(-3_600) }
    private var secondReset: Date { firstReset.addingTimeInterval(5 * 3_600) }

    private func claude(resetsAt: Date, state: ServiceState = .ok) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], state: state, at: t0)
    }

    /// A runtime that read the session window before its reset, then a live poll at `seenAt`
    /// showing the next one.
    private func runtimeThatSawAReset(at seenAt: Date, draws: [Double] = [0, 0.5]) -> PetRuntime {
        var runtime = PetRuntime(random: PetRandomFixture.sequence(draws))
        runtime.observe([claude(resetsAt: firstReset)], now: firstReset.addingTimeInterval(-60))
        runtime.observe([claude(resetsAt: secondReset)], now: seenAt)
        return runtime
    }

    private func tick(
        _ runtime: inout PetRuntime,
        _ seconds: TimeInterval,
        pose: PetPose = .idle,
        loops: Bool = true,
        activity: PetUserActivity = .none
    ) -> PetFrame {
        runtime.tick(
            at: t0 + seconds, pose: pose, loops: loops, activity: activity,
            animations: PetRuntimeFixture.animations, roamBeads: PetRuntimeFixture.roam
        )
    }

    func testALiveResetMakesThePetStretchOnceInTheNextBitsSlot() {
        var runtime = runtimeThatSawAReset(at: t0)
        XCTAssertEqual(runtime.stretchSeenAt, t0)
        XCTAssertNil(tick(&runtime, 0).bit)
        XCTAssertNil(tick(&runtime, 2.9).bit, "the slot is due at 3 s")
        let frame = tick(&runtime, 3)
        XCTAssertEqual(frame.bit, .stretch)
        XCTAssertEqual(frame.frame, "look")
        XCTAssertEqual(frame.fps, 1)
        XCTAssertEqual(tick(&runtime, 3.9).bit, .stretch)
        XCTAssertNil(tick(&runtime, 4.1).bit, "one look cycle: 1 s")
        XCTAssertNil(runtime.stretchSeenAt)
        XCTAssertNil(tick(&runtime, 8).bit, "once")
    }

    func testTheFirstReadingAfterALaunchAndRetainedReadingsBringNoStretch() {
        var relaunched = PetRuntime(random: PetRandomFixture.sequence([0.99]))
        relaunched.observe([claude(resetsAt: secondReset)], now: t0)
        XCTAssertNil(relaunched.stretchSeenAt, "a relaunch")
        var retained = PetRuntime(random: PetRandomFixture.sequence([0.99]))
        retained.observe([claude(resetsAt: firstReset)], now: firstReset.addingTimeInterval(-60))
        retained.observe([claude(resetsAt: secondReset, state: .notRunning)], now: t0)
        XCTAssertNil(retained.stretchSeenAt, "a retained refresh")
    }

    func testTheStretchWaitsForACalmMoodAndStopsWhenTheMoodMovesOn() {
        var runtime = runtimeThatSawAReset(at: t0)
        _ = tick(&runtime, 0, pose: .look, loops: false)
        XCTAssertNil(tick(&runtime, 3, pose: .look, loops: false).bit, "due, but an alert holds still")
        XCTAssertEqual(tick(&runtime, 4).bit, .stretch, "calm: idle, or agents working")
        XCTAssertNil(tick(&runtime, 4.5, pose: .sleep, loops: false).bit, "keep awake at night: the stretch stops")
    }

    func testTheStretchWaitsWhileTheUserIsBusy() {
        var runtime = runtimeThatSawAReset(at: t0)
        _ = tick(&runtime, 0)
        XCTAssertNil(tick(&runtime, 3, activity: PetUserActivity(fieldFocused: true)).bit)
        XCTAssertEqual(tick(&runtime, 4).bit, .stretch)
    }

    /// The owner's rulings of 2026-10-30: a reset seen while the island was closed is not let go
    /// after ten minutes; it takes the first slot of the next open, 2–4 s into it.
    func testAResetSeenWhileTheIslandWasClosedTakesTheNextOpensFirstSlot() {
        var runtime = runtimeThatSawAReset(at: t0)
        let threeHoursLater: TimeInterval = 3 * 3_600
        _ = tick(&runtime, threeHoursLater)
        XCTAssertEqual(runtime.stretchSeenAt, t0, "hours later the reset still waits")
        XCTAssertNil(tick(&runtime, threeHoursLater + 2.9).bit, "the open's first slot is due 3 s into it")
        XCTAssertEqual(tick(&runtime, threeHoursLater + 3).bit, .stretch)
        XCTAssertNil(runtime.stretchSeenAt, "once")
    }

    /// A later open too, with visible time already banked and a slot further off.
    func testAWaitingStretchTakesTheSlot2To4SecondsIntoTheNextOpen() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.5, 0.25]))
        runtime.observe([claude(resetsAt: firstReset)], now: firstReset.addingTimeInterval(-60))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 2).bit, .blink, "the first open's bit; the next slot 8.5 s on")
        runtime.pause(at: t0 + 3)
        runtime.observe([claude(resetsAt: secondReset)], now: t0 + 500)
        runtime.resume(at: t0 + 1_000)
        XCTAssertNil(tick(&runtime, 1_002.4).bit)
        XCTAssertEqual(tick(&runtime, 1_002.5).bit, .stretch)
    }

    func testAStretchTakesABitsSlotAndPutsTheNextOff() {
        var runtime = runtimeThatSawAReset(at: t0, draws: [0, 0.5, 0.5, 0, 0.5])
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 3).bit, .stretch)
        XCTAssertNil(tick(&runtime, 11.4).bit, "the stretch was this slot's bit")
        XCTAssertEqual(tick(&runtime, 11.5).bit, .walk)
    }

    func testAResetSeenDuringAWalkWaitsForTheNextSlot() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5, 0, 0.5]))
        runtime.observe([claude(resetsAt: firstReset)], now: firstReset.addingTimeInterval(-60))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 3).bit, .walk)
        runtime.observe([claude(resetsAt: secondReset)], now: t0 + 3.5)
        XCTAssertEqual(runtime.stretchSeenAt, t0 + 3.5)
        XCTAssertNil(tick(&runtime, 5.01).bit, "the walk was this slot's bit")
        XCTAssertNil(tick(&runtime, 11.4).bit)
        XCTAssertEqual(tick(&runtime, 11.5).bit, .stretch, "the next slot is the stretch's")
    }

    func testResetsSeenTogetherOrWhileAStretchWaitsMakeOneStretch() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5]))
        let weekEnds = t0.addingTimeInterval(5)
        func poll(session: Date, week: Date) -> [ServiceSnapshot] {
            [
                Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
                    Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: session, kind: .session),
                    Fixture.bucket(id: "seven_day", label: "All models", percent: 40, resetsAt: week, kind: .weekly),
                ], at: t0),
                Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [
                    Fixture.bucket(id: "codex_primary", label: "Current session", percent: 5, resetsAt: session, kind: .session),
                ], at: t0),
            ]
        }
        runtime.observe(poll(session: firstReset, week: weekEnds), now: firstReset.addingTimeInterval(-60))
        runtime.observe(poll(session: secondReset, week: weekEnds), now: t0)
        runtime.observe(poll(session: secondReset, week: weekEnds.addingTimeInterval(7 * 86_400)), now: t0 + 10)
        XCTAssertEqual(runtime.resets.reported.count, 3, "two resets in one poll, a third while the stretch waits: each reported once")
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 3).bit, .stretch)
        XCTAssertNil(tick(&runtime, 4.1).bit)
        XCTAssertEqual(tick(&runtime, 11.5).bit, .blink, "one stretch for the three resets; the next slot is an ordinary bit")
    }
}
