import XCTest
@testable import Omelette

/// Independent verification of P4's ruling R4 (2026-09-25, plan
/// `docs/superpowers/plans/2026-09-25-3.0-P4-agents.md`) and liquid-glass spec § Screens,
/// "Agents": the link "All sessions in History ›" always opens History, and carries the
/// source filter's provider along (All leaves the dashboard's provider alone). Checked
/// against the real provider ids (`ClaudeOAuthProvider.serviceID`,
/// `CodexProvider.serviceID`), not the string literals the rule happens to use, so a
/// provider id drifting out from under `AgentSource`'s raw values would fail here.
final class AgentsLinkRulesVerificationTests: XCTestCase {
    func testEverySourceTargetsHistoryNeverAnyOtherTab() {
        XCTAssertEqual(AgentsLinkRules.target(source: nil).tab, .history)
        XCTAssertEqual(AgentsLinkRules.target(source: .claude).tab, .history)
        XCTAssertEqual(AgentsLinkRules.target(source: .codex).tab, .history)
    }

    func testTheWrittenTabRawValueIsTheOne2xStoredForHistory() {
        // AppStorage persists the raw string; a drift here would silently misroute the
        // window for anyone who last had History open before this build.
        XCTAssertEqual(AgentsLinkRules.target(source: nil).tab.rawValue, "History")
    }

    func testAllLeavesTheProviderUntouched() {
        XCTAssertNil(AgentsLinkRules.target(source: nil).serviceID)
    }

    func testClaudeCarriesTheRealClaudeProviderID() {
        XCTAssertEqual(AgentsLinkRules.target(source: .claude).serviceID, ClaudeOAuthProvider.serviceID)
        XCTAssertEqual(ClaudeOAuthProvider.serviceID, "claude")
    }

    func testCodexCarriesTheRealCodexProviderID() {
        XCTAssertEqual(AgentsLinkRules.target(source: .codex).serviceID, CodexProvider.serviceID)
        XCTAssertEqual(CodexProvider.serviceID, "codex")
    }

    /// `AgentSource`'s raw values are, in fact, the providers' service ids — the fact
    /// the whole rule depends on. If a future rename breaks this, the link would still
    /// compile but would route to a service id nothing recognises.
    func testAgentSourceRawValuesAreTheProviderServiceIDs() {
        XCTAssertEqual(AgentSource.claude.rawValue, ClaudeOAuthProvider.serviceID)
        XCTAssertEqual(AgentSource.codex.rawValue, CodexProvider.serviceID)
    }

    /// The path the view actually takes: a persisted filter string, through
    /// `AgentsHistoryView.selectedSource`, into the link target.
    func testEveryStoredFilterValueRoundTripsToTheRightLinkTarget() {
        let cases: [(stored: String, expectedServiceID: String?)] = [
            ("all", nil),
            ("claude", "claude"),
            ("codex", "codex"),
            // Unknown or stale stored values read as All (spec: "reads as All rather
            // than filtering everything away"), so the link must leave the provider too.
            ("gemini", nil),
            ("antigravity", nil),
            ("", nil),
        ]
        for testCase in cases {
            let source = AgentsHistoryView.selectedSource(testCase.stored)
            let target = AgentsLinkRules.target(source: source)
            XCTAssertEqual(target.tab, .history, "stored \"\(testCase.stored)\"")
            XCTAssertEqual(target.serviceID, testCase.expectedServiceID, "stored \"\(testCase.stored)\"")
        }
    }
}
