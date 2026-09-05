import XCTest
@testable import Omelette

/// VoiceOver can't see that a tile is dimmed, so the label has to say it.
final class OMProviderTileTextTests: XCTestCase {
    private let hero = Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62)

    func testALiveTileReadsAsItAlwaysDid() {
        let service = Fixture.snapshot(id: "claude", displayName: "Claude",
                                       buckets: [Fixture.bucket(id: "seven_day", label: "All models", percent: 55)])
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: service.buckets.first),
            "Claude, All models 55 percent used"
        )
    }

    func testARetainedTileSaysTheNumbersAreLastKnown() {
        let service = Fixture.snapshot(id: "antigravity", displayName: "Antigravity",
                                       buckets: [hero], state: .notRunning,
                                       stateMessage: "Antigravity isn't running")
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero),
            "Antigravity, Gemini models 62 percent used, last known, Not running"
        )
    }

    func testATileWithNothingToShowIsJustItsState() {
        let service = Fixture.snapshot(id: "codex", displayName: "Codex", buckets: [], state: .notSignedIn)
        XCTAssertEqual(OMProviderTile.accessibilityText(for: service, hero: nil), "Codex, Sign in")
    }
}
