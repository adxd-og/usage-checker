import XCTest
@testable import Omelette

/// A poll the cadence holds back shows Claude's last answer instead of asking (spec
/// 2026-11-02 Claude limits from the status line, § Design › Cadence): only while Claude
/// is on, with its Retry-After spent; the last fetch moves only when a poll asked; a held
/// poll leaves the popover's floor where the last asking poll put it (session ruling 4);
/// the coordinator stands the held answer in for Claude's fetch and asks nothing.
final class ClaudeHeldFetchTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func claude(retryAfter: TimeInterval? = nil, at date: Date) -> ServiceSnapshot {
        var snapshot = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 20, kind: .session)],
            at: date
        )
        snapshot.retryAfter = retryAfter
        return snapshot
    }

    private func held(
        _ last: ClaudePollCadenceRules.LastFetch?,
        enabled: Bool = true,
        trigger: ClaudePollCadenceRules.Trigger = .tick,
        applied: TimeInterval? = 30
    ) -> ServiceSnapshot? {
        ClaudePollCadenceRules.heldAnswer(
            last: last,
            claudeEnabled: enabled,
            trigger: trigger,
            statusLineAppliedAt: applied.map { ago($0) },
            refreshIntervalSeconds: 60,
            now: now
        )
    }

    func testAHeldPollShowsTheLastAnswerWithItsRetryAfterSpent() {
        let answer = claude(retryAfter: 60, at: ago(60))

        let shown = held(ClaudePollCadenceRules.LastFetch(snapshot: answer, at: ago(60)))

        var expected = answer
        expected.retryAfter = nil
        XCTAssertEqual(shown, expected, "the backoff it asked for was honoured when it arrived")
    }

    func testAPollThatAsksHoldsNothing() {
        let last = ClaudePollCadenceRules.LastFetch(snapshot: claude(at: ago(60)), at: ago(60))

        XCTAssertNil(held(last, applied: nil), "no status-line reading")
        XCTAssertNil(held(last, trigger: .asked), "asked for")
        XCTAssertNil(held(nil), "never fetched")
        XCTAssertNil(
            held(ClaudePollCadenceRules.LastFetch(snapshot: claude(at: ago(300)), at: ago(300))),
            "its five minutes are up"
        )
    }

    func testClaudeOffHoldsNothing() {
        let last = ClaudePollCadenceRules.LastFetch(snapshot: claude(at: ago(60)), at: ago(60))

        XCTAssertNil(held(last, enabled: false))
    }

    func testTheLastFetchMovesOnlyWhenThePollAsked() {
        let previous = ClaudePollCadenceRules.LastFetch(snapshot: claude(at: ago(120)), at: ago(120))
        let fresh = claude(at: now)
        let codex = Fixture.snapshot(id: "codex", displayName: "Codex", at: now)

        XCTAssertEqual(
            ClaudePollCadenceRules.lastFetch(after: [fresh, codex], held: nil, previous: previous, at: now),
            ClaudePollCadenceRules.LastFetch(snapshot: fresh, at: now)
        )
        XCTAssertEqual(
            ClaudePollCadenceRules.lastFetch(after: [previous.snapshot, codex], held: previous.snapshot, previous: previous, at: now),
            previous,
            "a held poll keeps the fetch it showed again, and its time"
        )
        XCTAssertNil(
            ClaudePollCadenceRules.lastFetch(after: [codex], held: nil, previous: previous, at: now),
            "Claude off forgets it"
        )
    }

    /// Spec § Cadence, "the popover-open refresh still fetches": a held tick asked Claude
    /// nothing, so it leaves the floor where the last asking poll put it, and an island
    /// opened right after it asks (session ruling 4).
    func testAnIslandOpenedRightAfterAHeldTickAsks() {
        let askedAt = ago(60)
        let heldTickAt = ago(5)

        let afterHeld = ClaudePollCadenceRules.refreshStamp(previous: askedAt, pollAt: heldTickAt, held: true)
        XCTAssertEqual(afterHeld, askedAt, "a held tick does not move the floor")
        XCTAssertTrue(AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: afterHeld, now: now))
        XCTAssertNil(
            held(ClaudePollCadenceRules.LastFetch(snapshot: claude(at: askedAt), at: askedAt), trigger: .asked),
            "and the open's poll asks Claude's endpoint"
        )

        let afterAsked = ClaudePollCadenceRules.refreshStamp(previous: askedAt, pollAt: heldTickAt, held: false)
        XCTAssertEqual(afterAsked, heldTickAt)
        XCTAssertFalse(
            AppState.shouldRefreshOnPopoverOpen(lastRefreshAt: afterAsked, now: now),
            "a poll that asked keeps its ten-second floor"
        )
    }

    func testTheCoordinatorShowsTheHeldAnswerWithoutAsking() async {
        let heldAnswer = claude(at: ago(60))
        let fresh = claude(at: now)
        var calls = 0

        let shown = await ProviderCoordinator.claudeSnapshot(enabled: true, held: heldAnswer) {
            calls += 1
            return fresh
        }
        XCTAssertEqual(shown, heldAnswer)
        XCTAssertEqual(calls, 0)

        let fetched = await ProviderCoordinator.claudeSnapshot(enabled: true, held: nil) {
            calls += 1
            return fresh
        }
        XCTAssertEqual(fetched, fresh)
        XCTAssertEqual(calls, 1)

        let off = await ProviderCoordinator.claudeSnapshot(enabled: false, held: heldAnswer) {
            calls += 1
            return fresh
        }
        XCTAssertNil(off)
        XCTAssertEqual(calls, 1, "Claude off is not fetched, held answer or not")
    }
}
