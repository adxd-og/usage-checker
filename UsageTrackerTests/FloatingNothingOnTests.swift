import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, Nothing on: the
/// floating window used to render "Loading…" for good when it had no service
/// (`FloatingMiniLayout.content(for: nil)`). With every provider off it says so; before
/// the first poll it is still loading.
final class FloatingNothingOnTests: XCTestCase {
    func testWithEveryProviderOffThePanelSaysSoAndWhereToTurnOneOn() {
        let content = FloatingMiniLayout.content(for: nil, pollsNothing: true)
        XCTAssertNil(content.hero)
        XCTAssertTrue(content.rows.isEmpty)
        XCTAssertNil(content.weekCost)
        XCTAssertNil(content.retainedAt)
        XCTAssertEqual(content.emptyText, "All providers are off. Turn one on in Settings › Providers.")
        XCTAssertEqual(NothingOnCopy.sentence, "All providers are off. Turn one on in Settings › Providers.")
    }

    func testBeforeTheFirstPollThePanelStillSaysLoading() {
        XCTAssertEqual(FloatingMiniLayout.content(for: nil, pollsNothing: false).emptyText, "Loading…")
    }

    func testNothingOnWinsOverAProviderThePollHasNotDroppedYet() {
        let codex = Fixture.snapshot(
            id: "codex", displayName: "Codex",
            buckets: [Fixture.bucket(id: "codex_session", label: "Session", percent: 30, kind: .session)]
        )
        let content = FloatingMiniLayout.content(for: codex, pollsNothing: true)
        XCTAssertNil(content.hero)
        XCTAssertEqual(content.emptyText, NothingOnCopy.sentence)
    }
}
