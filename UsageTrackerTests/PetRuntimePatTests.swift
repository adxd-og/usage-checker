import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 Mood rule row 7 ("Idle … a pat (♥ 1.2 s)"), D11 and
/// Runtime ("pat state"): a click on the idle pet puts a heart up for 1.2 s; a pat stops a
/// running bit and puts the next slot off, a waiting stretch's included; the heart shows only
/// while the idle loop runs (Idle, Agent working), and over a still pet too.
final class PetRuntimePatTests: XCTestCase {
    private let t0 = PetRuntimeFixture.t0

    private func tick(
        _ runtime: inout PetRuntime,
        _ seconds: TimeInterval,
        loops: Bool = true
    ) -> PetFrame {
        runtime.tick(
            at: t0 + seconds, pose: .idle, loops: loops, activity: .none,
            animations: PetRuntimeFixture.animations, roamBeads: PetRuntimeFixture.roam
        )
    }

    func testAPatShowsAHeartFor1Point2Seconds() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.99, 0.99]))
        XCTAssertFalse(tick(&runtime, 0).showsHeart)
        runtime.pat(at: t0 + 0.5)
        let frame = tick(&runtime, 0.6)
        XCTAssertTrue(frame.showsHeart)
        XCTAssertEqual(frame.frame, "idle_1", "it sits")
        XCTAssertNil(frame.bit)
        XCTAssertTrue(tick(&runtime, 1.65).showsHeart)
        XCTAssertFalse(tick(&runtime, 1.75).showsHeart)
    }

    func testAPatStopsARunningBitAndPutsTheNextOff() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0, 0.5, 0.5]))
        _ = tick(&runtime, 0)
        XCTAssertEqual(tick(&runtime, 20).bit, .walk)
        runtime.pat(at: t0 + 20.25)
        let frame = tick(&runtime, 20.3)
        XCTAssertNil(frame.bit)
        XCTAssertTrue(frame.showsHeart)
        XCTAssertEqual(runtime.clock.nextBitAt, 50.25, accuracy: 1e-9)
        XCTAssertNil(tick(&runtime, 50).bit)
        XCTAssertNotNil(tick(&runtime, 50.25).bit)
    }

    func testAPatPutsAWaitingStretchOffToTheNextSlot() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0, 0.5]))
        let reset = t0.addingTimeInterval(-3_600)
        func claude(_ resetsAt: Date) -> ServiceSnapshot {
            Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 3, resetsAt: resetsAt, kind: .session),
            ], at: t0)
        }
        runtime.observe([claude(reset)], now: reset.addingTimeInterval(-60))
        runtime.observe([claude(reset.addingTimeInterval(5 * 3_600))], now: t0)
        _ = tick(&runtime, 0)
        runtime.pat(at: t0 + 19.5)
        let frame = tick(&runtime, 20)
        XCTAssertNil(frame.bit, "the slot due at 20 s moved to 49.5 s")
        XCTAssertTrue(frame.showsHeart)
        XCTAssertNil(tick(&runtime, 49).bit)
        XCTAssertEqual(tick(&runtime, 49.5).bit, .stretch)
    }

    func testTheHeartGoesWhenTheMoodStopsLooping() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.99, 0.99]))
        _ = tick(&runtime, 0)
        runtime.pat(at: t0 + 0.5)
        XCTAssertFalse(tick(&runtime, 0.6, loops: false).showsHeart, "an alert came up")
    }

    func testAStillPetShowsTheHeartToo() {
        var runtime = PetRuntime(random: PetRandomFixture.sequence([0.99, 0.99]))
        runtime.pat(at: t0)
        XCTAssertTrue(runtime.showsHeart(at: t0 + 1))
        XCTAssertFalse(runtime.showsHeart(at: t0 + 1.25))
    }
}
