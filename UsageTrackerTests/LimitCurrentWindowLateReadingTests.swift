import XCTest
@testable import Omelette

/// The current window's readings: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design, Window bounds and Totals ("chat shares plus Outside equal the window's percent
/// now"). The window before's last readings can be stamped just after the computed start:
/// they still report that window's reset. One fewer than 5 points above the new percent is
/// no held drop, so the running maximum would keep it as the new window's level. A reading
/// that reports a reset at or before the start (give or take `resetDrift`) is the window
/// before's and is left out; one that reports none is read by its time, as before.
final class LimitCurrentWindowLateReadingTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let hour: TimeInterval = 3_600

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// The session open now began an hour ago and resets in four.
    private var sessionStart: Date { now.addingTimeInterval(-hour) }
    private var sessionReset: Date { now.addingTimeInterval(4 * hour) }

    private func claude(sessionPercent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: sessionPercent,
                           resetsAt: sessionReset, kind: .session, windowLength: 5 * hour),
        ], at: now)
    }

    private var log: TurnCostLog {
        TurnCostLog(turns: [
            Fixture.turnCost(at: sessionStart.addingTimeInterval(10 * 60), chat: "chat-a", cost: 2),
        ])
    }

    private func share(readings: [HistoryRecord], live: Double) throws -> LimitShare {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude(sessionPercent: live), kind: .session, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        XCTAssertEqual(request.period.start, sessionStart)
        return try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
    }

    func testALateReadingOfTheWindowBeforeDoesNotHoldTheNewWindowsLevel() throws {
        let readings = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(-30 * 60), percent: 3, resetsAt: sessionStart),
            // Stamped a second after the start, still reporting the old reset.
            (at: sessionStart.addingTimeInterval(1), percent: 4, resetsAt: sessionStart),
            (at: sessionStart.addingTimeInterval(60), percent: 1, resetsAt: sessionReset),
            (at: sessionStart.addingTimeInterval(30 * 60), percent: 1, resetsAt: sessionReset),
        ])

        let share = try share(readings: readings, live: 1)

        XCTAssertEqual(share.percent, 1, accuracy: 1e-9, "the live percent, not the window before's 4")
        XCTAssertEqual(share.chats.first { $0.id == "chat-a" }?.points ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 0, accuracy: 1e-9)
    }

    /// Claude reports a reset a second either side of the whole minute from poll to poll.
    func testAnOldResetReportedASecondAfterTheStartIsStillTheWindowBefores() throws {
        let readings = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(2), percent: 4, resetsAt: sessionStart.addingTimeInterval(1)),
            (at: sessionStart.addingTimeInterval(60), percent: 1, resetsAt: sessionReset.addingTimeInterval(-1)),
        ])

        XCTAssertEqual(try share(readings: readings, live: 1).percent, 1, accuracy: 1e-9)
    }

    /// The new window's own readings name its reset, whatever its percent: none is left out.
    func testTheWindowsOwnReadingsAllCount() throws {
        let readings = Fixture.timedReadings(bucketID: "five_hour", kind: .session, windowLength: 5 * hour, points: [
            (at: sessionStart.addingTimeInterval(60), percent: 1, resetsAt: sessionReset),
            (at: sessionStart.addingTimeInterval(40 * 60), percent: 6, resetsAt: sessionReset),
        ])

        XCTAssertEqual(try share(readings: readings, live: 4).percent, 6, accuracy: 1e-9, "a dip below a reading is noise")
    }

    /// Records written before resets were kept name none: they are read by their time.
    func testAReadingThatNamesNoResetIsReadByItsTime() throws {
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: sessionStart.addingTimeInterval(1), percent: 4),
            (at: sessionStart.addingTimeInterval(60), percent: 1),
        ])

        XCTAssertEqual(try share(readings: readings, live: 1).percent, 4, accuracy: 1e-9)
    }
}
