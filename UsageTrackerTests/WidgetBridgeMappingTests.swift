import XCTest
@testable import Omelette

/// `publish` writes into the App Group container, which a unit-test bundle has no
/// access to — so the mapping it does first is the part worth testing.
final class WidgetBridgeMappingTests: XCTestCase {
    func testARetainedProviderIsPassedThroughAndFlagged() throws {
        let service = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity", plan: "Antigravity Pro",
            buckets: [Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 62, kind: .weekly)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running"
        )

        let mapped = try XCTUnwrap(WidgetBridge.widgetServices(from: [service]).first)

        XCTAssertTrue(mapped.isRetained)
        XCTAssertEqual(mapped.buckets.map(\.id), ["antigravity_gemini"], "the numbers go through unchanged")
        XCTAssertEqual(mapped.buckets.first?.percent, 62)
        XCTAssertEqual(mapped.plan, "Antigravity Pro")
    }

    func testALiveProviderIsNotFlagged() throws {
        let service = Fixture.snapshot(
            id: "claude",
            buckets: [Fixture.bucket(id: "seven_day", percent: 55, kind: .weekly)]
        )
        let mapped = try XCTUnwrap(WidgetBridge.widgetServices(from: [service]).first)
        XCTAssertFalse(mapped.isRetained)
    }

    func testAProviderWithNothingToDrawIsStillDropped() {
        let bare = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)
        XCTAssertTrue(WidgetBridge.widgetServices(from: [bare]).isEmpty)
    }

    func testASpendLimitStillBecomesAWindow() throws {
        let service = Fixture.snapshot(
            id: "claude", plan: "Enterprise",
            buckets: [Fixture.bucket(id: "five_hour", percent: 40, kind: .session)],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 200, usedCredits: 156.4, utilization: 78.2)
        )
        let mapped = try XCTUnwrap(WidgetBridge.widgetServices(from: [service]).first)
        XCTAssertEqual(mapped.buckets.map(\.id), ["five_hour", "extra_usage"])
        XCTAssertEqual(mapped.buckets.last?.label, "Spend limit")
    }

    // MARK: - Decoding a file an older build wrote

    func testAWidgetServiceFromABuildWithoutIsRetainedStillDecodes() throws {
        // The shared file outlives an app update: the extension can be asked for a
        // timeline before the new app has published once, and what it finds is the
        // previous version's JSON — with no isRetained key in it. A property default
        // does not cover this; only the custom decoder does.
        let json = """
        {"id": "antigravity", "name": "Antigravity", "icon": "sparkles", "plan": "Pro",
         "buckets": [{"id": "antigravity_gemini", "label": "Gemini models", "percent": 62}]}
        """
        let service = try JSONDecoder().decode(WidgetService.self, from: Data(json.utf8))

        XCTAssertFalse(service.isRetained, "absent means live, not a decoding failure")
        XCTAssertEqual(service.buckets.map(\.id), ["antigravity_gemini"])
        XCTAssertNil(service.spendLabel)
    }

    func testARoundTripKeepsTheFlag() throws {
        let service = WidgetService(
            id: "antigravity", name: "Antigravity", icon: "sparkles", plan: nil,
            buckets: [], spendLabel: "$3.50 last 7 days", isRetained: true
        )
        let decoded = try JSONDecoder().decode(
            WidgetService.self, from: JSONEncoder().encode(service)
        )
        XCTAssertEqual(decoded, service)
    }
}
