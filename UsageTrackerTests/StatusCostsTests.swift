import XCTest
@testable import Omelette

/// `gather` reads the real `~/.claude`, `~/.codex` and `~/.grok` trees, so it is not
/// what a test can pin. The mapping is: which three numbers out of a `CLIBreakdown`
/// end up in the file, and in which order.
final class StatusCostsTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_788_693_600)

    private func breakdown(today: Double, week: Double, tokens: Int) -> CLIBreakdown {
        CLIBreakdown(
            todayCost: today,
            todayTokens: tokens,
            todayTokenBreakdown: .zero,
            todayTurns: 3,
            weekCost: week,
            monthCost: week * 3,
            byModelToday: [],
            daily: [],
            projectsWeek: [],
            projectsMonth: [],
            updatedAt: day
        )
    }

    func testTodayWeekAndTokensAreCarriedInThatOrder() {
        let entry = StatusCosts.entry(breakdown(today: 4.2, week: 31.7, tokens: 1_234_567))

        XCTAssertEqual(entry.todayCost, 4.2)
        XCTAssertEqual(entry.weekCost, 31.7)
        XCTAssertEqual(entry.todayTokens, 1_234_567)
    }

    func testAQuietDayIsZeroRatherThanAbsent() {
        // "No log" is absent (the provider is not in the dictionary at all); "spent
        // nothing today" is zero. The CLI prints neither, but MCP tells them apart.
        let entry = StatusCosts.entry(breakdown(today: 0, week: 12, tokens: 0))

        XCTAssertEqual(entry.todayCost, 0)
        XCTAssertEqual(entry.weekCost, 12)
    }

    func testOnlyProvidersWithALocalLogAreEverGathered() async {
        // Antigravity keeps no per-turn token log — `DashboardState` already says
        // so — so it can never appear, whatever is enabled.
        let gathered = await StatusCosts.gather(serviceIDs: ["antigravity"])

        XCTAssertTrue(gathered.costs.isEmpty)
        XCTAssertTrue(gathered.sessions.isEmpty, "and it names no chat either")
    }

    // MARK: - Limit shares (spec 2026-10-16 § Published data)

    func testOnlyProvidersWithAChatLogHaveShareSources() {
        // Grok's log names no chat and Antigravity keeps no token log: neither can
        // split a window by chat.
        let withChatLog = Set(["claude", "codex", "grok", "antigravity"].filter {
            DashboardState.hasSessionLog(for: $0)
        })
        XCTAssertEqual(Set(StatusCosts.shareSources.keys), withChatLog)
    }

    func testAProviderWithoutAChatLogGetsNoShares() async {
        // A weekly window would make it a subscription; with no chat log there is
        // nothing to split it by. Antigravity reaches no aggregator in `gather`.
        let antigravity = Fixture.snapshot(id: "antigravity", plan: nil, buckets: [
            Fixture.bucket(id: "antigravity_weekly", label: "Weekly", percent: 30,
                           resetsAt: day.addingTimeInterval(86_400), kind: .weekly),
        ], at: day)

        let gathered = await StatusCosts.gather(
            serviceIDs: ["antigravity"], services: [antigravity], weeklyBudgetUSD: 0, now: day
        )

        XCTAssertTrue(gathered.shares.isEmpty)
    }
}
