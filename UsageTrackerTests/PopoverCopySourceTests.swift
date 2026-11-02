import XCTest
@testable import Omelette

/// The provider page's "Updated" line names Claude Code when its status line fed the
/// provider's windows, and is then as old as that reading (spec 2026-11-02 Claude limits
/// from the status line, § Source tag; session ruling 3): "Claude Max 20x · Updated 2m ago
/// from Claude Code", whatever the poll's or the retained reading's time.
final class PopoverCopySourceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func claude(
        sessionSource: ReadingSource?, asOf: Date? = nil, state: ServiceState = .ok
    ) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [
                Fixture.bucket(
                    id: "five_hour", label: "Current session", percent: 23.5, kind: .session,
                    source: sessionSource, asOf: asOf
                ),
                Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 12, kind: .modelSpecific),
            ],
            state: state
        )
    }

    /// The review's case: a signed-out Claude whose last OAuth numbers are three hours old,
    /// fed two minutes ago by Claude Code.
    func testAPageClaudeCodeFedIsDatedByTheReading() {
        XCTAssertEqual(
            PopoverCopy.metaLine(
                service: claude(sessionSource: .statusLine, asOf: ago(120), state: .notSignedIn),
                fetchedAt: ago(3 * 3600), now: now
            ),
            "Claude Max 20x · Updated 2m ago from Claude Code"
        )
        XCTAssertEqual(
            PopoverCopy.metaLine(service: claude(sessionSource: .statusLine, asOf: ago(2)), fetchedAt: ago(40), now: now),
            "Claude Max 20x · Just updated from Claude Code"
        )
    }

    func testAPageItsProviderFedSaysNothingMore() {
        XCTAssertEqual(
            PopoverCopy.metaLine(service: claude(sessionSource: nil), fetchedAt: ago(7), now: now),
            "Claude Max 20x · Updated 7s ago"
        )
        XCTAssertEqual(
            PopoverCopy.metaLine(service: claude(sessionSource: .oauth, asOf: ago(120)), fetchedAt: ago(7), now: now),
            "Claude Max 20x · Updated 7s ago",
            "the provider's own fetch is dated by the fetch"
        )
    }

    func testAFedWindowWithoutItsTimeTakesThePollsAge() {
        XCTAssertEqual(
            PopoverCopy.metaLine(service: claude(sessionSource: .statusLine), fetchedAt: ago(7), now: now),
            "Claude Max 20x · Updated 7s ago from Claude Code"
        )
    }
}
