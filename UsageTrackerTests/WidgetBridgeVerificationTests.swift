import XCTest
@testable import Omelette

/// Independent verification of `WidgetBridge.widgetServices(from:)` and of
/// `WidgetService`'s backward-compatible decoding, attacking the one case the
/// executor's own `WidgetBridgeMappingTests.swift` never exercises: a widget
/// snapshot written by a build that predates `isRetained` entirely.
final class WidgetBridgeVerificationTests: XCTestCase {
    func testDecodingAnOldWidgetServiceWithNoIsRetainedKeyDefaultsToFalse() throws {
        // No "isRetained" key at all — exactly what an older build wrote to disk.
        let json = """
        {
            "id": "claude",
            "name": "Claude",
            "icon": "sparkles",
            "plan": "Max 20x",
            "buckets": []
        }
        """
        let decoder = JSONDecoder()
        let service = try decoder.decode(WidgetService.self, from: Data(json.utf8))
        XCTAssertFalse(service.isRetained, "an old snapshot with no isRetained key must decode, defaulting to false")
    }

    func testDecodingAnOldWidgetSnapshotEnvelopeWithNoIsRetainedKeyWorks() throws {
        let json = """
        {
            "services": [
                {"id": "codex", "name": "Codex", "icon": "terminal", "plan": null, "buckets": []}
            ],
            "updatedAt": 780000000.0
        }
        """
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.services.count, 1)
        XCTAssertFalse(snapshot.services[0].isRetained)
    }

    func testWidgetServicesSetsIsRetainedTrueOnlyForARetainedProvider() throws {
        let retained = Fixture.snapshot(
            id: "antigravity", displayName: "Antigravity",
            buckets: [Fixture.bucket(id: "antigravity_gemini", percent: 62, kind: .weekly)],
            state: .notRunning, stateMessage: "Antigravity isn't running"
        )
        let live = Fixture.snapshot(
            id: "claude", buckets: [Fixture.bucket(id: "seven_day", percent: 40, kind: .weekly)]
        )
        let mapped = WidgetBridge.widgetServices(from: [retained, live])
        let mappedRetained = try XCTUnwrap(mapped.first(where: { $0.id == "antigravity" }))
        let mappedLive = try XCTUnwrap(mapped.first(where: { $0.id == "claude" }))
        XCTAssertTrue(mappedRetained.isRetained)
        XCTAssertFalse(mappedLive.isRetained)
    }
}
