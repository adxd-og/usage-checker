import XCTest
@testable import Omelette

/// The change signal: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design, Change signal (weekly only).
/// - This week's price is compared with the mean of the previous complete weeks still
///   inside the 31-day turn horizon, each with at least 10 attributed points.
/// - It fires below 75 % of that mean, when this week has at least 10 points.
/// - It says when the costliest model changed.
/// - "Weekly only" means a window of at most 8 days, this week's and the usual ones: a
///   30-day window of kind `.weekly` is not a week.
final class LimitShareChangeSignalTests: XCTestCase {
    /// This week's start: 2026-09-06 12:00 UTC, a Sunday. "Now" is three days in.
    private let weekStart = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private var now: Date { weekStart.addingTimeInterval(3 * day) }
    /// `now − 31 days`, which is `weekStart − 28 days`.
    private var horizonStart: Date { now.addingTimeInterval(-31 * day) }

    /// The week `weeksBack` weeks before this one (0 is this week, which runs to now).
    /// One turn costs `cost`, and the percent reaches `points` in the same half hour.
    private func week(
        _ weeksBack: Int, points: Double, cost: Double, model: String = "claude-opus-4-5"
    ) -> LimitShare {
        let start = weekStart.addingTimeInterval(-Double(weeksBack) * 7 * day)
        let end = weeksBack == 0 ? now : start.addingTimeInterval(7 * day)
        return LimitShareRules.share(
            window: LimitWindow(start: start, end: end),
            bucketID: "seven_day",
            readings: Fixture.readings(
                bucketID: "seven_day", points: [(at: start.addingTimeInterval(20 * 60), percent: points)]
            ),
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: start.addingTimeInterval(5 * 60), chat: "week-\(weeksBack)", model: model, cost: cost),
            ])
        )
    }

    /// Three usual weeks at $60 a point.
    private var usualWeeks: [LimitShare] {
        [week(1, points: 40, cost: 2_400), week(2, points: 50, cost: 3_000), week(3, points: 30, cost: 1_800)]
    }

    func testAPercentThatBuysAThirdLessThanUsualFires() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800), previous: usualWeeks,
            horizonStart: horizonStart
        ))
        XCTAssertEqual(signal.price, 40, accuracy: 1e-9)
        XCTAssertEqual(signal.usualPrice, 60, accuracy: 1e-9)
        XCTAssertEqual(signal.percentLess, 33, "a percent buys about 33 % less than usual")
        XCTAssertNil(signal.modelChange, "the same model every week")
    }

    func testAPriceAtThreeQuartersOfUsualDoesNotFire() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 900), previous: usualWeeks,
            horizonStart: horizonStart
        ), "$45 is 75 % of $60, not below it")
    }

    func testAWeekUnderTenAttributedPointsHasNoSignal() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 9, cost: 180), previous: usualWeeks,
            horizonStart: horizonStart
        ))
    }

    func testAPreviousWeekUnderTenAttributedPointsIsNotUsual() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly,
            current: week(0, points: 20, cost: 800),
            previous: [week(1, points: 9, cost: 1_800), week(2, points: 40, cost: 2_400)],
            horizonStart: horizonStart
        ))
        XCTAssertEqual(signal.usualPrice, 60, accuracy: 1e-9, "the $200-a-point week had 9 points and is left out")
    }

    func testWithNoComparableWeekThereIsNoSignal() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800), previous: [],
            horizonStart: horizonStart
        ))
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800),
            previous: [week(1, points: 9, cost: 540)], horizonStart: horizonStart
        ))
    }

    func testAWeekOlderThanTheTurnHorizonIsNotUsual() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly,
            current: week(0, points: 20, cost: 800),
            previous: usualWeeks + [week(5, points: 40, cost: 40_000)],
            horizonStart: horizonStart
        ))
        XCTAssertEqual(signal.usualPrice, 60, accuracy: 1e-9, "the week 35 days back starts before the horizon")
    }

    func testTheSignalSaysWhenTheCostliestModelChanged() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly,
            current: week(0, points: 20, cost: 800, model: "claude-sonnet-4-5"),
            previous: usualWeeks,
            horizonStart: horizonStart
        ))
        let opus = try XCTUnwrap(ModelPricing.displayName(for: "claude-opus-4-5"))
        let sonnet = try XCTUnwrap(ModelPricing.displayName(for: "claude-sonnet-4-5"))
        XCTAssertNotEqual(opus, sonnet)
        XCTAssertEqual(signal.modelChange, LimitChangeSignal.ModelChange(usual: opus, now: sonnet))
    }

    func testASessionWindowHasNoChangeSignal() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .session, current: week(0, points: 20, cost: 800), previous: usualWeeks,
            horizonStart: horizonStart
        ))
    }

    /// A share of the window from `start` to `end`. One turn costs `cost`, and the percent
    /// reaches `points` in the same half hour.
    private func window(from start: Date, to end: Date, points: Double, cost: Double) -> LimitShare {
        LimitShareRules.share(
            window: LimitWindow(start: start, end: end),
            bucketID: "codex_session",
            readings: Fixture.readings(
                bucketID: "codex_session", points: [(at: start.addingTimeInterval(20 * 60), percent: points)]
            ),
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: start.addingTimeInterval(5 * 60), chat: "chat", cost: cost),
            ])
        )
    }

    func testAThirtyDayWindowIsNotAWeekAndHasNoChangeSignal() {
        // Codex Free's window has kind `.weekly` and lasts 30 days. The horizon passed here
        // reaches back far enough for two ordinary weeks before it to be usual, so only
        // the window's length keeps the signal off.
        let farHorizon = now.addingTimeInterval(-44 * day)
        let usual = [
            window(from: now.addingTimeInterval(-37 * day), to: now.addingTimeInterval(-30 * day), points: 40, cost: 2_400),
            window(from: farHorizon, to: now.addingTimeInterval(-37 * day), points: 50, cost: 3_000),
        ]
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly,
            current: window(from: now.addingTimeInterval(-30 * day), to: now, points: 20, cost: 800),
            previous: usual, horizonStart: farHorizon
        ))
        XCTAssertNotNil(LimitShareRules.changeSignal(
            kind: .weekly,
            current: window(from: now.addingTimeInterval(-8 * day), to: now, points: 20, cost: 800),
            previous: usual, horizonStart: farHorizon
        ), "a window of eight days is still compared")
    }

    func testAPreviousThirtyDayWindowIsNotAUsualWeek() {
        // Twelve hours into a Codex Free window, the 30-day window before it still starts
        // inside the 31-day turn horizon.
        let currentStart = now.addingTimeInterval(-12 * 3_600)
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly,
            current: window(from: currentStart, to: now, points: 20, cost: 800),
            previous: [
                window(from: currentStart.addingTimeInterval(-30 * day), to: currentStart, points: 40, cost: 2_400),
            ],
            horizonStart: horizonStart
        ))
    }
}
