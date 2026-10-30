import XCTest
@testable import Omelette

/// Verifier for notch-island spec 2026-10-29 § 3.5 "Jump from the island": the hand-over to the
/// session's app after a refusal, to the half second, and the landing looks at +0.3 s and +0.6 s.
@MainActor
final class SessionActivatorLandingVerificationTests: XCTestCase {
    private let iTerm = AgentHostInfo(pid: 42, bundleID: "com.googlecode.iterm2", tty: nil)

    /// A refused hand-over, Omelette active on the `n`th look: how it ends.
    private func afterARefusal(
        activeOnLook n: Int?, secondHandOver: Bool
    ) async -> (result: Bool, events: [String]) {
        var events: [String] = []
        var looks = 0
        var handOvers = 0
        let result = await SessionActivator.bringForward(
            activate: {
                handOvers += 1
                events.append("hand over \(handOvers)")
                return handOvers == 1 ? false : secondHandOver
            },
            activateSelf: { events.append("self") },
            selfIsActive: {
                looks += 1
                events.append("look \(looks)")
                guard let n else { return false }
                return looks >= n
            },
            wait: { events.append("wait \($0)") }
        )
        return (result, events)
    }

    func testTheSecondHandOverBeingRefusedToo_TheJumpFails() async {
        let outcome = await afterARefusal(activeOnLook: 1, secondHandOver: false)
        XCTAssertFalse(outcome.result, "Omelette was active but the activation still did not pass: no landing to confirm")
        XCTAssertEqual(outcome.events, ["hand over 1", "self", "look 1", "look 2", "hand over 2"])
    }

    func testOmeletteActiveOnlyAfterTheLastWaitIsStillHandedOnAtTheEndOfTheHalfSecond() async {
        // looks: 10 inside the loop (each followed by a wait) and one more after it.
        let outcome = await afterARefusal(activeOnLook: 11, secondHandOver: true)
        XCTAssertTrue(outcome.result)
        XCTAssertEqual(outcome.events.filter { $0.hasPrefix("wait") }.count, 10)
        XCTAssertEqual(outcome.events.last, "hand over 2")
        XCTAssertEqual(outcome.events.filter { $0 == "self" }.count, 1, "Omelette asks for its own activation once")
    }

    func testOmeletteActivatesItselfBeforeItWaitsAndBeforeTheSecondHandOver() async {
        let outcome = await afterARefusal(activeOnLook: 3, secondHandOver: true)
        XCTAssertEqual(
            outcome.events,
            ["hand over 1", "self", "look 1", "wait 0.05", "look 2", "wait 0.05", "look 3", "look 4", "hand over 2"]
        )
    }

    func testNeverActiveWaitsTheWholeHalfSecondAndOnlyThenGivesUp() async {
        let outcome = await afterARefusal(activeOnLook: nil, secondHandOver: true)
        XCTAssertFalse(outcome.result)
        XCTAssertEqual(outcome.events.filter { $0.hasPrefix("hand over") }.count, 1)
        XCTAssertEqual(outcome.events.filter { $0.hasPrefix("wait") }.count, 10)
        XCTAssertEqual(outcome.events.last, "look 11", "one last look after the last wait")
    }

    /// The landing looks at 0.3 s and 0.6 s of simulated time: an app in front by a look lands, one
    /// that comes forward after the last look does not.
    func testTheLandingIsJudgedOnlyAtPlusPoint3AndPlusPoint6() async {
        for (frontAt, expected) in [(0.0, true), (0.29, true), (0.3, true), (0.45, true), (0.6, true), (0.61, false)] as [(Double, Bool)] {
            var clock = 0.0
            let landed = await SessionActivator.confirmLanding(
                on: iTerm,
                frontmost: { clock >= frontAt ? (pid: 42, bundleID: "com.googlecode.iterm2") : (pid: 7, bundleID: "com.apple.Safari") },
                wait: { clock += $0 }
            )
            XCTAssertEqual(landed, expected, "target in front from \(frontAt) s")
            XCTAssertLessThanOrEqual(clock, 0.6 + 1e-9, "never waits past 0.6 s")
        }
    }

    func testAnAppThatCameForwardAndLeftAgainBeforeTheFirstLookIsNotALanding() async {
        var looks = 0
        let landed = await SessionActivator.confirmLanding(
            on: iTerm,
            frontmost: {
                looks += 1
                return (pid: 7, bundleID: "com.apple.Safari")
            },
            wait: { _ in }
        )
        XCTAssertFalse(landed)
        XCTAssertEqual(looks, 2, "two looks, no more")
    }
}
