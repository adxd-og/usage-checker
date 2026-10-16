import XCTest
@testable import Omelette

/// The change signal's window and its usual weeks: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Change signal ("weekly
/// only"; "the mean of previous complete weeks still inside the 31-day turn horizon … each
/// with at least 10 attributed points"). A window is a week by its own length, not by how
/// long its spans happened to be: Codex windows reset early, and a 30-day window's spans
/// can look like weeks.
final class LimitChangeSignalLengthTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private var horizonStart: Date { now.addingTimeInterval(-31 * day) }

    /// A window ending `endingDaysAgo` days ago and lasting `length` days, one chat filling
    /// `points` of it at `perPoint` dollars a point.
    private func window(endingDaysAgo: Double, length: Double, points: Double, perPoint: Double) -> LimitShare {
        let end = now.addingTimeInterval(-endingDaysAgo * day)
        return Fixture.limitShare(
            window: LimitWindow(start: end.addingTimeInterval(-length * day), end: end),
            chats: [Fixture.chatShare(id: "chat-a", points: points, cost: points * perPoint, lastAt: end)],
            price: PercentPrice(dollars: perPoint, tokens: 1_000)
        )
    }

    func testAThirtyDayWindowNeverFiresHoweverShortItsSpans() {
        let current = window(endingDaysAgo: 0, length: 3, points: 20, perPoint: 40)
        let previous = [
            window(endingDaysAgo: 3, length: 2, points: 20, perPoint: 60),
            window(endingDaysAgo: 6, length: 2, points: 20, perPoint: 60),
        ]
        XCTAssertNotNil(
            LimitShareRules.changeSignal(kind: .weekly, current: current, previous: previous, horizonStart: horizonStart),
            "by their spans alone these are weeks"
        )
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: current, previous: previous, horizonStart: horizonStart, windowLength: 30 * day
        ))
    }

    func testAWeekGivenItsLengthStillFires() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly,
            current: window(endingDaysAgo: 0, length: 5, points: 20, perPoint: 40),
            previous: [window(endingDaysAgo: 5, length: 7, points: 20, perPoint: 60)],
            horizonStart: horizonStart,
            windowLength: 7 * day
        ))
        XCTAssertEqual(signal.percentLess, 33, "$40 against $60")
    }

    func testTheSignalSaysHowManyUsualWeeksItAveraged() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly,
            current: window(endingDaysAgo: 0, length: 5, points: 20, perPoint: 40),
            previous: [
                window(endingDaysAgo: 5, length: 7, points: 20, perPoint: 60),
                window(endingDaysAgo: 12, length: 7, points: 20, perPoint: 60),
                window(endingDaysAgo: 19, length: 7, points: 9, perPoint: 60),
            ],
            horizonStart: horizonStart,
            windowLength: 7 * day
        ))
        XCTAssertEqual(signal.usualWeeks, 2, "a week under 10 attributed points is not a usual week")
    }
}
