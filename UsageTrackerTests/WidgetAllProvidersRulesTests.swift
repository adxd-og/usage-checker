import XCTest
@testable import Omelette

/// Spec 2026-11-10 Mistral provider § Surfaces: the widget gains Mistral. The limit of five
/// providers and the one window row each at five are the plan's decision (plan R14), not the
/// spec's words. Past five listed, the Admin API organisation waits first. Up to four listed,
/// each shows its session and its fullest other window; at five, each shows its one most
/// telling window, so the large widget's height holds them.
final class WidgetAllProvidersRulesTests: XCTestCase {
    private func service(_ id: String, buckets: [WidgetBucket] = []) -> WidgetService {
        WidgetService(id: id, name: id.capitalized, icon: "circle", plan: nil, buckets: buckets)
    }

    private func shown(_ ids: [String]) -> [String] {
        let snapshot = WidgetSnapshot(services: ids.map { service($0) }, updatedAt: Date(timeIntervalSince1970: 0))
        return WidgetEntryRules.allProvidersShown(snapshot).map(\.id)
    }

    func testFiveProvidersAllFitTheLargeWidgetAndASixthDoesNot() {
        let ids = ["claude", "anthropic-admin", "codex", "antigravity", "grok", "mistral"]
        XCTAssertEqual(shown(ids), ["claude", "codex", "antigravity", "grok", "mistral"])
        XCTAssertEqual(WidgetEntryRules.allProvidersLimit, 5)
    }

    func testFiveWithTheAdminOrganisationAmongThemAreAllListed() {
        let ids = ["claude", "anthropic-admin", "codex", "antigravity", "grok"]
        XCTAssertEqual(shown(ids), ids)
    }

    func testSixWithoutAnAdminOrganisationListTheFirstFive() {
        let ids = ["claude", "codex", "antigravity", "grok", "mistral", "extra"]
        XCTAssertEqual(shown(ids), Array(ids.prefix(5)))
    }

    /// The widget target cannot see the app's provider types, so the rule names the id itself.
    func testTheWidgetsAdminOrganisationIsTheAdminProvidersService() {
        let admin = AnthropicAdminProvider(adminKey: "", fetchCostReport: { _, _ in Data() })
        XCTAssertEqual(WidgetEntryRules.adminOrganisationServiceID, admin.serviceID)
    }

    func testFourOrFewerKeepTwoWindowsAndFiveGetOne() {
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 1), 2)
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 4), 2)
        XCTAssertEqual(WidgetEntryRules.windowRowsPerProvider(shown: 5), 1)
    }

    func testTwoRowsAreTheSessionAndTheFullestOtherWindow() {
        let claude = service("claude", buckets: [
            WidgetBucket(id: "seven_day", label: "All models", percent: 18, kind: "weekly"),
            WidgetBucket(id: "five_hour", label: "Session", percent: 42, kind: "session"),
            WidgetBucket(id: "seven_day_fable", label: "Fable only", percent: 24, kind: "modelSpecific"),
        ])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: claude, limit: 2).map(\.id), ["five_hour", "seven_day_fable"])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: claude, limit: 1).map(\.id), ["five_hour"])
    }

    func testOneRowWithoutASessionIsTheFullestWindow() {
        let mistral = service("mistral", buckets: [
            WidgetBucket(id: "mistral_vibe", label: "Vibe", percent: 6, kind: "weekly"),
            WidgetBucket(id: "mistral_api", label: "API", percent: 0, kind: "modelSpecific"),
        ])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: mistral, limit: 1).map(\.id), ["mistral_vibe"])
        XCTAssertEqual(WidgetEntryRules.windowRows(of: mistral, limit: 2).map(\.id), ["mistral_vibe", "mistral_api"])
    }
}
