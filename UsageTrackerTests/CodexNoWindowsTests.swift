import XCTest
@testable import Omelette

/// An identified Codex account whose RPC answered without any rate-limit window
/// (CodexBarCore's `emptyCodexUsageSnapshotIfIdentified`). Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention — "Codex
/// identified with no windows: `.ok` only when neither the previous nor the stored
/// Codex entry had windows; otherwise a non-ok state ('Codex reported no limits') so
/// retention dims the old numbers."
final class CodexNoWindowsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    private var t1: Date { t0.addingTimeInterval(600) }

    private var session: UsageBucket {
        Fixture.bucket(id: "codex_session", label: "Current session", percent: 40, kind: .session)
    }

    private func codex(buckets: [UsageBucket], weekCost: Double? = nil, at date: Date) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "codex", displayName: "Codex", icon: "chevron.left.forwardslash.chevron.right",
            plan: "Codex Plus", accountLabel: "me@example.com",
            buckets: buckets, weekCost: weekCost, at: date
        )
    }

    private func poll(_ services: [ServiceSnapshot], at date: Date) -> UsageSnapshot {
        UsageSnapshot(services: services, fetchedAt: date, isStale: false, lastError: nil)
    }

    func testTheStateRule() {
        XCTAssertEqual(CodexProvider.state(bucketCount: 2, hadWindowsBefore: true), .ok)
        XCTAssertEqual(CodexProvider.state(bucketCount: 2, hadWindowsBefore: false), .ok)
        XCTAssertEqual(CodexProvider.state(bucketCount: 0, hadWindowsBefore: false), .ok,
                       "a plan that never had windows is correctly empty")
        XCTAssertEqual(CodexProvider.state(bucketCount: 0, hadWindowsBefore: true), .error)
    }

    func testWindowsThatVanishAfterAPollAreFlagged() throws {
        let previous = poll([codex(buckets: [session], at: t0)], at: t0)
        let next = poll([codex(buckets: [], weekCost: 5.2, at: t1)], at: t1)

        let flagged = CodexProvider.flaggingMissingWindows(in: next, previous: previous, stored: [:])

        let service = try XCTUnwrap(flagged.services.first)
        XCTAssertEqual(service.state, .error)
        XCTAssertEqual(service.stateMessage, "Codex reported no limits")
        XCTAssertEqual(CodexProvider.noLimitsMessage, "Codex reported no limits")
        XCTAssertEqual(service.plan, "Codex Plus", "the account it identified stays")
        XCTAssertEqual(service.fetchedAt, t1)
    }

    func testTheOldNumbersStayDimmedUnderTheChip() throws {
        let previous = poll([codex(buckets: [session], at: t0)], at: t0)
        let next = poll([codex(buckets: [], at: t1)], at: t1)

        let flagged = CodexProvider.flaggingMissingWindows(in: next, previous: previous, stored: [:])
        let shown = AppState.retainingLastGoodServices(previous: previous, next: flagged, stored: [:])

        let service = try XCTUnwrap(shown.services.first)
        XCTAssertEqual(service.buckets.first?.utilization, 40, "the numbers no longer vanish unflagged")
        XCTAssertTrue(service.isRetained)
        XCTAssertEqual(service.retainedAt, t0)
        XCTAssertEqual(service.stateMessage, "Codex reported no limits")
    }

    func testAfterARelaunchTheStoredReadingIsEnough() {
        let stored = ["codex": LastKnownService(from: codex(buckets: [session], at: t0), order: 1)]
        let next = poll([codex(buckets: [], at: t1)], at: t1)

        let flagged = CodexProvider.flaggingMissingWindows(in: next, previous: .empty, stored: stored)

        XCTAssertEqual(flagged.services.first?.state, .error)
    }

    func testAnAccountThatNeverHadWindowsStaysOk() {
        let next = poll([codex(buckets: [], weekCost: 5.2, at: t1)], at: t1)
        XCTAssertEqual(CodexProvider.flaggingMissingWindows(in: next, previous: .empty, stored: [:]), next)
    }

    func testAnAccountWithWindowsIsUntouched() {
        let previous = poll([codex(buckets: [session], at: t0)], at: t0)
        let next = poll([codex(buckets: [session], at: t1)], at: t1)
        XCTAssertEqual(CodexProvider.flaggingMissingWindows(in: next, previous: previous, stored: [:]), next)
    }

    func testOtherProvidersAreUntouched() {
        // A pay-as-you-go Claude reports no windows either; that is not Codex's rule.
        let previous = poll([Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "five_hour", percent: 20, kind: .session)], at: t0
        )], at: t0)
        let next = poll([Fixture.snapshot(id: "claude", buckets: [], weekCost: 31.7, at: t1)], at: t1)
        XCTAssertEqual(CodexProvider.flaggingMissingWindows(in: next, previous: previous, stored: [:]), next)
    }

    func testForgettingTheNumbersLetsAWindowlessPlanSettle() {
        // The way out when a plan really did lose its windows: Settings → Providers →
        // "Forget last known numbers" clears the stored entry and the retained numbers.
        let previous = poll([codex(buckets: [session], at: t0)], at: t0)
        let flagged = CodexProvider.flaggingMissingWindows(
            in: poll([codex(buckets: [], at: t1)], at: t1), previous: previous, stored: [:]
        )
        let shown = AppState.retainingLastGoodServices(previous: previous, next: flagged, stored: [:])
        let forgotten = AppState.droppingRetained(serviceID: "codex", from: shown)

        let later = poll([codex(buckets: [], at: t1.addingTimeInterval(600))], at: t1.addingTimeInterval(600))
        let settled = CodexProvider.flaggingMissingWindows(in: later, previous: forgotten, stored: [:])

        XCTAssertEqual(settled.services.first?.state, .ok)
    }
}
