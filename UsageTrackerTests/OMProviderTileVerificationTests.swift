import XCTest
@testable import Omelette

/// Verifier pass for notch-island spec 2026-10-29 § 3.4 and § 3.8 (a tile is a button VoiceOver
/// reads with its numbers, the waiting agent, and the hint "Opens details"): the tile's reading
/// over every state, display mode and presence of a hero, with and without a waiting agent. The
/// waiting phrase is added once, last, and only while an agent waits; everything before it is the
/// reading the tile always had.
final class OMProviderTileVerificationTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 42, kind: .session)

    func testTheWaitingPhraseComesOnceAndLastAndOnlyWhileAnAgentWaits() {
        let states: [ServiceState] = [.ok, .notSignedIn, .notRunning, .error]
        let modes: [PercentDisplay.Mode] = [.used, .remaining]
        for state in states {
            for mode in modes {
                for hero in [session, nil] {
                    let service = Fixture.snapshot(
                        id: "codex", displayName: "Codex", buckets: hero.map { [$0] } ?? [], state: state,
                        stateMessage: state == .ok ? nil : "message"
                    )
                    let quiet = OMProviderTile.accessibilityText(for: service, hero: hero, mode: mode, waiting: false)
                    let waiting = OMProviderTile.accessibilityText(for: service, hero: hero, mode: mode, waiting: true)
                    let tag = "\(state) \(mode) hero \(hero != nil)"
                    XCTAssertEqual(
                        OMProviderTile.accessibilityText(for: service, hero: hero, mode: mode), quiet, "the default is not waiting: \(tag)"
                    )
                    XCTAssertFalse(quiet.contains(IslandNavigationCopy.waitingPhrase), tag)
                    XCTAssertEqual(waiting, "\(quiet), an agent needs you", tag)
                    XCTAssertTrue(quiet.hasPrefix("Codex, "), tag)
                    if hero != nil {
                        XCTAssertTrue(quiet.contains("Current session"), tag)
                        XCTAssertEqual(quiet.contains("last known"), state != .ok, tag)
                    }
                }
            }
        }
    }

    func testAShownNumberIsSpokenInTheDisplayMode() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", buckets: [session])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: session, mode: .used, waiting: true),
            "Claude, Current session 42 percent used, an agent needs you"
        )
        XCTAssertTrue(
            OMProviderTile.accessibilityText(for: service, hero: session, mode: .remaining, waiting: true)
                .contains("58 percent"),
            "remaining mode speaks what is left"
        )
    }
}
