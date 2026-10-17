import XCTest
@testable import Omelette

/// A picked past window stays picked: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § The tab, item 1 (the period picker) and § Design, Window bounds. Every load finds the
/// past windows again, and the newest one ends at the current window's start, which moves
/// with the live reset's drift (Claude reports 09:59:59 next to 10:00:00). A window on
/// offer that starts and ends within `LimitShareRules.resetDrift` of the picked one is the
/// picked one. The picked instance is what the page keeps, so the query, and the load key
/// the tab watches, hold still from poll to poll; the picker marks the entry on offer.
final class LimitsPastPeriodDriftTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// The session open now began an hour ago, as the first poll put it.
    private var sessionStart: Date { now.addingTimeInterval(-hour) }

    /// Claude Max with its session reset as one poll reported it.
    private func claude(sessionReset: Date) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 3,
                           resetsAt: sessionReset, kind: .session, windowLength: 5 * hour),
        ], at: now)
    }

    /// The session before, which reset at `sessionStart`: 10 % then 20 %.
    private var records: [HistoryRecord] {
        Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(-2 * hour), percent: 10, resetsAt: sessionStart),
            (at: sessionStart.addingTimeInterval(-30 * 60), percent: 20, resetsAt: sessionStart),
        ])
    }

    /// The periods a load offers when the live reset puts the current session's start at
    /// `currentStart`.
    private func offered(currentStart: Date) -> [LimitsPeriod] {
        LimitsRules.periods(
            mode: .subscription,
            pastWindows: LimitShareRules.pastWindows(
                records: records, bucketID: "five_hour", windowLength: 5 * hour,
                before: currentStart, horizonStart: now.addingTimeInterval(-31 * day)
            )
        )
    }

    private func query(_ period: LimitsPeriod, sessionReset: Date) -> LimitsQuery {
        LimitsRules.query(
            serviceID: "claude", service: claude(sessionReset: sessionReset), kind: .session, period: period,
            weeklyBudgetUSD: 0, now: now, calendar: utc
        )
    }

    func testThePickedWindowSurvivesAPollThatMovesTheCurrentStartBackASecond() throws {
        let first = offered(currentStart: sessionStart)
        let picked = try XCTUnwrap(first.last)
        guard case .past(let window) = picked else { return XCTFail("the session before is on offer") }
        XCTAssertEqual(window.end, sessionStart)

        let next = offered(currentStart: sessionStart.addingTimeInterval(-1))
        XCTAssertFalse(next.contains(picked), "the same window, ending a second earlier")

        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: next), picked)
    }

    /// The query, and so the load key, carries the period: the picked instance keeps it
    /// the same, poll after poll, while the live reset wanders.
    func testTheQueryHoldsStillAcrossPollsThatMoveTheResetASecond() throws {
        let picked = try XCTUnwrap(offered(currentStart: sessionStart).last)
        let resets = [0.0, -1, 1, -1].map { sessionStart.addingTimeInterval(5 * hour + $0) }

        let queries = resets.map { reset in
            query(
                LimitsRules.selectedPeriod(picked, offered: offered(currentStart: reset.addingTimeInterval(-5 * hour))),
                sessionReset: reset
            )
        }

        XCTAssertEqual(Set(queries).count, 1)
        XCTAssertEqual(queries.first?.period, picked)
    }

    /// The load cuts the window the user picked: its readings by the same resets, its
    /// turns within the drift of the window found now.
    func testTheLoadOfThePickedWindowUsesItsOwnBounds() throws {
        let picked = try XCTUnwrap(offered(currentStart: sessionStart).last)
        guard case .past(let window) = picked else { return XCTFail("the session before is on offer") }
        let shown = LimitsRules.selectedPeriod(picked, offered: offered(currentStart: sessionStart.addingTimeInterval(-1)))

        let request = try XCTUnwrap(LimitsRules.request(
            for: claude(sessionReset: sessionStart.addingTimeInterval(5 * hour - 1)), kind: .session, period: shown,
            weeklyBudgetUSD: 0, now: now, calendar: utc
        ))

        XCTAssertEqual(request.period, window.window)
        XCTAssertEqual(request.resets, sessionStart...sessionStart)
        XCTAssertNil(request.livePercent)
    }

    func testThePickerMarksTheEntryOnOfferForThePickedWindow() throws {
        let picked = try XCTUnwrap(offered(currentStart: sessionStart).last)
        let next = offered(currentStart: sessionStart.addingTimeInterval(-1))

        let entry = LimitsRules.pickerEntry(for: LimitsRules.selectedPeriod(picked, offered: next), offered: next)

        XCTAssertEqual(entry, next.last, "the entry the picker lists, not the instance the page keeps")
        XCTAssertEqual(LimitsRules.pickerEntry(for: .current, offered: next), .current)
    }

    /// Two windows' resets are at least ten minutes apart: a window that far off is
    /// another one, and the page goes back to the current period.
    func testAWindowFurtherOffThanTheDriftIsAnotherWindow() {
        let picked = LimitsPeriod.past(LimitPastWindow(
            start: sessionStart.addingTimeInterval(-5 * hour - 10 * 60), end: sessionStart.addingTimeInterval(-10 * 60),
            resets: sessionStart.addingTimeInterval(-10 * 60)...sessionStart.addingTimeInterval(-10 * 60)
        ))

        XCTAssertEqual(LimitsRules.selectedPeriod(picked, offered: offered(currentStart: sessionStart)), .current)
    }
}
