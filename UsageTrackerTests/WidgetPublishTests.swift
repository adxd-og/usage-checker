import XCTest
@testable import Omelette

/// When the app writes the widget's file. Spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Retention —
/// "`WidgetBridge.publish` may write an empty snapshot and is called from
/// `forgetLastKnown` and whenever the published services changed." The App Group
/// container is out of reach in tests; the gate and the mapping are what is tested.
final class WidgetPublishTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_788_000_000)

    private var claude: WidgetService {
        WidgetService(
            id: "claude", name: "Claude", icon: "sparkles", plan: nil,
            buckets: [WidgetBucket(id: "five_hour", label: "Session", percent: 40, kind: "session")]
        )
    }

    /// The services half of a publication; the count is the same on both sides, so only
    /// the rows decide, as these tests always meant.
    private func publication(_ services: [WidgetService]) -> WidgetBridge.Publication {
        WidgetBridge.Publication(services: services, enabledProviders: 2)
    }

    func testSomethingToDrawIsWrittenEveryPoll() {
        XCTAssertTrue(WidgetBridge.shouldPublish(publication([claude]), lastPublished: publication([claude])),
                      "\"Updated …\" has to move with every poll")
        XCTAssertTrue(WidgetBridge.shouldPublish(publication([claude]), lastPublished: nil))
    }

    func testNothingToDrawIsWrittenOnceWhenItBecomesNothing() {
        XCTAssertTrue(WidgetBridge.shouldPublish(publication([]), lastPublished: publication([claude])))
        XCTAssertFalse(WidgetBridge.shouldPublish(publication([]), lastPublished: publication([])),
                       "reloading every widget each minute to say nothing again is waste")
    }

    func testALaunchWithNothingToDrawClearsWhatAnEarlierRunLeft() {
        XCTAssertTrue(WidgetBridge.shouldPublish(publication([]), lastPublished: nil))
    }

    func testForgettingTheOnlyRetainedProviderEmptiesTheWidget() {
        // The report's case: Antigravity retained, every other provider without windows.
        let antigravity = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62)],
            state: .notRunning, at: at
        )
        let codex = Fixture.snapshot(id: "codex", plan: nil, buckets: [], state: .notSignedIn, at: at)
        let before = UsageSnapshot(services: [antigravity, codex], fetchedAt: at, isStale: true, lastError: nil)

        let after = AppState.droppingRetained(serviceID: "antigravity", from: before)

        XCTAssertFalse(after.hasAnyData, "the old `if next.hasAnyData` gate never published this")
        let written = WidgetBridge.snapshot(from: after.services, at: after.fetchedAt, mode: .used)
        XCTAssertTrue(written.services.isEmpty)
        XCTAssertTrue(WidgetBridge.shouldPublish(
            publication(written.services), lastPublished: publication(WidgetBridge.widgetServices(from: before.services))
        ))
    }

    func testAWindowlessAccountReachesTheWidget() {
        let payAsYouGo = Fixture.snapshot(id: "claude", buckets: [], weekCost: 31.7, at: at)
        XCTAssertFalse(
            UsageSnapshot(services: [payAsYouGo], fetchedAt: at, isStale: false, lastError: nil).hasAnyData,
            "the old gate skipped a spend-only account"
        )
        let services = WidgetBridge.widgetServices(from: [payAsYouGo])
        XCTAssertEqual(services.first?.spendLabel, "$31.70 last 7 days")
        XCTAssertTrue(WidgetBridge.shouldPublish(publication(services), lastPublished: publication(services)))
    }
}
