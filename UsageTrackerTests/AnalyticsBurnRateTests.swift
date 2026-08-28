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

        // Ends 5 minutes ago — inside the 10-minute staleness mark. (It used to be 30
        // minutes, which equalled the default lookback and could therefore never fire.)
        let fresh = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 40, percent: 10), (minutesAgo: 5, percent: 40)],
            now: now
        )
        XCTAssertEqual(
            Analytics.burnRate(records: fresh, bucketId: "five_hour", lookbackMinutes: 120)?.isStale,
            false
        )
    }

    func testStalenessIsReachableAtTheDefaultLookback() {
        // The regression this guards: with `isStale` set at 30 minutes and the default
        // 30-minute lookback, every point in the slice was younger than the mark by
        // construction, so no prediction was ever flagged and `pacingAdvice` never
        // rejected one for age.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 28, percent: 10), (minutesAgo: 20, percent: 40)],
            now: now
        )
        XCTAssertEqual(Analytics.burnRate(records: records, bucketId: "five_hour")?.isStale, true)
    }

    // MARK: - Guards

    func testTwoPointsTooCloseTogetherAreNotATrend() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 20.0 / 60.0, percent: 10), (minutesAgo: 0, percent: 40)],
            now: now
        )
        XCTAssertNil(Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60))
    }

    func testTheMinimumLegalSpacingStillCounts() {
        // The history store spaces points at least 30 seconds apart, so exactly half a
        // minute is the tightest real pair — `> 0.5` threw it away.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 0.5, percent: 10), (minutesAgo: 0, percent: 40)],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60)
        XCTAssertEqual(burn?.percentPerMinute ?? 0, 60, accuracy: 0.0001)
    }

    func testACrawlIsReportedButNotProjected() {
        // 0.04%/min: real growth, but too slow to call — projecting it would promise a
        // limit more than a day out from ten minutes of data.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 10, percent: 10), (minutesAgo: 0, percent: 10.4)],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60)
        XCTAssertEqual(burn?.percentPerMinute ?? -1, 0.04, accuracy: 0.0001)
        XCTAssertNil(burn?.secondsToLimit)
    }

    func testThereIsNothingLeftToProjectAtAHundredPercent() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 30, percent: 70), (minutesAgo: 0, percent: 100)],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60)
        XCTAssertNil(burn?.secondsToLimit)
        XCTAssertEqual(burn?.percentPerMinute ?? 0, 1.0, accuracy: 0.0001)
    }

    func testFallingUsageIsNeverANegativeRate() {
        // A drift down inside one window (rounding, a corrected server figure). Small
        // enough not to read as a reset.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 30, percent: 40), (minutesAgo: 0, percent: 35)],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour", lookbackMinutes: 60)
        XCTAssertEqual(burn?.percentPerMinute, 0)
        XCTAssertNil(burn?.secondsToLimit)
    }

    // MARK: - Resets inside the lookback

    func testTheRateIsMeasuredOnTheWindowThatIsOpenNow() {
        // 92% → the window resets → 4% → 38% in twelve minutes. End to end that is a
        // FALL, so the prediction used to vanish for a full lookback — exactly the half
        // hour after a reset when "you're burning fast" is worth saying.
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [
                (minutesAgo: 25, percent: 92),
                (minutesAgo: 13, percent: 4),
                (minutesAgo: 1, percent: 38),
            ],
            now: now
        )
        guard let burn = Analytics.burnRate(records: records, bucketId: "five_hour") else {
            return XCTFail("the post-reset climb is a trend of its own")
        }
        let expectedRate: Double = (38 - 4) / 12
        let expectedSeconds: Double = (100 - 38) / expectedRate * 60
        XCTAssertEqual(burn.percentPerMinute, expectedRate, accuracy: 0.0001)
        XCTAssertEqual(burn.secondsToLimit ?? 0, expectedSeconds, accuracy: 1)
    }

    func testOnePointAfterAResetIsNotATrend() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [(minutesAgo: 20, percent: 90), (minutesAgo: 5, percent: 10)],
            now: now
        )
        XCTAssertNil(Analytics.burnRate(records: records, bucketId: "five_hour"))
    }

    func testAMonotonicSeriesIsLeftAlone() {
        let records = Fixture.history(
            bucketID: "five_hour",
            points: [
                (minutesAgo: 20, percent: 10),
                (minutesAgo: 10, percent: 20),
                (minutesAgo: 0, percent: 30),
            ],
            now: now
        )
        let burn = Analytics.burnRate(records: records, bucketId: "five_hour")
        XCTAssertEqual(burn?.percentPerMinute ?? 0, 1.0, accuracy: 0.0001)
    }

    func testRecordsOutOfChronologicalOrderReadTheSame() {
        let points: [(minutesAgo: Double, percent: Double)] = [
            (minutesAgo: 20, percent: 10),
            (minutesAgo: 0, percent: 30),
            (minutesAgo: 10, percent: 20),
        ]
        let shuffled = Fixture.history(bucketID: "five_hour", points: points, now: now)
        let burn = Analytics.burnRate(records: shuffled, bucketId: "five_hour")
        XCTAssertEqual(burn?.percentPerMinute ?? 0, 1.0, accuracy: 0.0001)
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
