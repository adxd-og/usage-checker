import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.4 and § 3.8: a tile is a button VoiceOver reads with its
/// numbers and, while an agent waits, the dot drawn for the eye ("…, an agent needs you"; P3a
/// ledger: the dot never reached VoiceOver), with "Opens details" as its hint; under the
/// pointer it rises a point and shows its chevron, which keyboard focus shows too.
final class OMProviderTileNavigationTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)

    func testATileReadsItsNameAndNumbersAsBefore() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: session),
            "Claude, Current session 42 percent used"
        )
    }

    func testAWaitingAgentReachesVoiceOver() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: session, waiting: true),
            "Claude, Current session 42 percent used, an agent needs you"
        )
    }

    func testARetainedTileSaysItsNumbersAreOldAndThatAnAgentWaits() {
        let service = Fixture.snapshot(
            id: "codex", displayName: "Codex", buckets: [session],
            state: .notRunning, stateMessage: "Codex isn't running"
        )
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: session, waiting: true),
            "Codex, Current session 42 percent used, last known, Not running, an agent needs you"
        )
    }

    func testATileWithNothingToShowStillSaysAnAgentWaits() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [], state: .notSignedIn)
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: nil, waiting: true),
            "Codex, Sign in, an agent needs you"
        )
    }

    func testUnderThePointerTheTileRisesOnePoint() {
        XCTAssertEqual(OMProviderTile.hoverLift, 1)
        XCTAssertEqual(OMProviderTile.liftOffset(hovering: true), -1)
        XCTAssertEqual(OMProviderTile.liftOffset(hovering: false), 0)
    }

    func testTheChevronShowsUnderThePointerOrWithKeyboardFocus() {
        XCTAssertTrue(OMProviderTile.showsChevron(hovering: true, focused: false))
        XCTAssertTrue(OMProviderTile.showsChevron(hovering: false, focused: true))
        XCTAssertFalse(OMProviderTile.showsChevron(hovering: false, focused: false))
    }
}
