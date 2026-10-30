import XCTest
@testable import Omelette

/// Notch-island spec 2026-10-29 § 3.3, decisions moved out of views: the needs-you dot.
/// A provider carries it while one of its own sessions waits for the user; providers
/// without agents (Antigravity, Grok) never do.
final class ProviderGridWaitingDotTests: XCTestCase {
    private func session(_ id: String, _ source: AgentSource, _ state: AgentState) -> AgentSession {
        Fixture.agentSession(sessionID: id, source: source, state: state)
    }

    func testAWaitingClaudeSessionLightsClaudeOnly() {
        let sessions = [session("a", .claude, .needsYou), session("b", .codex, .working)]
        XCTAssertTrue(ProviderGridRules.showsWaitingDot(serviceID: "claude", sessions: sessions))
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "codex", sessions: sessions))
    }

    func testAWaitingCodexSessionLightsCodex() {
        XCTAssertTrue(ProviderGridRules.showsWaitingDot(serviceID: "codex", sessions: [session("c", .codex, .needsYou)]))
    }

    func testWorkingDoneAndIdleSessionsLightNothing() {
        let sessions = [session("a", .claude, .working), session("b", .claude, .done), session("c", .claude, .idle)]
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "claude", sessions: sessions))
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "claude", sessions: []))
    }

    func testProvidersWithoutAgentsNeverLight() {
        let sessions = [session("a", .claude, .needsYou), session("b", .codex, .needsYou)]
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "antigravity", sessions: sessions))
        XCTAssertFalse(ProviderGridRules.showsWaitingDot(serviceID: "grok", sessions: sessions))
    }
}
