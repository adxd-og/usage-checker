import Combine
import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// status.json (report B #2): "the store's sink passes the emitted sessions through to
/// `publishStatusFile`." This file exercises `AppState.agentSummaries(of:)` as a pure
/// function against a synthetic `@Published` source (no `AgentSessionStore`, no
/// `AppState` singleton), which is what makes it independent of
/// `StatusAgentSinkTests.swift`'s real-store test: any divergence between the two would
/// mean the store's own state transitions — not the mapping rule — are where a bug
/// hides.
final class AppStateVerificationTests: XCTestCase {
    /// A plain `@Published` source, standing in for `AgentSessionStore.$sessions`
    /// without touching the store at all.
    private final class Emitter {
        @Published var sessions: [AgentSession] = []
    }

    func testASummaryBuiltFromAnEmittedListThatLacksASessionLeavesItOut() throws {
        let emitter = Emitter()
        var delivered: [StatusFileWriter.AgentSummary] = []
        let subscription = AppState.agentSummaries(of: emitter.$sessions).sink { delivered.append($0) }
        defer { subscription.cancel() }

        let kept = Fixture.agentSession(sessionID: "verify-kept", state: .working)
        let removed = Fixture.agentSession(sessionID: "verify-removed", state: .needsYou)
        emitter.sessions = [kept, removed]
        XCTAssertEqual(delivered.last?.sessions.map(\.id).sorted(), [kept.id, removed.id].sorted(), "precondition")

        // The list `removed` is no longer part of — exactly what `AgentSessionStore`
        // hands its subscribers the instant a `SessionEnd` fires.
        emitter.sessions = [kept]

        let summary = try XCTUnwrap(delivered.last)
        XCTAssertEqual(summary.sessions.map(\.id), [kept.id])
        XCTAssertFalse(
            summary.sessions.contains(where: { $0.id == removed.id }),
            "a session absent from the emitted array must not appear in the built summary"
        )
        XCTAssertEqual(summary.needsYou, 0, "the removed session was the only one waiting on the user")
        XCTAssertEqual(summary.working, 1)
    }

    func testEveryEmissionProducesItsOwnSummaryNotJustTheLast() {
        let emitter = Emitter()
        var counts: [Int] = []
        let subscription = AppState.agentSummaries(of: emitter.$sessions)
            .sink { counts.append($0.sessions.count) }
        defer { subscription.cancel() }

        emitter.sessions = [Fixture.agentSession(sessionID: "verify-a")]
        emitter.sessions = [
            Fixture.agentSession(sessionID: "verify-a"), Fixture.agentSession(sessionID: "verify-b"),
        ]
        emitter.sessions = []

        // Initial value (empty, from `@Published`'s own subscribe-time emission) plus
        // the three assignments above.
        XCTAssertEqual(counts, [0, 1, 2, 0])
    }

    /// `StatusFileWriter.AgentSummary.init(sessions:)` itself: the needsYou/working
    /// counts come from the WHOLE list, even once the row list is capped at
    /// `maxSessions` — a truncated list must not undercount the flag the status line
    /// and `get_agents` both read.
    func testTheCountsComeFromTheWholeListEvenPastTheDisplayCap() {
        var many: [AgentSession] = []
        for i in 0..<(StatusFileWriter.maxSessions + 5) {
            many.append(Fixture.agentSession(sessionID: "verify-cap-\(i)", state: .needsYou))
        }

        let summary = StatusFileWriter.AgentSummary(sessions: many)

        XCTAssertEqual(summary.sessions.count, StatusFileWriter.maxSessions, "rows are capped")
        XCTAssertEqual(summary.needsYou, many.count, "but the count is not — every one of them needs the user")
    }
}
