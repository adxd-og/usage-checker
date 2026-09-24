import XCTest
@testable import Omelette

/// The floating panel for a provider that stopped reporting. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "Floating panel: `FloatingMiniLayout.Content` carries the retained state; the view
/// dims ring and bars to 0.55, hides the pace marker, shows the tile's chip."
final class FloatingMiniRetainedTests: XCTestCase {
    private let readAt = Date(timeIntervalSince1970: 1_788_000_000)
    private var now: Date { readAt.addingTimeInterval(3600) }

    private var session: UsageBucket {
        Fixture.bucket(id: "five_hour", label: "Current session", percent: 37,
                       resetsAt: now.addingTimeInterval(2 * 3600), kind: .session)
    }
    private var weekly: UsageBucket {
        Fixture.bucket(id: "seven_day", label: "All models", percent: 76,
                       resetsAt: now.addingTimeInterval(3 * 86_400), kind: .weekly)
    }

    private func retained() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [session, weekly], state: .notRunning, at: readAt)
    }

    private func live() -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [session, weekly], at: now)
    }

    func testARetainedServiceCarriesWhenItsNumbersWereTrue() {
        let content = FloatingMiniLayout.content(for: retained())
        XCTAssertEqual(content.retainedAt, readAt)
        XCTAssertEqual(content.hero?.id, "five_hour", "the numbers stay; only how they are drawn changes")
        XCTAssertEqual(content.rows.map(\.id), ["seven_day"])
    }

    func testALiveServiceCarriesNoStamp() {
        XCTAssertNil(FloatingMiniLayout.content(for: live()).retainedAt)
    }

    func testEmptyStatesCarryNoStamp() {
        XCTAssertNil(FloatingMiniLayout.content(for: nil).retainedAt)
        XCTAssertNil(FloatingMiniLayout.content(
            for: Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn, at: now)
        ).retainedAt)
    }

    func testRetainedNumbersAreDimmedToTheTilesStrength() {
        XCTAssertEqual(FloatingMiniLayout.numbersOpacity(FloatingMiniLayout.content(for: retained())), 0.55)
        XCTAssertEqual(FloatingMiniLayout.numbersOpacity(FloatingMiniLayout.content(for: live())), 1)
    }

    func testAFrozenWindowHasNoPaceMarker() throws {
        let livePace = try XCTUnwrap(
            FloatingMiniLayout.pace(for: session, in: FloatingMiniLayout.content(for: live()), now: now)
        )
        XCTAssertEqual(livePace, 0.6, accuracy: 0.000_1, "two hours left of five")
        XCTAssertNil(FloatingMiniLayout.pace(for: session, in: FloatingMiniLayout.content(for: retained()), now: now))
    }
}
