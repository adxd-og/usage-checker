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

/// The burn-rate card Overview shows in place of the rings when a provider has no window
/// to draw: its title names the window the prediction is for, its value says what the
/// prediction is. The wording is the pre-hero burn card's, verbatim.
final class OverviewBurnCardTests: XCTestCase {
    func testTheTitleNamesTheWindowItPredicts() {
        XCTAssertEqual(OverviewView.burnTitle(Fixture.bucket(id: "five_hour", label: "5-hour", kind: .session)),
                       "5-hour burn rate")
        XCTAssertEqual(OverviewView.burnTitle(Fixture.bucket(id: "five_hour", label: "Session", kind: .session)),
                       "Session burn rate")
        XCTAssertEqual(OverviewView.burnTitle(nil), "Burn rate")
    }

    func testGrowthWithNoLimitInSightReadsAsStable() {
        XCTAssertEqual(OverviewView.burnValue(Fixture.prediction(secondsToLimit: nil, percentPerMinute: 1)), "Stable")
    }

    func testFlatGrowthReadsAsIdle() {
        XCTAssertEqual(OverviewView.burnValue(Fixture.prediction(secondsToLimit: nil, percentPerMinute: 0)), "Idle")
    }

    func testNoPredictionAtAllSaysSo() {
        XCTAssertEqual(OverviewView.burnValue(nil), "Not enough data")
    }

    func testAPredictedLimitKeepsTheOldWording() {
        XCTAssertEqual(OverviewView.burnValue(Fixture.prediction(secondsToLimit: 2 * 3600 + 15 * 60)), "Hit limit in 2h 15m")
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
}
