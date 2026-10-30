import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime: "One stretch per limit reset seen in a live
/// poll (deduplicated by window id + reset time; never on relaunch or a retained refresh)". The
/// stretch is a bit of the idle loop (Idle, and Agent working by the owner's ruling of
/// 2026-10-30): it takes the next due bit's slot (20–40 s of visible time after the last bit,
/// never in an open's first 1.5 s), waits while the user is busy, never plays in an alert or
/// asleep, and resets seen together or while it waits make one stretch (R22).
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
        XCTAssertNil(tick(&runtime, 19.5).bit, "the slot is due at 20 s")
        let frame = tick(&runtime, 20)
        XCTAssertEqual(frame.bit, .stretch)
        XCTAssertEqual(frame.frame, "look")
        XCTAssertEqual(frame.fps, 1)
        XCTAssertEqual(tick(&runtime, 20.9).bit, .stretch)
        XCTAssertNil(tick(&runtime, 21.1).bit, "one look cycle: 1 s")
        XCTAssertNil(runtime.stretchSeenAt)
        XCTAssertNil(tick(&runtime, 25).bit, "once")
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
        XCTAssertNil(tick(&runtime, 20, pose: .look, loops: false).bit, "due, but an alert holds still")
        XCTAssertEqual(tick(&runtime, 21).bit, .stretch, "calm: idle, or agents working")
        XCTAssertNil(tick(&runtime, 21.5, pose: .sleep, loops: false).bit, "keep awake at night: the stretch stops")
    }

    func testTheStretchWaitsWhileTheUserIsBusy() {
        var runtime = runtimeThatSawAReset(at: t0)
        _ = tick(&runtime, 0)
        XCTAssertNil(tick(&runtime, 20, activity: PetUserActivity(fieldFocused: true)).bit)
        XCTAssertEqual(tick(&runtime, 21).bit, .stretch)
    }

    func testAResetSeenLongAgoBringsNoStretchAndItsSlotGoesToAnOrdinaryBit() {
        var runtime = runtimeThatSawAReset(at: t0)
        _ = tick(&runtime, PetRuntime.stretchFreshness + 1)
        XCTAssertNil(runtime.stretchSeenAt)
        XCTAssertEqual(tick(&runtime, PetRuntime.stretchFreshness + 21).bit, .blink)
    }

    func testAStretchTakesABitsSlotAndPutsTheNextOff() {
        var runtime = runtimeThatSawAReset(at: t0, draws: [0, 0.5, 0, 0.5])
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .stretch)
        XCTAssertNil(tick(&runtime, 40).bit, "the stretch was this slot's bit")
        XCTAssertEqual(tick(&runtime, 50).bit, .walk)
    }

    func testAResetSeenDuringAWalkWaitsForTheNextSlot() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5]))
        runtime.observe([claude(resetsAt: firstReset)], now: firstReset.addingTimeInterval(-60))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .walk)
        runtime.observe([claude(resetsAt: secondReset)], now: t0 + 20.5)
        XCTAssertEqual(runtime.stretchSeenAt, t0 + 20.5)
        XCTAssertNil(tick(&runtime, 22.01).bit, "the walk was this slot's bit")
        XCTAssertNil(tick(&runtime, 49.9).bit)
        XCTAssertEqual(tick(&runtime, 50).bit, .stretch, "the next slot is the stretch's")
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
        XCTAssertEqual(tick(&runtime, 20).bit, .stretch)
        XCTAssertNil(tick(&runtime, 21.1).bit)
        XCTAssertEqual(tick(&runtime, 50).bit, .blink, "one stretch for the three resets; the next slot is an ordinary bit")
    }
}
