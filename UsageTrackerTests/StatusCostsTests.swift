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
        // Gemini and Antigravity keep no per-turn token log — `DashboardState`
        // already says so — so they can never appear, whatever is enabled.
        let costs = await StatusCosts.gather(serviceIDs: ["gemini", "antigravity"])

        XCTAssertTrue(costs.isEmpty)
    }
}
