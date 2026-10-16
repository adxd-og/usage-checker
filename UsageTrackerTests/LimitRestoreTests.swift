import XCTest
@testable import Omelette

/// A limit restored inside a window: spec `docs/superpowers/specs/2026-10-16-limit-analytics.md`
/// § Design, Readings ("a window does not empty between resets") and Totals ("chat shares
/// plus Outside equal the window's percent now"). When the percent falls and holds with
/// its reset unchanged, the provider gave points back and nothing says whose. Every
/// reading before the fall is scaled by the level it fell to over the level it fell from,
/// so each chat keeps its part of what still counts. On this Mac the week of 2026-10-08
/// fell 60 → 51 at 13:20 on 10-12, in a half hour where one chat ran 122 records: cut at
/// the fall instead, that chat would have read the 51 points as its own.
final class LimitRestoreTests: XCTestCase {
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

    /// Claude Max with its week at `weekPercent`; the week began five days ago.
    private func claude(weekPercent: Double) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", buckets: [
            Fixture.bucket(id: "seven_day", label: "All models", percent: weekPercent,
                           resetsAt: now.addingTimeInterval(2 * day), kind: .weekly),
        ])
    }

    private func points(_ share: LimitShare, _ chat: String) -> Double {
        share.chats.first { $0.id == chat }?.points ?? -1
    }

    func testARestoreToZeroLeavesNothingBeforeIt() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude(weekPercent: 12), kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let start = request.period.start
        let readings = Fixture.readings(bucketID: "seven_day", points: [
            (at: start.addingTimeInterval(1 * day), percent: 30),
            (at: start.addingTimeInterval(2 * day), percent: 94),
            (at: start.addingTimeInterval(3 * day), percent: 0),
            (at: start.addingTimeInterval(3 * day + hour), percent: 0),
            (at: start.addingTimeInterval(4 * day), percent: 10),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(2 * day - 600), chat: "chat-before", cost: 5),
            Fixture.turnCost(at: start.addingTimeInterval(4 * day - 600), chat: "chat-after", cost: 5),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 12, accuracy: 1e-9)
        XCTAssertEqual(points(share, "chat-before"), 0, accuracy: 1e-9, "everything before a reset to 0 was given back")
        XCTAssertEqual(points(share, "chat-after"), 10, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 2, accuracy: 1e-9)
    }

    func testTwoRestoresEachScaleWhatCameBefore() throws {
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude(weekPercent: 32), kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc
        ))
        let start = request.period.start
        // 40 → 20 holds (25 next), so everything before counts half; 60 → 30 holds (31
        // next), so everything before that counts half again.
        let readings = Fixture.readings(bucketID: "seven_day", points: [
            (at: start.addingTimeInterval(1 * day), percent: 40),
            (at: start.addingTimeInterval(2 * day), percent: 20),
            (at: start.addingTimeInterval(2 * day + hour), percent: 25),
            (at: start.addingTimeInterval(3 * day), percent: 60),
            (at: start.addingTimeInterval(4 * day), percent: 30),
            (at: start.addingTimeInterval(4 * day + hour), percent: 31),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start.addingTimeInterval(1 * day - 600), chat: "chat-a", cost: 1),
            Fixture.turnCost(at: start.addingTimeInterval(3 * day - 600), chat: "chat-b", cost: 1),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 32, accuracy: 1e-9)
        XCTAssertEqual(points(share, "chat-a"), 10, accuracy: 1e-9, "40 × ½ × ½")
        XCTAssertEqual(points(share, "chat-b"), 17.5, accuracy: 1e-9, "(60 − 25) × ½")
        XCTAssertEqual(share.outside, 4.5, accuracy: 1e-9, "25 × ½ − 10, then 30 → 31 → 32")
    }

    func testARestoreInsideAPastWeekKeepsTheWeeksPercentWhereItEnded() throws {
        let week = LimitWindow(start: now.addingTimeInterval(-12 * day), end: now.addingTimeInterval(-5 * day))
        let request = LimitShareRequest(mode: .subscription, period: week, bucketID: "seven_day", livePercent: nil)
        let readings = Fixture.readings(bucketID: "seven_day", points: [
            (at: week.start.addingTimeInterval(1 * day), percent: 50),
            (at: week.start.addingTimeInterval(2 * day), percent: 94),
            (at: week.start.addingTimeInterval(3 * day), percent: 66),
            (at: week.start.addingTimeInterval(3 * day + hour), percent: 66),
            (at: week.start.addingTimeInterval(6 * day), percent: 70),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: week.start.addingTimeInterval(2 * day - 600), chat: "chat-a", cost: 4),
            Fixture.turnCost(at: week.start.addingTimeInterval(6 * day - 600), chat: "chat-b", cost: 4),
        ])

        let share = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(share.percent, 70, accuracy: 1e-9, "where the week ended, not the 94 it held before")
        XCTAssertEqual(points(share, "chat-a"), 66 - 50 * 66 / 94.0, accuracy: 1e-9)
        XCTAssertEqual(points(share, "chat-b"), 4, accuracy: 1e-9)
        XCTAssertEqual(share.outside, 50 * 66 / 94.0, accuracy: 1e-9)
    }
}
