import XCTest
@testable import Omelette

/// Spec 2026-11-19 agent resources § Where it shows: the Agents tab's Live card gives both
/// figures for every live session, and a State / CPU sort from two sessions up, when at least one
/// has figures. Sorted by CPU, rows that carry an action keep the top in their state order and
/// never move by CPU; the others order by whole percent, ties in the state order. A session in an
/// IDE panel shows nothing (Decision 3). Settings' Reset forgets the order (plan R10); that test
/// writes the app's defaults domain and hands it back.
final class AgentsLiveResourcesTests: XCTestCase {
    private typealias F = AgentProcessFixture
    private typealias Figures = AgentResourceRules.Figures
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var savedDomain: [String: Any]?
    private var domainName: String { Bundle.main.bundleIdentifier ?? "com.usagetracker.app" }

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domainName)
    }

    override func tearDown() {
        AppDomainRestore.restore(savedDomain, domainName: domainName)
        super.tearDown()
    }

    private func session(_ name: String, _ state: AgentState, tty: String?, minutesAgo: Double) -> AgentSession {
        Fixture.agentSession(
            sessionID: name, projectName: name, state: state,
            stateSince: now.addingTimeInterval(-minutesAgo * 60),
            lastEventAt: now.addingTimeInterval(-minutesAgo * 60),
            host: AgentHostInfo(pid: nil, bundleID: nil, tty: tty)
        )
    }

    /// State order: test (needs you), Usage tracker (working), orion-gemini (done), scratchpad (idle).
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
    private func shown(
        _ byTTY: [String: AgentResourceRules.Figures], of live: [AgentSession]? = nil
    ) -> [String: AgentResourceRules.Figures] {
        AgentResourceRules.bySession(live ?? sessions, byTTY: byTTY)
    }

    private var figures: [String: AgentResourceRules.Figures] { shown(byTTY) }

    func testSortedByStateTheOrderIsAsBefore() {
        XCTAssertEqual(
            AgentsLiveCard.rows(sessions, sort: .state, figures: figures).map(\.projectName),
            ["test", "Usage tracker", "orion-gemini", "scratchpad"]
        )
    }

    func testSortedByCPUTheBusiestSessionLeadsAfterTheRowsThatNeedTheUser() {
        XCTAssertEqual(
            AgentsLiveCard.rows(sessions, sort: .cpu, figures: figures).map(\.projectName),
            ["test", "orion-gemini", "Usage tracker", "scratchpad"],
            "test needs you and keeps the top; then 212%, 48%, no figures"
        )
    }

    func testSessionsWithoutCPUFollowInStateOrder() {
        let firstReading = shown([
            F.tab: Figures(cpuPercent: nil, memoryBytes: 634 * F.mb),
            F.pane: Figures(cpuPercent: 48, memoryBytes: 525 * F.mb),
        ])
        XCTAssertEqual(
            AgentsLiveCard.rows(sessions, sort: .cpu, figures: firstReading).map(\.projectName),
            ["test", "orion-gemini", "Usage tracker", "scratchpad"],
            "Usage tracker has memory and no CPU yet: it follows orion-gemini, then scratchpad in state order"
        )
    }

    /// Review F1: the order compares whole percents, so jitter within one cannot swap two rows
    /// between two samples.
    func testJitterWithinAPercentNeverSwapsTwoRows() {
        let pair = [
            session("alpha", .working, tty: F.tab, minutesAgo: 1),
            session("beta", .working, tty: F.pane, minutesAgo: 2),
        ]
        let before = shown([F.tab: Figures(cpuPercent: 0.31, memoryBytes: 634 * F.mb), F.pane: Figures(cpuPercent: 0.29, memoryBytes: 634 * F.mb)], of: pair)
        let after = shown([F.tab: Figures(cpuPercent: 0.29, memoryBytes: 634 * F.mb), F.pane: Figures(cpuPercent: 0.31, memoryBytes: 634 * F.mb)], of: pair)
        XCTAssertEqual(AgentsLiveCard.rows(pair, sort: .cpu, figures: before).map(\.projectName), ["alpha", "beta"])
        XCTAssertEqual(AgentsLiveCard.rows(pair, sort: .cpu, figures: after).map(\.projectName), ["alpha", "beta"])
        XCTAssertEqual(AgentsLiveCard.wholePercent(0.31), 0)
        XCTAssertEqual(AgentsLiveCard.wholePercent(212.4), 212)
        XCTAssertNil(AgentsLiveCard.wholePercent(nil))
    }

    /// Review F1: a row with Allow / Deny or a question never moves under the pointer: rows that
    /// need the user keep the top in their state order, whatever their figures.
    func testRowsThatNeedTheUserNeverMoveUnderTheCPUSort() {
        let live = [
            session("first", .needsYou, tty: F.tab, minutesAgo: 0),
            session("second", .needsYou, tty: F.pane, minutesAgo: 1),
            session("busy", .working, tty: F.otherTab, minutesAgo: 2),
        ]
        let one = shown([
            F.tab: Figures(cpuPercent: 2, memoryBytes: 634 * F.mb),
            F.pane: Figures(cpuPercent: 150, memoryBytes: 634 * F.mb),
            F.otherTab: Figures(cpuPercent: 212.4, memoryBytes: 634 * F.mb),
        ], of: live)
        let other = shown([
            F.tab: Figures(cpuPercent: 150, memoryBytes: 634 * F.mb),
            F.pane: Figures(cpuPercent: 2, memoryBytes: 634 * F.mb),
            F.otherTab: Figures(cpuPercent: 212.4, memoryBytes: 634 * F.mb),
        ], of: live)
        XCTAssertEqual(AgentsLiveCard.rows(live, sort: .cpu, figures: one).map(\.projectName), ["first", "second", "busy"])
        XCTAssertEqual(AgentsLiveCard.rows(live, sort: .cpu, figures: other).map(\.projectName), ["first", "second", "busy"])
    }

    func testAnUnknownStoredSortReadsAsState() {
        XCTAssertEqual(AgentsLiveCard.selectedSort("cpu"), .cpu)
        XCTAssertEqual(AgentsLiveCard.selectedSort("state"), .state)
        XCTAssertEqual(AgentsLiveCard.selectedSort(""), .state)
        XCTAssertEqual(AgentsLiveCard.selectedSort("fastest"), .state)
    }

    func testTheSortSwitchShowsFromTwoSessionsWhenOneHasFigures() {
        let measured = Array(sessions.prefix(2))  // scratchpad (no tty), Usage tracker (tab)
        XCTAssertFalse(AgentsLiveCard.showsSort([sessions[1]], figures: figures), "one session")
        XCTAssertFalse(AgentsLiveCard.showsSort(measured, figures: [:]), "two sessions, no figures")
        XCTAssertTrue(AgentsLiveCard.showsSort(measured, figures: figures), "two sessions, one with figures")
    }

    func testTheSortSwitchReadsStateAndCPU() {
        XCTAssertEqual(AgentsCopy.sortPickerName, "Sort")
        XCTAssertEqual(AgentsLiveCard.sortItems.map(\.id), ["state", "cpu"])
        XCTAssertEqual(AgentsLiveCard.sortItems.map(\.title), ["State", "CPU"])
        XCTAssertEqual(AgentsLiveCard.sortKey, "agentsLiveSort")
    }

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

    @MainActor
    func testResetForgetsTheLiveCardsSort() {
        UserDefaults.standard.set("cpu", forKey: AgentsLiveCard.sortKey)
        SettingsStore.shared.resetToDefaults()
        XCTAssertNil(UserDefaults.standard.object(forKey: AgentsLiveCard.sortKey))
    }
}
