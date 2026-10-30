import Combine
import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Runtime ("owned by the app, survives panel re-creation …
/// one stretch per limit reset seen in a live poll … never on relaunch"; no bit while the user is
/// busy) and § 3.8 (collapsed, no timers): the app's one pet runtime reads every published poll
/// from launch, starts and banks the visible open time on the gate, ticks only while the gate is
/// on (`tick` would resume a paused clock), reads the user's activity at each frame, and keeps a
/// pat's heart for a still pet.
@MainActor
final class PetKeeperTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0
    private let animations = PetRuntimeFixture.animations
    private let roam = PetRuntimeFixture.roam

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func presentation(_ mood: PetMood) -> PetMoodPresentation {
        PetMoodRules.presentation(
            of: mood, petName: "Cat", mode: .used, now: t0, calendar: utc, locale: Locale(identifier: "en_GB")
        )
    }

    private func frame(_ keeper: PetKeeper, _ seconds: TimeInterval, _ mood: PetMood = .idle) -> PetFrame? {
        keeper.frame(at: t0 + seconds, presentation: presentation(mood), animations: animations, roamBeads: roam)
    }

    private func claude(resetsAt: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
        ], at: t0)
    }

    func testWithItsGateOffTheKeeperNeverTicksTheRuntime() {
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0]))
        XCTAssertNil(frame(keeper, 0))
        XCTAssertFalse(keeper.runtime.clock.isRunning, "a tick would have resumed the visible clock")
        XCTAssertEqual(keeper.runtime.clock.visibleTime(at: t0 + 100), 0)
    }

    func testTheGateOnStartsTheVisibleClockAndOffBanksIt() {
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0]))
        keeper.setAnimating(true, at: t0)
        XCTAssertTrue(keeper.isAnimating)
        XCTAssertTrue(keeper.runtime.clock.isRunning)
        XCTAssertEqual(frame(keeper, 0.25)?.frame, "idle_1")
        XCTAssertEqual(frame(keeper, 0.75)?.frame, "idle_2")
        keeper.setAnimating(false, at: t0 + 10)
        XCTAssertFalse(keeper.runtime.clock.isRunning)
        XCTAssertNil(frame(keeper, 11))
        XCTAssertEqual(keeper.runtime.clock.visibleTime(at: t0 + 100), 10, "ten seconds on screen, nothing after")
    }

    func testEveryPublishedPollReachesTheResetWatchFromLaunch() {
        var now = t0.addingTimeInterval(-3_660)
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0]), clock: { now })
        let polls = PassthroughSubject<[ServiceSnapshot], Never>()
        keeper.watch(polls)
        let reset = t0.addingTimeInterval(-3_600)
        polls.send([claude(resetsAt: reset)])
        XCTAssertNil(keeper.runtime.stretchSeenAt, "the first reading after a launch only records")
        now = t0
        polls.send([claude(resetsAt: reset.addingTimeInterval(5 * 3_600))])
        XCTAssertEqual(keeper.runtime.stretchSeenAt, t0, "a reset in a poll, with the island closed")
    }

    func testTheUsersActivityIsReadAtEachFrame() {
        var activity = PetUserActivity(pointerOverContent: true)
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0, 0, 0]))
        keeper.activity = { activity }
        keeper.setAnimating(true, at: t0)
        XCTAssertNil(frame(keeper, 2)?.bit, "a bit is due, but the pointer is over the numbers")
        activity = .none
        XCTAssertEqual(frame(keeper, 2.5)?.bit, .walk)
    }

    func testAMoodThatHoldsStillGetsItsPoseAndNoBit() {
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0, 0]))
        keeper.setAnimating(true, at: t0)
        XCTAssertEqual(frame(keeper, 0.25, .nothingOn)?.frame, "sleep_1")
        XCTAssertNil(frame(keeper, 30, .nothingOn)?.bit, "nothing on: asleep, no bits")
    }

    func testAPatShowsTheHeartForAStillPetToo() {
        let keeper = PetKeeper(random: PetRandomFixture.sequence([0]))
        keeper.pat(at: t0)
        XCTAssertTrue(keeper.showsHeart(at: t0 + 1))
        XCTAssertFalse(keeper.showsHeart(at: t0 + 1.25))
    }
}
