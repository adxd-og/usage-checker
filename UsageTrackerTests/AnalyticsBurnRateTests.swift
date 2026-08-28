import XCTest
@testable import Omelette

final class AnalyticsBurnRateTests: XCTestCase {
    private let now = Date()

    func testProjectsTheLimitFromASteadyClimb() {
        // 10% → 40% over half an hour: 1%/min, 60% of the window left, so an hour to go.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 30, percent: 10), (minutesAgo: 0, percent: 40)],
            now: now
        )
        guard let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60) else {
            return XCTFail("a rising two-point history must produce a prediction")
        }
        XCTAssertEqual(burn.percentPerMinute, 1.0, accuracy: 0.0001)
        XCTAssertEqual(burn.secondsToLimit ?? 0, 60 * 60, accuracy: 1)
        XCTAssertEqual(burn.bucketId, "five_hour")
        XCTAssertFalse(burn.isStale)
    }

    func testFlatUsageProjectsNoLimit() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 30, percent: 40), (minutesAgo: 0, percent: 40)],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60)
        XCTAssertNotNil(burn)
        XCTAssertNil(burn?.secondsToLimit)
        XCTAssertEqual(burn?.percentPerMinute, 0)
    }

    func testASinglePointIsNotATrend() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 0, percent: 40)],
            now: now
        )
        XCTAssertNil(Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60))
        XCTAssertNil(Analytics.burnRate(records: [], bucketId: "five_hour", lookbackMinutes: 60))
    }

    func testRecordsOlderThanTheLookbackAreIgnored() {
        // The 50-minute-old point sat at 90%; including it would read as a *fall*
        // and produce no projection at all. Only the last two count.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [
                (minutesAgo: 50, percent: 90),
                (minutesAgo: 20, percent: 10),
                (minutesAgo: 5, percent: 25),
            ],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 30)
        XCTAssertEqual(burn?.percentPerMinute ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(burn?.secondsToLimit ?? 0, 75 * 60, accuracy: 1)
    }

    func testAPredictionFromStaleRecordsIsFlaggedStale() {
        let stale = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 70, percent: 10), (minutesAgo: 40, percent: 40)],
            now: now
        )
        XCTAssertEqual(
            Analytics.burnRate(records: stale, bucketId: "five_hour", lookbackMinutes: 120)?.isStale,
            true
        )

        let fresh = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 40, percent: 10), (minutesAgo: 10, percent: 40)],
            now: now
        )
        XCTAssertEqual(
            Analytics.burnRate(records: fresh, bucketId: "five_hour", lookbackMinutes: 120)?.isStale,
            false
        )
    }

    func testADifferentBucketHasNoHistoryOfItsOwn() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 30, percent: 10), (minutesAgo: 0, percent: 40)],
            now: now
        )
        XCTAssertNil(Analytics.burnRate(records: records, bucketId: "seven_day", lookbackMinutes: 60))
    }
}
