import XCTest
@testable import Omelette

/// Independent verification of the pure view-rule statics: `OMProviderTile.accessibilityText`
/// and `OverviewView.burnValue`/`burnLine`. Different fixtures from the executor's own
/// `OMProviderTileTextTests.swift` / `BurnVerdictTests.swift`, so a copy-paste error in
/// either wouldn't be caught by re-running the same inputs.
final class ViewRulesVerificationTests: XCTestCase {
    // MARK: - OMProviderTile.accessibilityText

    func testATileWithBucketsButNoStateMessageIsStillMarkedLastKnown() {
        let hero = Fixture.bucket(id: "seven_day", label: "All models", percent: 88)
        let service = Fixture.snapshot(
            id: "gemini", displayName: "Gemini", buckets: [hero], state: .error, stateMessage: nil
        )
        XCTAssertEqual(
            OMProviderTile.accessibilityText(for: service, hero: hero),
            "Gemini, All models 88 percent used, last known, Error"
        )
    }

    func testATileWithBucketsAndOkStateNeverSaysLastKnown() {
        let hero = Fixture.bucket(id: "five_hour", label: "Session", percent: 12)
        let service = Fixture.snapshot(id: "grok", displayName: "Grok", buckets: [hero], state: .ok)
        let text = OMProviderTile.accessibilityText(for: service, hero: hero)
        XCTAssertFalse(text.contains("last known"), "a healthy tile's accessibility text must not say last known: \(text)")
    }

    // MARK: - OverviewView.burnValue / burnLine

    func testBurnValueDefaultsToNotRetained() {
        // The default parameter matters: a call site that forgets `retained:` must
        // not accidentally suppress a live prediction.
        XCTAssertEqual(
            OverviewView.burnValue(Fixture.prediction(secondsToLimit: 3600)),
            "Hit limit in 1h 0m"
        )
    }

    func testBurnValueIdleWhenThereIsNoUpwardSlope() {
        XCTAssertEqual(
            OverviewView.burnValue(Fixture.prediction(secondsToLimit: nil, percentPerMinute: 0), retained: false),
            "Idle"
        )
    }

    func testBurnLineNeverSaysPausedForALiveProvider() {
        let bucket = Fixture.bucket(id: "seven_day", label: "All models", percent: 40, kind: .weekly)
        let line = OverviewView.burnLine(burn: Fixture.prediction(secondsToLimit: 3600), bucket: bucket, retained: false)
        XCTAssertFalse(line.contains("Paused"), "a live provider's burn line must never say Paused: \(line)")
    }
}
