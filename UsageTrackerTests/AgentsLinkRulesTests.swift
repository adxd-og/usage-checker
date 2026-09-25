import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, "Agents" (link "All sessions in History ›") and
/// § Principles 4 (a summary links to the screen that owns the detail), with the
/// session's ruling R4 (2026-09-25): the link opens History, on the provider the source
/// filter names.
final class AgentsLinkRulesTests: XCTestCase {
    func testTheLinkAlwaysOpensHistory() {
        XCTAssertEqual(AgentsLinkRules.target(source: nil).tab, .history)
        XCTAssertEqual(AgentsLinkRules.target(source: .claude).tab, .history)
        XCTAssertEqual(AgentsLinkRules.target(source: .codex).tab, .history)
    }

    func testTheTabValueTheLinkWritesRoutesTheWindowToHistory() {
        XCTAssertEqual(DashboardTab.route(storedValue: AgentsLinkRules.target(source: nil).tab.rawValue), .history)
    }

    func testAllLeavesTheDashboardsProviderAlone() {
        XCTAssertNil(AgentsLinkRules.target(source: nil).serviceID)
    }

    func testAClaudeFilterTakesHistoryToClaude() {
        XCTAssertEqual(AgentsLinkRules.target(source: .claude).serviceID, "claude")
        XCTAssertEqual(AgentsLinkRules.target(source: .claude).serviceID, ClaudeOAuthProvider.serviceID)
    }

    func testACodexFilterTakesHistoryToCodex() {
        XCTAssertEqual(AgentsLinkRules.target(source: .codex).serviceID, "codex")
        XCTAssertEqual(AgentsLinkRules.target(source: .codex).serviceID, CodexProvider.serviceID)
    }

    func testTheStoredFilterValueCarriesThroughToTheProvider() {
        // From the persisted filter string to the provider id, the path the view takes.
        XCTAssertEqual(AgentsLinkRules.target(source: AgentsHistoryView.selectedSource("codex")).serviceID, "codex")
        XCTAssertNil(AgentsLinkRules.target(source: AgentsHistoryView.selectedSource("all")).serviceID)
    }
}
