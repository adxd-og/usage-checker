import XCTest
@testable import Omelette

/// The dashboard's copy of the agent run history. `DashboardState` is a main-actor
/// singleton, so these drive `.shared` directly and hand it a temp log — the same
/// injection point `AgentSessionStore` uses in its own tests.
@MainActor
final class DashboardAgentRecordsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardAgentRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ id: String) -> AgentSessionRecord {
        AgentSessionRecord(
            id: id, source: .claude, project: "Usage tracker",
            startedAt: Date(timeIntervalSince1970: 1_788_329_880),
            endedAt: Date(timeIntervalSince1970: 1_788_341_400),
            turns: 4, needsYouCount: 1
        )
    }

    func testTheLogIsPublishedAsAgentRecords() async throws {
        let url = directory.appendingPathComponent("agent-sessions.jsonl")
        let store = AgentHistoryStore(fileURL: url)
        try store.append(record("claude:s1"))
        try store.append(record("claude:s2"))

        await DashboardState.shared.refreshAgentHistory(historyURL: url)

        XCTAssertEqual(DashboardState.shared.agentRecords.map(\.id), ["claude:s1", "claude:s2"])
    }

    func testAMissingLogPublishesNothingRatherThanFailing() async throws {
        let url = directory.appendingPathComponent("does-not-exist.jsonl")
        await DashboardState.shared.refreshAgentHistory(historyURL: url)
        XCTAssertEqual(DashboardState.shared.agentRecords, [])
    }
}
