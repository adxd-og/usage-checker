import XCTest
@testable import Omelette

/// Spec 2026-10-25 (Claude switch and sign-in) § Design › Package 1, Nothing on: the
/// widget's file gains one backward-compatible field, how many providers the app polls,
/// and `WidgetBridge`'s change comparison includes it. Two empty files can say different
/// things — every enabled provider signed out, every provider switched off — and a widget
/// told the first has to hear the second.
final class WidgetEnabledProvidersTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_793_100_000)

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

    func testTheFileSaysHowManyProvidersAreOn() {
        XCTAssertEqual(WidgetBridge.snapshot(from: [], at: at, mode: .used, enabledProviders: 0).enabledProviders, 0)
        let codex = Fixture.snapshot(
            id: "codex", buckets: [Fixture.bucket(id: "codex_session", percent: 30, kind: .session)], at: at
        )
        XCTAssertEqual(WidgetBridge.snapshot(from: [codex], at: at, mode: .used, enabledProviders: 3).enabledProviders, 3)
    }

    func testTheCountRoundTripsThroughTheFilesOwnEncoder() throws {
        let off = WidgetSnapshot(services: [], updatedAt: at, enabledProviders: 0)
        XCTAssertEqual(try decoder.decode(WidgetSnapshot.self, from: encoder.encode(off)).enabledProviders, 0)
    }

    func testAFileAnOlderBuildWroteOpensWithTheCountUnknown() throws {
        let json = #"{"services": [], "updatedAt": "2026-10-27T09:00:00Z", "showsRemaining": false}"#
        XCTAssertNil(try decoder.decode(WidgetSnapshot.self, from: Data(json.utf8)).enabledProviders)
    }

    func testAnUnknownCountLeavesTheKeyOutOfTheFile() throws {
        let unknown = String(decoding: try encoder.encode(WidgetSnapshot(services: [], updatedAt: at)), as: UTF8.self)
        XCTAssertFalse(unknown.contains("enabledProviders"), unknown)
        let off = String(
            decoding: try encoder.encode(WidgetSnapshot(services: [], updatedAt: at, enabledProviders: 0)), as: UTF8.self
        )
        XCTAssertTrue(off.contains(#""enabledProviders":0"#), off)
    }

    func testSwitchingTheLastProviderOffReachesTheFileEvenWithNothingToDraw() {
        let signedOut = WidgetBridge.Publication(services: [], enabledProviders: 2)
        let off = WidgetBridge.Publication(services: [], enabledProviders: 0)
        XCTAssertTrue(WidgetBridge.shouldPublish(off, lastPublished: signedOut))
        XCTAssertFalse(WidgetBridge.shouldPublish(off, lastPublished: off), "said once, not every minute")
        XCTAssertTrue(
            WidgetBridge.shouldPublish(signedOut, lastPublished: off),
            "a provider switched back on that has not reported yet"
        )
    }

    func testAFailedWriteOfTheCountIsTriedAgain() {
        let signedOut = WidgetBridge.Publication(services: [], enabledProviders: 2)
        let off = WidgetBridge.Publication(services: [], enabledProviders: 0)
        let afterFailure = WidgetBridge.recordedPublication(off, wrote: false, previous: signedOut)
        XCTAssertEqual(afterFailure, signedOut)
        XCTAssertTrue(WidgetBridge.shouldPublish(off, lastPublished: afterFailure))
    }
}
