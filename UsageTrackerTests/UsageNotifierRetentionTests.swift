import XCTest
@testable import Omelette

/// Which services an alert may speak for. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Alerts:
/// both loops evaluate `state == .ok` services only; `lastFiredKey` is neither re-armed
/// nor cleared for a retained service." The notification centre is out of reach here,
/// so what is tested is the filter both loops share.
final class UsageNotifierRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testARetainedWindowPastItsResetNeverReachesTheAlerts() {
        // The report's scenario: a session window frozen at 85%, its old reset an hour
        // gone, fired "resets in 10m, currently 85%" for a window that had started over.
        let live = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "five_hour", percent: 20,
                                     resetsAt: now.addingTimeInterval(3600), kind: .session)],
            at: now
        )
        let retained = Fixture.snapshot(
            id: "antigravity",
            buckets: [Fixture.bucket(id: "antigravity_session", percent: 85,
                                     resetsAt: now.addingTimeInterval(-3600), kind: .session)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running",
            at: now.addingTimeInterval(-5 * 3600)
        )
        XCTAssertTrue(retained.isRetained)

        XCTAssertEqual(UsageNotifier.alertableServices([live, retained]).map(\.id), ["claude"])
    }

    func testAFailedServiceIsLeftOutWhateverItStillShows() {
        let signedOut = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, at: now)
        let erroring = Fixture.snapshot(
            id: "grok",
            buckets: [Fixture.bucket(id: "grok_credits", percent: 99, kind: .weekly)],
            state: .error, stateMessage: "500", at: now
        )
        XCTAssertTrue(UsageNotifier.alertableServices([signedOut, erroring]).isEmpty)
    }

    func testEveryLiveServiceStaysInPollOrder() {
        let claude = Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)], at: now
        )
        let codex = Fixture.snapshot(
            id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 10, kind: .session)], at: now
        )
        XCTAssertEqual(UsageNotifier.alertableServices([claude, codex]).map(\.id), ["claude", "codex"])
    }
}
