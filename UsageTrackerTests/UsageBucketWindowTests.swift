import XCTest
@testable import Omelette

final class UsageBucketWindowTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600
    private let week: TimeInterval = 7 * 24 * 3600

    func testAReportedLengthBeatsTheInference() {
        // Gemini's per-model quotas are daily. Inference alone called every
        // model-scoped window a week, which is what made its pace indicator lie.
        let daily = Fixture.bucket(id: "gemini_pro", kind: .modelSpecific, windowLength: day)
        XCTAssertEqual(daily.windowDuration, day)

        let weeklyByInference = Fixture.bucket(id: "gemini_pro", kind: .modelSpecific)
        XCTAssertEqual(weeklyByInference.windowDuration, week)
    }

    func testAReportedLengthOverridesEvenAKnownAnthropicID() {
        let bucket = Fixture.bucket(id: "seven_day_opus", kind: .modelSpecific, windowLength: day)
        XCTAssertEqual(bucket.windowDuration, day)
        XCTAssertNotEqual(bucket.windowDuration, week)
    }

    func testInferenceIsUnchangedWithoutAReportedLength() {
        XCTAssertEqual(Fixture.bucket(id: "five_hour", kind: .session).windowDuration, 5 * 3600)
        XCTAssertEqual(Fixture.bucket(id: "seven_day", kind: .weekly).windowDuration, week)
        XCTAssertEqual(Fixture.bucket(id: "seven_day_opus", kind: .modelSpecific).windowDuration, week)
        XCTAssertEqual(Fixture.bucket(id: "codex_session", kind: .session).windowDuration, 5 * 3600)
        XCTAssertNil(Fixture.bucket(id: "grok_credits", kind: .other).windowDuration)
    }

    func testANonsensicalLengthFallsBackToInference() {
        XCTAssertEqual(Fixture.bucket(id: "seven_day", kind: .weekly, windowLength: 0).windowDuration, week)
        XCTAssertEqual(Fixture.bucket(id: "seven_day", kind: .weekly, windowLength: -60).windowDuration, week)
    }

    func testElapsedFractionUsesTheReportedLength() {
        let now = Date()
        let sixHoursLeft = now.addingTimeInterval(6 * 3600)

        let daily = Fixture.bucket(
            id: "gemini_pro", resetsAt: sixHoursLeft, kind: .modelSpecific, windowLength: day
        )
        XCTAssertEqual(try XCTUnwrap(daily.elapsedFraction(now: now)), 0.75, accuracy: 0.0001)

        // The same window inferred as weekly reads as barely started — the bug.
        let inferred = Fixture.bucket(id: "gemini_pro", resetsAt: sixHoursLeft, kind: .modelSpecific)
        XCTAssertEqual(try XCTUnwrap(inferred.elapsedFraction(now: now)), 1 - (6 * 3600) / week, accuracy: 0.0001)
    }

    func testElapsedFractionIsNilWhenTheRemainderExceedsTheWindow() {
        let now = Date()
        let bucket = Fixture.bucket(
            id: "gemini_pro",
            resetsAt: now.addingTimeInterval(2 * day),
            kind: .modelSpecific,
            windowLength: day
        )
        XCTAssertNil(bucket.elapsedFraction(now: now))
    }

    func testAPersistedBucketWithoutALengthStillDecodes() throws {
        let legacy = """
        {"id":"five_hour","label":"Current session","utilization":42.0,
         "resetsAt":768000000.0,"kind":"session"}
        """
        let bucket = try JSONDecoder().decode(UsageBucket.self, from: Data(legacy.utf8))

        XCTAssertNil(bucket.windowLength)
        XCTAssertEqual(bucket.windowDuration, 5 * 3600)
        XCTAssertEqual(bucket.utilization, 42.0)
    }

    func testAReportedLengthSurvivesARoundTrip() throws {
        let original = Fixture.bucket(
            id: "gemini_pro", resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .modelSpecific, windowLength: day
        )
        let decoded = try JSONDecoder().decode(
            UsageBucket.self, from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.windowLength, day)
    }
}
