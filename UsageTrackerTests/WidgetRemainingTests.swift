import XCTest
@testable import Omelette

/// The App Group file. The extension updates on its own schedule and can be asked
/// for a timeline before the new app has ever published, so the snapshot it finds
/// may be whatever the previous version left there — the new key has to decode as
/// absent, never as a failure. Spec § "Propagation" — "WidgetSnapshot gains
/// showsRemaining: Bool (Codable with a default so an older snapshot decodes;
/// explicit init(from:) as the existing isRetained does)".
final class WidgetRemainingTests: XCTestCase {
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testASnapshotWrittenByAnOlderBuildStillOpens() throws {
        // No "showsRemaining" key at all — exactly what 2.4.1 wrote.
        let json = """
        {
            "services": [
                {"id": "claude", "name": "Claude", "icon": "sparkles", "plan": "Max 20x", "buckets": []}
            ],
            "updatedAt": 780000000.0
        }
        """
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.services.count, 1)
        XCTAssertFalse(snapshot.showsRemaining, "an absent key is the old behaviour, not a decode failure")
        XCTAssertEqual(snapshot.mode, .used)
    }

    func testTheFlagRoundTripsThroughTheFilesOwnEncoder() throws {
        let original = WidgetSnapshot(
            services: [WidgetService(id: "claude", name: "Claude", icon: "sparkles", plan: nil,
                                     buckets: [WidgetBucket(id: "five_hour", label: "Session", percent: 42)])],
            updatedAt: Date(timeIntervalSince1970: 1_788_693_600),
            showsRemaining: true
        )
        let back = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(original))
        XCTAssertTrue(back.showsRemaining)
        XCTAssertEqual(back.mode, .remaining)
        XCTAssertEqual(back.services.first?.buckets.first?.percent, 42, "the numbers in the file stay used")
    }

    func testThePlaceholderCountsUpLikeAFreshInstall() {
        XCTAssertFalse(WidgetSnapshot.placeholder.showsRemaining)
    }

    func testTheBridgeCarriesTheSwitchAndLeavesTheNumbersAlone() throws {
        let service = Fixture.snapshot(
            id: "claude", displayName: "Claude", plan: "Max 20x",
            buckets: [Fixture.bucket(id: "seven_day", label: "All models", percent: 62, kind: .weekly)]
        )
        let at = Date(timeIntervalSince1970: 1_788_693_600)

        let up = WidgetBridge.snapshot(from: [service], at: at, mode: .used)
        XCTAssertFalse(up.showsRemaining)

        let down = WidgetBridge.snapshot(from: [service], at: at, mode: .remaining)
        XCTAssertTrue(down.showsRemaining)
        XCTAssertEqual(down.updatedAt, at)
        XCTAssertEqual(
            try XCTUnwrap(down.services.first?.buckets.first?.percent), 62,
            "the file records what is used; only the flag says how to draw it"
        )
    }

    func testASignedOutProviderIsStillDroppedWhicheverWayTheAppCounts() {
        let bare = Fixture.snapshot(id: "codex", buckets: [], state: .notSignedIn)
        XCTAssertTrue(WidgetBridge.snapshot(from: [bare], at: Date(), mode: .remaining).services.isEmpty)
    }

    // MARK: - What the extension draws

    func testTheSmallWidgetsRingAndNumberFollowTheFlag() throws {
        let bucket = WidgetBucket(id: "five_hour", label: "Session", percent: 42, kind: "session")
        let service = WidgetService(id: "claude", name: "Claude", icon: "sparkles",
                                    plan: "Max 20x", buckets: [bucket])
        let headline = try XCTUnwrap(service.headlineBucket)
        XCTAssertEqual(PercentDisplay.percentText(headline.percent, mode: .remaining), "58%")
        XCTAssertEqual(OMRing.geometry(used: headline.percent, mode: .remaining).trim, 0.58, accuracy: 0.0001)
        XCTAssertEqual(OMRing.geometry(used: headline.percent, mode: .remaining).color, .green)
    }

    func testAPayAsYouGoWidgetHasAnEmptyRingRatherThanAFullOne() {
        let service = WidgetService(id: "claude", name: "Claude", icon: "sparkles", plan: nil,
                                    buckets: [], spendLabel: "$41.37 last 7 days")
        XCTAssertNil(service.headlineBucket)
        XCTAssertEqual(OMRing.geometry(used: service.headlineBucket?.percent, mode: .remaining).trim, 0)
    }

    func testTheHeadlineWindowIsStillChosenByHowFullItIs() {
        let service = WidgetService(
            id: "gemini", name: "Gemini", icon: "diamond", plan: nil,
            buckets: [
                WidgetBucket(id: "a", label: "Quiet", percent: 5, kind: "weekly"),
                WidgetBucket(id: "b", label: "Busy", percent: 91, kind: "weekly"),
            ]
        )
        XCTAssertEqual(service.headlineBucket?.id, "b")
    }
}
