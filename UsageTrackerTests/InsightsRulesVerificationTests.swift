import XCTest
@testable import Omelette

/// Independent verification of `InsightsRules` against the liquid-glass spec (§ Screens,
/// "Insights"; § Decisions, "What limit hit counts") and the P6 plan's session ruling 5
/// (model split). Written from the spec and the diff, not from the executor's
/// `InsightsRulesTests.swift`.
final class InsightsRulesVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// Noon UTC, `offset` days from `now`.
    private func noon(_ offset: Int) -> Date {
        now.addingTimeInterval(Double(offset) * 86_400)
    }

    private func model(
        _ name: String, _ cost: Double
    ) -> (model: String, cost: Double, tokens: Int, breakdown: TokenBreakdown) {
        (model: name, cost: cost, tokens: 1, breakdown: .zero)
    }

    // MARK: - Days at limit: the span is fixed, not merely defaulted

    /// Ten days of readings all at capacity; only the last seven (today included) may be
    /// counted. A test that only supplied seven days of fixture data could pass even if
    /// the production code accidentally walked more than `daysAtLimitSpan`.
    func testDaysAtLimitNeverCountsMoreThanTheLastSevenDaysEvenWhenTenAreAtCapacity() {
        let history = Fixture.quotaHistory(
            service: "claude",
            points: (-9...0).map { offset in (noon(offset), ["five_hour": 100.0]) }
        )

        let days = InsightsRules.daysAtLimit(
            records: history, bucketIDs: ["five_hour"], now: now, calendar: utc
        )

        XCTAssertEqual(days, QuotaDaysAtCapacity(atCapacity: 7, observed: 7, span: 7))
    }

    // MARK: - Model split

    /// A single model with dollars takes the whole bar: one slice, fraction 1, not
    /// "Other" (`isOther` only applies past the third model).
    func testModelSplitWithOneModelTakesTheWholeBarAndIsNotOther() {
        let split = InsightsRules.modelSplit([model("Opus 5", 42)])

        XCTAssertEqual(split, [InsightsModelShare(model: "Opus 5", cost: 42, fraction: 1, isOther: false)])
    }

    /// Session ruling 5, precisely: past three models with dollars, the third slice is
    /// "Other" summing every model past the top two — checked at the exact boundary of
    /// four models (one past the three-model threshold), not five or six as the
    /// executor's tests do.
    func testModelSplitWithExactlyFourModelsSumsTheTwoPastTheTopTwoIntoOther() {
        let split = InsightsRules.modelSplit([
            model("Sonnet", 10), model("Opus", 40), model("Haiku", 6), model("Fable", 4)
        ])

        XCTAssertEqual(split.map(\.model), ["Opus", "Sonnet", "Other"])
        XCTAssertEqual(split.map(\.isOther), [false, false, true])
        guard split.count == 3 else { return XCTFail("three slices expected, got \(split.count)") }
        XCTAssertEqual(split[2].cost, 10, accuracy: 1e-9)  // Haiku 6 + Fable 4
        XCTAssertEqual(split.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
    }

    /// Exactly three models with dollars keep three named slices — the boundary just
    /// below where "Other" appears must not tip over early.
    func testModelSplitWithExactlyThreeModelsHasNoOtherSlice() {
        let split = InsightsRules.modelSplit([model("A", 1), model("B", 1), model("C", 1)])

        XCTAssertEqual(split.count, 3)
        XCTAssertFalse(split.contains(where: \.isOther))
    }

    /// Ties at the cutoff between "named" and "summed into Other" go alphabetically, the
    /// same rule as every other ranking on this tab: equal costs must not let dictionary
    /// iteration order decide which model keeps its own slice.
    func testModelSplitTiesAtTheCutoffGoAlphabetical() {
        // B and A tie at the top; C and D tie for third/fourth. Alphabetical order
        // ("A" before "B", "C" before "D") must decide both.
        let split = InsightsRules.modelSplit([
            model("B", 5), model("A", 5), model("D", 3), model("C", 3)
        ])

        XCTAssertEqual(split.map(\.model), ["A", "B", "Other"])
        XCTAssertEqual(split[2].cost, 6, accuracy: 1e-9)  // C's 3 + D's 3
    }

    /// Fractions sum to 1 (accounting rounding aside) whatever the model count, and a
    /// model with zero dollars never appears, including when it sits among models that
    /// would otherwise be summed into "Other".
    func testModelSplitFractionsSumToOneAndZeroDollarModelsAreDroppedAtEveryCount() {
        for models in [
            [model("A", 10)],
            [model("A", 10), model("B", 5)],
            [model("A", 10), model("B", 5), model("C", 0), model("D", 2)],
            [model("A", 10), model("B", 5), model("C", 3), model("D", 2), model("E", 0), model("F", 1)]
        ] {
            let split = InsightsRules.modelSplit(models)
            XCTAssertEqual(split.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9, "for \(models.map(\.model))")
            XCTAssertFalse(split.contains(where: { $0.cost == 0 }), "a zero-dollar slice leaked through")
        }
    }

    // MARK: - This week vs last: the flat-week case (session ruling 8)

    /// Ruling 8: a flat week (no change at all, not merely a change that rounds to
    /// zero) reads "0%" with no arrow — the same code path as a near-zero change, but
    /// worth pinning at the exact value the ruling names.
    func testWeekOverWeekExactlyFlatHasNoDirectionInTheRawDelta() throws {
        let week = WeekOverWeek(thisWeek: 500, lastWeek: 500)

        let delta = try XCTUnwrap(week.deltaPercent)
        XCTAssertEqual(delta, 0, accuracy: 1e-12)
    }
}
