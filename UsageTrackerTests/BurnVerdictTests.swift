import XCTest
@testable import Omelette

final class BurnVerdictTests: XCTestCase {
    func testFormatBurn() {
        XCTAssertEqual(BurnVerdict.formatBurn(2 * 3600 + 15 * 60), "2h 15m")
        XCTAssertEqual(BurnVerdict.formatBurn(45 * 60), "45m")
        XCTAssertEqual(BurnVerdict.formatBurn(3 * 86400 + 3600), "3d")
    }

    func testNilWithoutPrediction() {
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: Date().addingTimeInterval(3600), kind: .session)
        XCTAssertNil(BurnVerdict.make(burn: nil, sessionBuckets: [session]))
    }

    func testWillHitWhenLimitComesBeforeReset() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(2 * 3600), kind: .session)
        let burn = Fixture.prediction(secondsToLimit: 30 * 60, bucketId: "five_hour")
        let verdict = BurnVerdict.make(burn: burn, sessionBuckets: [session], now: now)
        XCTAssertEqual(verdict, BurnVerdict(willHit: true, text: "At this pace, limit in ~30m"))
    }

    func testSafeWhenResetComesFirst() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(30 * 60), kind: .session)
        let burn = Fixture.prediction(secondsToLimit: 2 * 3600, bucketId: "five_hour")
        let verdict = BurnVerdict.make(burn: burn, sessionBuckets: [session], now: now)
        XCTAssertEqual(verdict, BurnVerdict(willHit: false, text: "At this pace you won't hit the limit before reset"))
    }

    func testNilWhenPredictionIsStaleOrForAnotherBucket() {
        let now = Date()
        let session = Fixture.bucket(id: "five_hour", percent: 40, resetsAt: now.addingTimeInterval(3600), kind: .session)
        XCTAssertNil(BurnVerdict.make(burn: Fixture.prediction(secondsToLimit: 60, bucketId: "seven_day"), sessionBuckets: [session], now: now))
        XCTAssertNil(BurnVerdict.make(burn: Fixture.prediction(secondsToLimit: 60, bucketId: "five_hour", isStale: true), sessionBuckets: [session], now: now))
    }
}

/// The line the Overview hero falls back to when `BurnVerdict.make` returns nil —
/// stale prediction, no prediction, or growth too flat to extrapolate. Its wording is
/// the pre-hero burn card's, verbatim, so those states stay visible.
final class OverviewBurnLineTests: XCTestCase {
    func testTheLineNamesTheWindowItPredicts() {
        let bucket = Fixture.bucket(id: "five_hour", label: "5-hour", kind: .session)
        XCTAssertEqual(
            OverviewView.burnLine(burn: Fixture.prediction(secondsToLimit: nil, percentPerMinute: 1), bucket: bucket),
            "5-hour burn rate · Stable"
        )
    }

    func testFlatGrowthReadsAsIdle() {
        XCTAssertEqual(
            OverviewView.burnLine(burn: Fixture.prediction(secondsToLimit: nil, percentPerMinute: 0), bucket: nil),
            "Burn rate · Idle"
        )
    }

    func testNoPredictionAtAllSaysSo() {
        XCTAssertEqual(OverviewView.burnLine(burn: nil, bucket: nil), "Burn rate · Not enough data")
    }

    func testAPredictedLimitKeepsTheOldWording() {
        let bucket = Fixture.bucket(id: "five_hour", label: "Session", kind: .session)
        XCTAssertEqual(
            OverviewView.burnLine(burn: Fixture.prediction(secondsToLimit: 2 * 3600 + 15 * 60), bucket: bucket),
            "Session burn rate · Hit limit in 2h 15m"
        )
    }

    // MARK: - Retained

    func testARetainedProviderBurnsNothing() {
        // The numbers stopped moving with the provider; extrapolating from them
        // would predict a limit the user is not walking towards.
        XCTAssertEqual(
            OverviewView.burnValue(Fixture.prediction(secondsToLimit: 2 * 3600), retained: true),
            "Paused"
        )
        XCTAssertEqual(OverviewView.burnValue(nil, retained: true), "Paused")
    }

    func testALiveProviderStillPredicts() {
        XCTAssertEqual(
            OverviewView.burnValue(Fixture.prediction(secondsToLimit: 2 * 3600), retained: false),
            "Hit limit in 2h 0m"
        )
    }

    func testTheHeroCaptionSaysPausedToo() {
        let bucket = Fixture.bucket(id: "seven_day", label: "All models", percent: 62, kind: .weekly)
        XCTAssertEqual(
            OverviewView.burnLine(burn: Fixture.prediction(secondsToLimit: 2 * 3600), bucket: bucket, retained: true),
            "All models burn rate · Paused"
        )
    }
}
