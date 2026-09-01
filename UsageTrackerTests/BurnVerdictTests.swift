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
