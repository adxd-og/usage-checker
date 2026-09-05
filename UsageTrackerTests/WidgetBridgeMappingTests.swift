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
}
