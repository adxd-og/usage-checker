import XCTest
@testable import Omelette

/// The persisted source filter. The stored value is a raw string, so it has to
/// survive a value written by a future build (or a hand-edited defaults plist).
final class AgentsHistorySourceTests: XCTestCase {
    func testAllMeansNoFilter() {
        XCTAssertNil(AgentsHistoryView.selectedSource("all"))
    }

    func testAProviderIdSelectsThatSource() {
        XCTAssertEqual(AgentsHistoryView.selectedSource("claude"), .claude)
        XCTAssertEqual(AgentsHistoryView.selectedSource("codex"), .codex)
    }

    func testAnUnknownStoredValueFallsBackToAll() {
        XCTAssertNil(AgentsHistoryView.selectedSource("antigravity"))
        XCTAssertNil(AgentsHistoryView.selectedSource(""))
    }

    func testTheStoredKeyIsTheOneTheSpecFixed() {
        XCTAssertEqual(AgentsHistoryView.sourceKey, "agentsHistorySource")
    }

    func testTheFilterOffersAllClaudeAndCodexInThatOrder() {
        XCTAssertEqual(AgentsHistoryView.sourceItems.map(\.title), ["All", "Claude", "Codex"])
    }

    func testEverySegmentIsAValueTheFilterUnderstands() {
        XCTAssertNil(AgentsHistoryView.selectedSource(AgentsHistoryView.sourceItems[0].id))
        XCTAssertEqual(
            AgentsHistoryView.sourceItems.dropFirst().map { AgentsHistoryView.selectedSource($0.id) },
            [.claude, .codex]
        )
    }
}

/// What makes the Agents tab reload its history. The live session count alone misses
/// every same-count transition — a session ending as another starts, or a session
/// being archived and immediately revived by `claude --resume`.
final class AgentsHistoryReloadKeyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_788_350_400)

    func testAnEventWithNoChangeInCountStillReloads() {
        XCTAssertNotEqual(
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at),
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at.addingTimeInterval(1))
        )
    }

    func testANewSessionReloadsBeforeAnyEventHasLanded() {
        XCTAssertNotEqual(
            AgentsHistoryView.historyReloadKey(sessions: 0, lastEventAt: nil),
            AgentsHistoryView.historyReloadKey(sessions: 1, lastEventAt: nil)
        )
    }

    func testAnUnchangedStoreDoesNotReload() {
        XCTAssertEqual(
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at),
            AgentsHistoryView.historyReloadKey(sessions: 3, lastEventAt: at)
        )
    }
}
