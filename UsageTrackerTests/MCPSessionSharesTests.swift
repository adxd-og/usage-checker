import XCTest
@testable import Omelette

/// MCP `get_sessions` and the chat shares: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Published data ("MCP
/// `get_sessions` returns them and its description says so. CLI text unchanged").
final class MCPSessionSharesTests: XCTestCase {
    /// 2026-09-06 11:20:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_693_600)

    private func file(withShares: Bool) -> StatusSnapshot {
        StatusSnapshot(
            version: StatusSnapshot.currentVersion,
            updatedAt: now,
            services: [
                StatusSnapshot.Service(
                    id: "claude", name: "Claude", state: "ok", retained: false, retainedAt: nil,
                    plan: "Max 5x", windows: [], todayCost: 4.2, weekCost: 31.7, todayTokens: 1_000,
                    apiEquivalent: true,
                    sessions: [
                        StatusSnapshot.SessionEntry(
                            id: "s1", title: "Blume integration", project: "Usage tracker",
                            lastAt: now.addingTimeInterval(-3600), turns: 40, tokens: 2_000_000,
                            cost: 12.5, agents: 1, origin: nil,
                            sessionShare: withShares ? 3.5 : nil,
                            weekShare: withShares ? 12.5 : nil
                        ),
                        StatusSnapshot.SessionEntry(
                            id: "s2", title: "Release notes", project: "Usage tracker",
                            lastAt: now.addingTimeInterval(-7200), turns: 8, tokens: 300_000,
                            cost: 1.25, agents: 0, origin: nil
                        ),
                    ]
                ),
            ],
            agents: .none
        )
    }

    func testGetSessionsReturnsEachChatsSharesAndNoKeyWhereNoneApplies() throws {
        let data = MCPServer.sessionsData(file(withShares: true), provider: nil, limit: 10)
        let services = try XCTUnwrap(data["services"] as? [[String: Any]])
        let sessions = try XCTUnwrap(services.first?["sessions"] as? [[String: Any]])
        let s1 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s1" })
        let s2 = try XCTUnwrap(sessions.first { $0["id"] as? String == "s2" })

        XCTAssertEqual(s1["sessionShare"] as? Double, 3.5)
        XCTAssertEqual(s1["weekShare"] as? Double, 12.5)
        XCTAssertNil(s1["budgetShare"])
        XCTAssertNil(s2["sessionShare"])
        XCTAssertNil(s2["weekShare"])
        XCTAssertNil(s2["budgetShare"])
    }

    func testTheGetSessionsParagraphIsTheSameWithShares() {
        let calendar = SessionFixture.calendar
        let locale = SessionFixture.locale

        XCTAssertEqual(
            MCPSummary.sessions(
                snapshot: file(withShares: true), provider: nil, limit: 10, now: now,
                calendar: calendar, locale: locale
            ),
            MCPSummary.sessions(
                snapshot: file(withShares: false), provider: nil, limit: 10, now: now,
                calendar: calendar, locale: locale
            )
        )
    }
}
