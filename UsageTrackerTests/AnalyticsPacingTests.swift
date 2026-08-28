import XCTest
@testable import Omelette

/// The interesting half of `pacingAdvice` is what does NOT fire, so most of these
/// assert nil: a pace that resets in time isn't a problem, and a reset is only news
/// when the user is actually pressed against the limit.
final class AnalyticsPacingTests: XCTestCase {
    private let lead: TimeInterval = 45 * 60
    private let resetLead: TimeInterval = 15 * 60
    private let highWaterMark: Double = 80

    private func advice(
        percent: Double,
        untilReset: TimeInterval,
        prediction: BurnRatePrediction?,
        wantsPace: Bool = true,
        wantsReset: Bool = true
    ) -> PacingAdvice? {
        Analytics.pacingAdvice(
            percent: percent,
            untilReset: untilReset,
            prediction: prediction,
            leadSeconds: lead,
            resetLeadSeconds: resetLead,
            highWaterMark: highWaterMark,
            wantsPace: wantsPace,
            wantsReset: wantsReset
        )
    }

    // MARK: - Pace

    func testWarnsWhenLimitArrivesLongBeforeTheReset() {
        let result = advice(
            percent: 50,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: 1800)
        )
        XCTAssertEqual(result, .burningFast(secondsToLimit: 1800))
    }

    func testSilentWhenTheWindowResetsBeforeTheLimitIsHit() {
        // Same 30-minute pace, but the window starts over in 20 minutes: nothing to do.
        XCTAssertNil(advice(
            percent: 50,
            untilReset: 20 * 60,
            prediction: Fixture.prediction(secondsToLimit: 1800)
        ))
    }

    func testSilentWhenTheLimitIsBeyondTheWarningHorizon() {
        XCTAssertNil(advice(
            percent: 50,
            untilReset: 5 * 3600,
            prediction: Fixture.prediction(secondsToLimit: 2 * 3600)
        ))
    }

    func testFiresWhenTheLimitLandsExactlyOnTheLead() {
        let result = advice(
            percent: 50,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: lead)
        )
        XCTAssertEqual(result, .burningFast(secondsToLimit: lead))
    }

    func testSilentWithoutAUsablePrediction() {
        XCTAssertNil(advice(percent: 50, untilReset: 3 * 3600, prediction: nil))
        XCTAssertNil(advice(
            percent: 50,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: nil)
        ))
        XCTAssertNil(advice(
            percent: 50,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: 1800, isStale: true)
        ))
    }

    func testSilentAtAHundredPercent() {
        // Already spent: a pace warning has nothing left to warn about.
        XCTAssertNil(advice(
            percent: 100,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: 1800)
        ))
    }

    func testSilentWhenPaceAlertsAreOff() {
        XCTAssertNil(advice(
            percent: 50,
            untilReset: 3 * 3600,
            prediction: Fixture.prediction(secondsToLimit: 1800),
            wantsPace: false
        ))
    }

    // MARK: - Reset

    func testWarnsWhenPressedAgainstAWindowThatIsAboutToReset() {
        XCTAssertEqual(
            advice(percent: 88, untilReset: 10 * 60, prediction: nil),
            .aboutToReset
        )
    }

    func testSilentWhenTheResetFindsPlentyOfHeadroom() {
        XCTAssertNil(advice(percent: 40, untilReset: 10 * 60, prediction: nil))
    }

    func testSilentWhenTheResetIsStillFarOff() {
        XCTAssertNil(advice(percent: 88, untilReset: 40 * 60, prediction: nil))
    }

    func testSilentWhenResetAlertsAreOff() {
        XCTAssertNil(advice(percent: 88, untilReset: 10 * 60, prediction: nil, wantsReset: false))
    }

    // MARK: - Precedence and bounds

    func testResetOutranksPaceWhenBothApply() {
        XCTAssertEqual(
            advice(
                percent: 90,
                untilReset: 10 * 60,
                prediction: Fixture.prediction(secondsToLimit: 5 * 60)
            ),
            .aboutToReset
        )
    }

    func testSilentOnceTheWindowHasAlreadyReset() {
        for untilReset in [0, -60] as [TimeInterval] {
            XCTAssertNil(
                advice(
                    percent: 95,
                    untilReset: untilReset,
                    prediction: Fixture.prediction(secondsToLimit: 300)
                ),
                "untilReset \(untilReset) should produce no advice"
            )
        }
    }
}
