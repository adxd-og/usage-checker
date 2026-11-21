import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Where it shows: the Agents tab's Live card gives both
/// figures for every live session. A session in an IDE panel shows nothing (Decision 3). The
/// rows' order is `AgentsLiveCardTests`'.
final class AgentsLiveResourcesTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private typealias Figures = AgentResourceRules.Figures
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(_ name: String, _ state: AgentState, tty: String?, minutesAgo: Double) -> AgentSession {
        Fixture.agentSession(
            sessionID: name, projectName: name, state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60),
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: tty)
        )
    }

    /// Three sessions in terminals and one in an IDE panel, which has no tty.
    private var sessions: [AgentSession] {
        [
            session("scratchpad", .idle, tty: nil, minutesAgo: 2),
            session("Usage tracker", .working, tty: F.tab, minutesAgo: 1),
            session("orion-gemini", .done, tty: F.pane, minutesAgo: 5),
            session("test", .needsYou, tty: F.otherTab, minutesAgo: 0),
        ]
    }

    private let byTTY: [String: AgentResourceRules.Figures] = [
        AgentProcessFixture.tab: AgentResourceRules.Figures(cpuPercent: 48, memoryBytes: 525 * AgentProcessFixture.mb),
        AgentProcessFixture.pane: AgentResourceRules.Figures(cpuPercent: 212.4, memoryBytes: 3_650_722_202),
        AgentProcessFixture.otherTab: AgentResourceRules.Figures(cpuPercent: 3.2, memoryBytes: 415 * AgentProcessFixture.mb),
    ]

    /// What the monitor publishes: each session's figures by id (`AgentResourceMonitor.bySession`).
    private var figures: [String: Figures] { AgentResourceRules.bySession(sessions, byTTY: byTTY) }

    func testEveryMeasuredRowCarriesBothFigures() {
        let tab = session("Usage tracker", .working, tty: F.tab, minutesAgo: 1)
        let busy = session("orion-gemini", .done, tty: F.pane, minutesAgo: 5)
        let quiet = session("test", .needsYou, tty: F.otherTab, minutesAgo: 0)
        let panel = session("scratchpad", .idle, tty: nil, minutesAgo: 2)
        XCTAssertEqual(AgentsLiveCard.resourceText(for: busy, figures: figures, scale: .perCore, cores: 10), "212% CPU · 3.4 GB")
        XCTAssertEqual(AgentsLiveCard.resourceText(for: busy, figures: figures, scale: .wholeMac, cores: 10), "21% CPU · 3.4 GB")
        XCTAssertEqual(AgentsLiveCard.resourceText(for: tab, figures: figures, scale: .perCore, cores: 10), "48% CPU · 525 MB")
        XCTAssertEqual(
            AgentsLiveCard.resourceText(for: quiet, figures: figures, scale: .perCore, cores: 10), "3% CPU · 415 MB",
            "below the island's threshold, still shown here"
        )
        XCTAssertNil(AgentsLiveCard.resourceText(for: panel, figures: figures, scale: .perCore, cores: 10))
    }
}
