import XCTest
@testable import Omelette

/// Independent verification of P4's Task 1 (source filter on the title row) and Task 11
/// (the History link), against liquid-glass spec § Screens, "Agents", and the plan's
/// "Check especially" items: the picker's segment ids against the real provider ids, and
/// its VoiceOver name against `OMSegmentedControl`'s own default (so the override is
/// proven meaningful, not accidentally equal to the default it replaces).
final class AgentsHistoryViewVerificationTests: XCTestCase {
    // MARK: - sourceItems against the real provider ids

    func testAllHasNoProviderIDBecauseItIsNotAProvider() {
        let all = AgentsHistoryView.sourceItems[0]
        XCTAssertEqual(all.id, "all")
        XCTAssertNil(all.serviceID)
    }

    func testTheClaudeSegmentsIDAndProviderIDAreTheRealClaudeServiceID() {
        let claude = AgentsHistoryView.sourceItems[1]
        XCTAssertEqual(claude.id, AgentSource.claude.rawValue)
        XCTAssertEqual(claude.serviceID, ClaudeOAuthProvider.serviceID)
    }

    func testTheCodexSegmentsIDAndProviderIDAreTheRealCodexServiceID() {
        let codex = AgentsHistoryView.sourceItems[2]
        XCTAssertEqual(codex.id, AgentSource.codex.rawValue)
        XCTAssertEqual(codex.serviceID, CodexProvider.serviceID)
    }

    /// Round-trip: an item's own id, fed back through `selectedSource`, must select
    /// exactly the source that item stands for (or nil, for All).
    func testEverySourceItemsIDSelectsItself() {
        let expected: [AgentSource?] = [nil, .claude, .codex]
        for (item, want) in zip(AgentsHistoryView.sourceItems, expected) {
            XCTAssertEqual(AgentsHistoryView.selectedSource(item.id), want, "item id \"\(item.id)\"")
        }
    }

    // MARK: - selectedSource's fallback

    func testAnUnrecognisedStoredSourceFallsBackToAllNotToClaude() {
        // A regression that defaulted an unknown value to the first real source, rather
        // than to "no filter", would silently hide Codex sessions from a user on a
        // build that renamed or removed a source.
        XCTAssertNil(AgentsHistoryView.selectedSource("unknown-provider"))
        XCTAssertNil(AgentsHistoryView.selectedSource("Claude")) // case-sensitive: not the stored form
    }

    // MARK: - The VoiceOver override is meaningful, not a no-op

    func testTheSourcePickersAccessibilityLabelOverridesTheControlsGenericDefault() {
        // OMSegmentedControl defaults accessibilityLabel to "Provider"; if AgentsCopy
        // .sourcePickerName ever collapsed back to that default, VoiceOver would call
        // the filter "Provider" again despite "All" not being a provider.
        XCTAssertNotEqual(AgentsCopy.sourcePickerName, "Provider")
        XCTAssertEqual(AgentsCopy.sourcePickerName, "Source")
    }

    // MARK: - Live count copy, cross-checked against AgentsSection's own pluralisation

    func testLiveCountIsNilAtZeroBecauseTheEmptyRowAlreadySaysSo() {
        XCTAssertNil(AgentsCopy.liveCount(0))
    }

    func testLiveCountAboveZeroMatchesAgentsSectionsOwnPluralisationRule() {
        for count in [1, 2, 5, 42] {
            XCTAssertEqual(AgentsCopy.liveCount(count), AgentsSection.sessionsCaption(count))
        }
    }

    func testLiveCountSingularAndPluralWording() {
        XCTAssertEqual(AgentsCopy.liveCount(1), "1 session")
        XCTAssertEqual(AgentsCopy.liveCount(2), "2 sessions")
    }

    // MARK: - historyReloadKey changes on every input that should force a reload

    func testReloadKeyChangesWhenTheLiveCountChangesWithTheSameLastEvent() {
        let at = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertNotEqual(
            AgentsHistoryView.historyReloadKey(sessions: 1, lastEventAt: at),
            AgentsHistoryView.historyReloadKey(sessions: 2, lastEventAt: at)
        )
    }

    func testReloadKeyIsStableForTheSameSessionCountAndNilLastEvent() {
        XCTAssertEqual(
            AgentsHistoryView.historyReloadKey(sessions: 0, lastEventAt: nil),
            AgentsHistoryView.historyReloadKey(sessions: 0, lastEventAt: nil)
        )
    }
}
