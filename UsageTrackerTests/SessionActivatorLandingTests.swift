import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.5 "Jump from the island" and § 2 (`SessionActivator` ignored
/// the result of `activate(from:)` and assumed Omelette was the active app): from a non-activating
/// island the jump hands its activation on; when AppKit refuses, Omelette activates itself and
/// hands it on again only once it is actually active (Codex review 1); then the app in front is
/// checked, and only a jump that landed may close the island. A failure stays silent.
@MainActor
final class SessionActivatorLandingTests: XCTestCase {
    private let iTerm = AgentHostInfo(pid: 42, bundleID: "com.googlecode.iterm2", tty: nil)

    private func landing(
        on target: AgentHostInfo, fronts: [PresenceMonitor.Frontmost?]
    ) async -> (landed: Bool, waits: [TimeInterval]) {
        var fronts = fronts
        var waits: [TimeInterval] = []
        let landed = await SessionActivator.confirmLanding(
            on: target,
            frontmost: { fronts.count > 1 ? fronts.removeFirst() : fronts[0] },
            wait: { waits.append($0) }
        )
        return (landed, waits)
    }

    // MARK: - The hand-over

    func testAnActivationTakenAtOnceAsksNothingMore() async {
        var asked = 0
        var selfActivations = 0
        var waits: [TimeInterval] = []
        let result = await SessionActivator.bringForward(
            activate: {
                asked += 1
                return true
            },
            activateSelf: { selfActivations += 1 },
            selfIsActive: { false },
            wait: { waits.append($0) }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(selfActivations, 0)
        XCTAssertEqual(waits, [])
    }

    func testAfterARefusalTheHandOverWaitsUntilOmeletteIsActive() async {
        var events: [String] = []
        var active = false
        var looks = 0
        let result = await SessionActivator.bringForward(
            activate: {
                events.append(active ? "hand on, active" : "hand on, not active")
                return active
            },
            activateSelf: { events.append("activate self") },
            selfIsActive: {
                looks += 1
                if looks >= 3 { active = true }
                return active
            },
            wait: { events.append("wait \($0)") }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(
            events, ["hand on, not active", "activate self", "wait 0.05", "wait 0.05", "hand on, active"],
            "the second hand-over only once Omelette is active"
        )
    }

    func testOmeletteActiveAtTheFirstLookIsHandedOnWithoutWaiting() async {
        var answers = [false, true]
        var asked = 0
        var waits: [TimeInterval] = []
        let result = await SessionActivator.bringForward(
            activate: {
                asked += 1
                return answers.removeFirst()
            },
            activateSelf: {},
            selfIsActive: { true },
            wait: { waits.append($0) }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(waits, [])
    }

    func testOmeletteThatNeverBecomesActiveIsNotHandedOnAndTheJumpFails() async {
        var asked = 0
        var waits: [TimeInterval] = []
        let result = await SessionActivator.bringForward(
            activate: {
                asked += 1
                return false
            },
            activateSelf: {},
            selfIsActive: { false },
            wait: { waits.append($0) }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(asked, 1, "no second hand-over without an activation to hand on")
        XCTAssertEqual(waits, Array(repeating: 0.05, count: 10), "half a second at most")
    }

    // MARK: - The landing

    func testTheJumpLandsWhenTheSessionsAppIsInFrontAtTheFirstLook() async {
        let outcome = await landing(on: iTerm, fronts: [(pid: 42, bundleID: "com.googlecode.iterm2")])
        XCTAssertTrue(outcome.landed)
        XCTAssertEqual(outcome.waits, [0.3], "P0: the target was in front 300 ms after the request")
    }

    func testAnAppThatComesForwardLateStillLands() async {
        let outcome = await landing(
            on: iTerm,
            fronts: [(pid: 7, bundleID: "com.apple.Safari"), (pid: 42, bundleID: "com.googlecode.iterm2")]
        )
        XCTAssertTrue(outcome.landed)
        XCTAssertEqual(outcome.waits, [0.3, 0.3])
    }

    func testAnotherAppStillInFrontAfterTheLastLookIsAFailure() async {
        let outcome = await landing(on: iTerm, fronts: [(pid: 7, bundleID: "com.apple.Safari")])
        XCTAssertFalse(outcome.landed, "the island stays open")
        XCTAssertEqual(outcome.waits, [0.3, 0.3])
        let nobody = await landing(on: iTerm, fronts: [nil])
        XCTAssertFalse(nobody.landed)
    }

    func testThePidDecidesAndTheBundleIDOnlyWithoutOne() async {
        let anotherTerminal = await landing(
            on: AgentHostInfo(pid: 42, bundleID: "com.apple.Terminal", tty: nil),
            fronts: [(pid: 43, bundleID: "com.apple.Terminal")]
        )
        XCTAssertFalse(anotherTerminal.landed, "another Terminal process is not the session's")
        let finder = await landing(
            on: AgentHostInfo(pid: nil, bundleID: SessionActivator.finderBundleID, tty: nil),
            fronts: [(pid: 99, bundleID: "com.apple.finder")]
        )
        XCTAssertTrue(finder.landed, "the project folder in Finder")
        XCTAssertEqual(SessionActivator.finderBundleID, "com.apple.finder")
    }
}
