import Combine
import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// status.json: "the store's sink passes the emitted sessions through to
/// `publishStatusFile`." `@Published` delivers before the property holds the new list,
/// and the sink read the property: a `SessionEnd` — one emission, the row removed —
/// left the ended session in `status.json` until the next poll (report B #2).
final class StatusAgentSinkTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusAgentSinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func event(_ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(
            source: .claude,
            kind: kind,
            sessionID: "s1",
            cwd: "/Users/tester/Projects/alpha",
            toolName: nil,
            toolSummary: nil,
            isSubagent: false,
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: nil),
            receivedAt: t0
        )
    }

    /// `@MainActor` on the test, not the class: the store is main-actor isolated, and a
    /// main-actor class would make `setUpWithError` touch `directory` from outside it.
    @MainActor
    func testASessionThatEndsLeavesTheSummaryInTheSameDelivery() {
        let store = AgentSessionStore(historyURL: directory.appendingPathComponent("agent-sessions.jsonl"))
        store.apply(event(.sessionStart), now: t0)
        store.apply(event(.permissionRequested), now: t0.addingTimeInterval(5))

        var delivered: [StatusFileWriter.AgentSummary] = []
        var storeWhileDelivering: [Int] = []
        let summaries = AppState.agentSummaries(of: store.$sessions).sink { delivered.append($0) }
        let raw = store.$sessions.sink { _ in storeWhileDelivering.append(store.sessions.count) }
        defer {
            summaries.cancel()
            raw.cancel()
        }
        XCTAssertEqual(delivered.last?.needsYou, 1, "precondition: one session waiting on the user")

        store.apply(event(.sessionEnd), now: t0.addingTimeInterval(10))

        XCTAssertEqual(
            storeWhileDelivering.last, 1,
            "why the emitted list matters: the store still holds the ended session while it publishes"
        )
        XCTAssertEqual(delivered.last?.needsYou, 0)
        XCTAssertEqual(delivered.last?.working, 0)
        XCTAssertEqual(delivered.last?.sessions.map(\.id), [])
    }
}
