import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Local usage (P2), Surfaces: what P1 left generic for
/// `mistral` (its plan's R15) now names vibe's log. The Dashboard costs Mistral from
/// `VibeUsageAggregator`, History lists its chats and asks for `vibe` when empty; the Limits tab,
/// which the spec does not extend, still measures Claude and Codex only (plan R7).
final class MistralLocalUsageSurfacesTests: XCTestCase {
    private let now = MistralFixture.now
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testMistralsDollarsComeFromTheVibeLog() {
        let source = DashboardState.costSource(for: "mistral")
        XCTAssertEqual(source, .log(shortName: "Vibe CLI", longName: "the vibe CLI's session logs"))
        XCTAssertTrue(DashboardState.costAggregator(for: "mistral") is VibeUsageAggregator)
        XCTAssertEqual(OverviewCopy.cliTitle(shortName: source.shortName), "Vibe CLI · today")
        XCTAssertEqual(
            HistoryCopy.subtitle(showsQuota: false, providerName: "Mistral", sourceName: source.longName, isPayAsYouGo: false),
            "API-equivalent cost from the vibe CLI's session logs, not your subscription bill"
        )
    }

    func testHistoryListsMistralsChatsAndItsEmptyStateAsksForVibe() {
        XCTAssertTrue(DashboardState.hasSessionLog(for: "mistral"))
        XCTAssertEqual(DashboardState.cliCommandName(for: "mistral"), "vibe")
    }

    func testTheLimitsTabStillMeasuresOnlyClaudeAndCodex() throws {
        XCTAssertEqual(
            ["claude", "codex", "mistral", "grok", "antigravity"].filter { DashboardState.measuresLimitShares(for: $0) },
            ["claude", "codex"]
        )
        let entries = try MistralBillingFetcher.decodeBudget(Data(MistralFixture.budgetBody.utf8))
        let mistral = MistralProvider.snapshot(
            result: .success(MistralBilling(planName: "INDIVIDUAL", budget: .entries(entries))), now: now
        )
        XCTAssertEqual(
            LimitsRules.page(
                serviceID: "mistral", kind: .weekly, service: mistral, weeklyBudgetUSD: 0,
                load: nil, answered: nil, now: now, calendar: utc
            ),
            .unsupported
        )
        XCTAssertEqual(LimitsRules.switchKinds(serviceID: "mistral", service: mistral), [])
    }
}
