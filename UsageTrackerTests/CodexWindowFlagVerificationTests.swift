import XCTest
@testable import Omelette

/// Independent verification of P1 (Retention), report A item 6. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Codex
/// identified with no windows: `.ok` only when neither the previous nor the stored
/// Codex entry had windows; otherwise a non-ok state ('Codex reported no limits') so
/// retention dims the old numbers."
///
/// The executor's `CodexNoWindowsTests` pins one poll at a time. This file drives the
/// exact two-step pipeline `AppState.performRefresh` runs each poll —
/// `flaggingMissingWindows` then `retainingLastGoodServices` — across a chain of
/// several consecutive polls, since `flaggingMissingWindows`'s "had windows before"
/// check reads the *previous displayed* snapshot, which is itself the output of the
/// same pipeline one poll earlier.
final class CodexWindowFlagVerificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private func t(_ n: Int) -> Date { t0.addingTimeInterval(TimeInterval(n) * 600) }

    private var session: UsageBucket {
        Fixture.bucket(id: "codex_session", label: "Current session", percent: 55, kind: .session)
    }

    private func codex(buckets: [UsageBucket], at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "codex", displayName: "Codex", plan: "Codex Plus", buckets: buckets, at: date)
    }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    /// One production poll: flag, then retain, exactly as `performRefresh` does
    /// (`applyPayAsYouGo` is irrelevant to Codex and left out).
    private func step(previous: UsageSnapshot, rawNext: UsageSnapshot) -> UsageSnapshot {
        let flagged = CodexProvider.flaggingMissingWindows(in: rawNext, previous: previous, stored: [:])
        return AppState.mergingPoll(previous: previous, next: flagged, stored: [:])
    }

    func testThreeConsecutiveEmptyPollsStayErrorWithTheOriginalWindow() {
        var displayed = poll([codex(buckets: [session], at: t(0))], at: t(0))
        XCTAssertEqual(displayed.services.first?.state, .ok)

        for n in 1...3 {
            let raw = poll([codex(buckets: [], at: t(n))], at: t(n))
            displayed = step(previous: displayed, rawNext: raw)
            let codexNow = try? XCTUnwrap(displayed.services.first)
            XCTAssertEqual(codexNow?.state, .error, "poll \(n): still flagged, not silently ok with zero windows")
            XCTAssertEqual(codexNow?.stateMessage, CodexProvider.noLimitsMessage)
            XCTAssertEqual(codexNow?.buckets.first?.utilization, 55, "poll \(n): the original window, not lost or zeroed")
        }
        XCTAssertTrue(displayed.isStale)
    }

    func testWindowsReturningAfterTwoEmptyPollsClearsTheFlagWithFreshNumbers() {
        var displayed = poll([codex(buckets: [session], at: t(0))], at: t(0))
        for n in 1...2 {
            let raw = poll([codex(buckets: [], at: t(n))], at: t(n))
            displayed = step(previous: displayed, rawNext: raw)
        }
        XCTAssertEqual(displayed.services.first?.state, .error, "sanity: still flagged after two empty polls")

        let recovered = Fixture.bucket(id: "codex_session", percent: 8, kind: .session)
        let raw3 = poll([codex(buckets: [recovered], at: t(3))], at: t(3))
        let after = step(previous: displayed, rawNext: raw3)

        let codexNow = try? XCTUnwrap(after.services.first)
        XCTAssertEqual(codexNow?.state, .ok)
        XCTAssertNil(codexNow?.stateMessage)
        XCTAssertEqual(codexNow?.buckets.first?.utilization, 8, "the fresh reading, not the frozen 55%")
        XCTAssertFalse(codexNow?.isRetained ?? true)
        XCTAssertFalse(after.isStale)
    }

    func testAnAccountRelaunchedMidGapUsesTheStoredReadingNotAFreshEmptyOne() {
        // The app closes after one empty poll (state now `.error`, nothing new stored —
        // `remember` skips non-`.ok` services) and relaunches. `previous` starts empty;
        // only `stored` — from before the gap started — has a window.
        let stored = ["codex": LastKnownService(from: codex(buckets: [session], at: t0), order: 0)]
        let raw = poll([codex(buckets: [], at: t(5))], at: t(5))

        let flagged = CodexProvider.flaggingMissingWindows(in: raw, previous: .empty, stored: stored)
        let merged = AppState.mergingPoll(previous: .empty, next: flagged, stored: stored)

        let codexNow = try? XCTUnwrap(merged.services.first)
        XCTAssertEqual(codexNow?.state, .error)
        XCTAssertEqual(codexNow?.buckets.first?.utilization, 55, "pulled from the file across the relaunch, not treated as a plan with no windows")
    }

    func testACreditsOnlyAccountNeverFlipsToErrorAcrossRepeatedPolls() {
        // No windows this poll or ever before: stays `.ok` indefinitely, not just once.
        var displayed = poll([codex(buckets: [], at: t0)], at: t0)
        for n in 1...3 {
            let raw = poll([codex(buckets: [], at: t(n))], at: t(n))
            displayed = step(previous: displayed, rawNext: raw)
            XCTAssertEqual(displayed.services.first?.state, .ok, "poll \(n): a genuinely windowless plan is not an error")
        }
    }
}
