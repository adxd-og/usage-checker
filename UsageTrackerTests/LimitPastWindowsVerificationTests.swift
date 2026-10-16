import XCTest
@testable import Omelette

/// Past windows and their shares, checked against spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds and
/// Totals, and § The tab, item 1. A window comes from the reset each reading reported:
/// consecutive resets less than 10 minutes apart are one window (exactly 10 minutes is
/// two); it ends at the highest reset any reading named and has the length its readings
/// recorded, the live bucket's for a record that recorded none; reset-less readings go
/// through the held-drop rule; a past window's share counts the readings that named its
/// reset and no other's.
final class LimitPastWindowsVerificationTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let minute: TimeInterval = 60

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private func windows(
        _ records: [HistoryRecord], bucket: String, length: TimeInterval, currentStart: Date, horizonStart: Date
    ) -> [LimitPastWindow] {
        LimitShareRules.pastWindows(
            records: records, bucketID: bucket, windowLength: length, before: currentStart, horizonStart: horizonStart
        )
    }

    private func past(_ start: Date, _ end: Date, _ low: Date, _ high: Date) -> LimitPastWindow {
        LimitPastWindow(start: start, end: end, resets: low...high)
    }

    // MARK: - Window lengths

    func testAThirtyDayWindowKeepsItsRecordedLengthOnceTheBucketIsAWeek() {
        let x = at("2026-10-16T00:00:00Z")
        let thirty = Fixture.timedReadings(
            service: "codex", bucketID: "codex_weekly", kind: .weekly, windowLength: 30 * day,
            points: [(at: x - 2 * day, percent: 10, resetsAt: x), (at: x - hour, percent: 40, resetsAt: x)]
        )
        let week = Fixture.timedReadings(
            service: "codex", bucketID: "codex_weekly", kind: .weekly, windowLength: 7 * day,
            points: [(at: x + hour, percent: 3, resetsAt: x + 7 * day), (at: x + 6 * hour, percent: 5, resetsAt: x + 7 * day)]
        )
        let result = windows(
            thirty + week, bucket: "codex_weekly", length: 7 * day, currentStart: x,
            horizonStart: x + 12 * hour - 31 * day
        )
        XCTAssertEqual(result, [past(x - 30 * day, x, x, x)], "the old window ran 30 days, not the live bucket's 7")
    }

    func testAWeekWindowKeepsItsRecordedLengthOnceTheBucketIsThirtyDays() {
        let x = at("2026-10-16T00:00:00Z")
        let week = Fixture.timedReadings(
            service: "codex", bucketID: "codex_weekly", kind: .weekly, windowLength: 7 * day,
            points: [(at: x - 2 * day, percent: 10, resetsAt: x), (at: x - hour, percent: 40, resetsAt: x)]
        )
        let month = Fixture.timedReadings(
            service: "codex", bucketID: "codex_weekly", kind: .weekly, windowLength: 30 * day,
            points: [(at: x + hour, percent: 3, resetsAt: x + 30 * day)]
        )
        let result = windows(
            week + month, bucket: "codex_weekly", length: 30 * day, currentStart: x,
            horizonStart: x + 12 * hour - 31 * day
        )
        XCTAssertEqual(result, [past(x - 7 * day, x, x, x)])
    }

    func testAShorterRecordedLengthBeatsTheLiveBuckets() {
        let reset = at("2026-10-05T15:00:00Z")
        let records = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session, windowLength: 3 * hour,
            points: [(at: reset - 2 * hour, percent: 8, resetsAt: reset), (at: reset - hour, percent: 12, resetsAt: reset)]
        )
        let result = windows(
            records, bucket: "five_hour", length: 5 * hour, currentStart: reset + hour,
            horizonStart: reset - 31 * day
        )
        XCTAssertEqual(result, [past(reset - 3 * hour, reset, reset, reset)])
    }

    func testARecordWithNoLengthTakesTheLiveBucketsLength() throws {
        // A record from before windows were kept (no `bucketWindows`), Claude's session.
        let lines = [
            #"{"id":"6F1C2A10-0000-4000-8000-000000009001","timestamp":"2026-10-05T12:10:00Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":8},"fiveHourPercent":8,"fiveHourResetsAt":"2026-10-05T15:00:00Z","extraCreditsUsed":0}"#,
            #"{"id":"6F1C2A10-0000-4000-8000-000000009002","timestamp":"2026-10-05T14:40:00Z","plan":"Claude Max 20x","serviceID":"claude","bucketPercents":{"five_hour":13},"fiveHourPercent":13,"fiveHourResetsAt":"2026-10-05T15:00:00Z","extraCreditsUsed":0}"#,
        ]
        let reset = at("2026-10-05T15:00:00Z")
        let result = windows(
            try LimitHistoryFixture.records(lines), bucket: "five_hour", length: 5 * hour, currentStart: reset,
            horizonStart: reset - 31 * day
        )
        XCTAssertEqual(result, [past(reset - 5 * hour, reset, reset, reset)])
    }

    // MARK: - Edges of the horizon and of the current window

    func testAWindowThatBeganExactlyAtTheHorizonIsListedAndOneSecondBeforeIsNot() {
        let reset = at("2026-10-05T15:00:00Z")
        let records = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session,
            points: [(at: reset - hour, percent: 12, resetsAt: reset)]
        )
        let start = reset - 5 * hour
        XCTAssertEqual(windows(records, bucket: "five_hour", length: 5 * hour, currentStart: reset, horizonStart: start).count, 1)
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: reset, horizonStart: start + 1).count, 0
        )
    }

    func testAResetTenMinutesBeforeTheOpenWindowsIsAnotherWindowAndLessThanTenIsTheOpenOne() {
        let currentStart = at("2026-10-05T15:00:00Z")
        let currentReset = currentStart + 5 * hour
        func listed(namedReset: Date) -> Int {
            let records = Fixture.timedReadings(
                bucketID: "five_hour", kind: .session,
                points: [(at: currentStart + hour, percent: 12, resetsAt: namedReset)]
            )
            return windows(
                records, bucket: "five_hour", length: 5 * hour, currentStart: currentStart,
                horizonStart: currentStart - 31 * day
            ).count
        }
        XCTAssertEqual(listed(namedReset: currentReset), 0, "the open window's own reset")
        XCTAssertEqual(listed(namedReset: currentReset - 10 * minute + 1), 0, "9 min 59 s from it is the same window")
        XCTAssertEqual(listed(namedReset: currentReset - 10 * minute), 1, "exactly 10 minutes is two windows")
    }

    // MARK: - Jitter, order, early resets

    func testAResetThatWandersAndComesBackIsOneWindowEndingAtItsHighest() {
        let base = at("2026-10-05T11:30:00Z")
        let records = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session,
            points: [
                (at: base - 4 * hour, percent: 3, resetsAt: base),
                (at: base - 3 * hour, percent: 5, resetsAt: base - 1),
                (at: base - 2 * hour, percent: 7, resetsAt: base + 1),
                (at: base - hour, percent: 9, resetsAt: base + 4 * minute),
                (at: base - 30 * minute, percent: 11, resetsAt: base),
            ]
        )
        let result = windows(
            records, bucket: "five_hour", length: 5 * hour, currentStart: base + hour,
            horizonStart: base - 31 * day
        )
        XCTAssertEqual(result, [past(base + 4 * minute - 5 * hour, base + 4 * minute, base - 1, base + 4 * minute)])
    }

    func testTheOrderOfTheRecordsDoesNotChangeTheWindows() throws {
        let lines = LimitHistoryFixture.restoreAndEarlyReset + LimitHistoryFixture.sessionEndingAtTwoPercent
        let records = try LimitHistoryFixture.records(lines)
        let currentStart = at("2026-10-12T13:20:42Z")
        let sorted = windows(
            records.sorted { $0.timestamp < $1.timestamp }, bucket: "five_hour", length: 5 * hour,
            currentStart: currentStart, horizonStart: currentStart - 31 * day
        )
        let shuffled = windows(
            records.reversed(), bucket: "five_hour", length: 5 * hour,
            currentStart: currentStart, horizonStart: currentStart - 31 * day
        )
        XCTAssertFalse(sorted.isEmpty)
        XCTAssertEqual(sorted, shuffled)
    }

    /// Eight sessions of a Max account, as its history would hold them: full ones, ones
    /// reset early (the next opening where the old one stopped), one cut after half an
    /// hour, and idle hours between with the percent at 0 and no reset (`4001-01-01`).
    func testWindowsOfAWholeHistoryAreTheSessionsInOrderWithoutOverlap() {
        // (hours idle before, hours it ran): a session that runs less than 5 h was reset early.
        let plan: [(idle: Double, ran: Double)] = [
            (0, 5), (0, 2), (0, 5), (3, 5), (0, 0.5), (0, 5), (1, 5), (0, 1),
        ]
        let base = at("2026-09-30T00:00:00Z")
        var cursor = base
        var points: [(at: Date, percent: Double, resetsAt: Date)] = []
        var expected: [LimitPastWindow] = []
        for (index, session) in plan.enumerated() {
            if session.idle > 0 {
                var idle = cursor + 30 * minute
                while idle < cursor + session.idle * hour {
                    points.append((at: idle, percent: 0, resetsAt: .distantFuture))
                    idle += 30 * minute
                }
                cursor += session.idle * hour
            }
            let start = cursor
            let reset = start + 5 * hour
            let stop = start + session.ran * hour
            var reading = start + 10 * minute
            var percent = 1.0
            while reading < stop {
                points.append((at: reading, percent: percent, resetsAt: reset))
                percent += 1
                reading += 20 * minute
            }
            if index < plan.count - 1 {
                expected.append(LimitPastWindow(start: start, end: min(stop, reset), resets: reset...reset))
            }
            cursor = stop
        }
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: points)
        let currentStart = cursor - plan.last!.ran * hour
        let result = windows(
            records, bucket: "five_hour", length: 5 * hour, currentStart: currentStart, horizonStart: base - day
        )
        XCTAssertEqual(result, expected.reversed(), "newest first, each ending where the next began or at its own reset")
        for (newer, older) in zip(result, result.dropFirst()) {
            XCTAssertLessThanOrEqual(older.end, newer.start, "no two windows overlap")
        }
    }

    func testARestoreWhoseOwnReadingNamedNoResetStillDoesNotSplitTheWeek() {
        // 60 % -> 51 % mid-week with the reset unchanged, but the reading at 51 % came from a poll that
        // carried no reset (an older build's run, or a reading with none). Readings that named the
        // week's reset lie on both sides of the drop: a restore, not a boundary.
        let reset = at("2026-10-15T10:00:00Z")
        let named = Fixture.timedReadings(bucketID: "seven_day", kind: .weekly, points: [
            (at: reset - 5 * day, percent: 60, resetsAt: reset),
            (at: reset - 4 * day + 2 * hour, percent: 51, resetsAt: reset),
            (at: reset - 3 * day, percent: 55, resetsAt: reset),
        ])
        let bare = Fixture.readings(bucketID: "seven_day", points: [(at: reset - 4 * day, percent: 51)])
        let result = windows(
            named + bare, bucket: "seven_day", length: 7 * day, currentStart: reset, horizonStart: reset - 31 * day
        )
        XCTAssertEqual(result, [past(reset - 7 * day, reset, reset, reset)], "one week, not two")
    }

    // MARK: - A session that ends and the next one opens soon after

    /// A session whose reset is 15:00, polled each minute, and the next one opening at 15:05
    /// (its reset 20:05): between them the account reports no window (`Date.distantFuture`,
    /// 0 %). The old session ends at the highest reset its readings named, 15:00.
    func testASessionEndsAtItsResetWhenTheNextOneOpensWithinHalfAnHourOfIt() throws {
        let reset = at("2026-10-05T15:00:00Z")
        var points: [(at: Date, percent: Double, resetsAt: Date)] = []
        var minuteMark = reset - 90 * minute
        var percent = 4.0
        while minuteMark <= reset - 30 {
            points.append((at: minuteMark, percent: percent, resetsAt: reset))
            minuteMark += minute
            percent += 0.1
        }
        let idle = [(at: reset + 40, percent: 0.0, resetsAt: Date.distantFuture)]
        let next = [(at: reset + 6 * minute, percent: 1.0, resetsAt: reset + 5 * hour + 5 * minute)]
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: points + idle + next)
        let found = windows(
            records, bucket: "five_hour", length: 5 * hour, currentStart: reset + 5 * minute,
            horizonStart: reset - 31 * day
        )
        XCTAssertEqual(found.map(\.end), [reset], "the highest reset any reading named")
        XCTAssertEqual(found.map(\.start), [reset - 5 * hour])
    }

    // MARK: - A past window's share

    func testAPastSessionsShareTotalsItsLastReadingAndSplitsTheChatsByTheirBins() throws {
        let reset = at("2026-10-05T15:00:00Z")
        let start = reset - 5 * hour
        // Readings name two sessions: the one that ends at 15:00 and the next, whose first
        // reading is stamped before the old session's last (the poll's clock is unsteady).
        let ours = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session,
            points: [
                (at: start + 40 * minute, percent: 4, resetsAt: reset),
                (at: start + 100 * minute, percent: 10, resetsAt: reset),
                (at: reset + 7, percent: 14, resetsAt: reset),
            ]
        )
        let next = Fixture.timedReadings(
            bucketID: "five_hour", kind: .session,
            points: [(at: reset - 30, percent: 0, resetsAt: reset + 5 * hour)]
        )
        let records = ours + next
        let found = windows(
            records, bucket: "five_hour", length: 5 * hour, currentStart: reset, horizonStart: reset - 31 * day
        )
        let window = try XCTUnwrap(found.first)
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start + 20 * minute, chat: "chat-a", cost: 6),
            Fixture.turnCost(at: start + 80 * minute, chat: "chat-b", cost: 4),
        ])
        let share = try XCTUnwrap(LimitShareRules.share(
            for: LimitShareRules.request(for: window, bucketID: "five_hour"), log: log, readings: records
        ))
        XCTAssertEqual(share.percent, 14, accuracy: 1e-9, "the last reading, stamped 7 s after the reset")
        XCTAssertEqual(share.chats.map(\.id).sorted(), ["chat-a", "chat-b"])
        XCTAssertEqual(share.chats.reduce(0) { $0 + $1.points } + share.outside, 14, accuracy: 1e-9)
        XCTAssertEqual(share.chats.first { $0.id == "chat-a" }?.points ?? 0, 4, accuracy: 1e-9)
    }

    // MARK: - Restore

    func testAHeldDropScalesEveryReadingBeforeItByTheLevelItFellTo() {
        // 20 → 24 → 30 across two chats' half hours, then a restore to 15, held.
        let start = at("2026-10-12T00:00:00Z")
        let window = LimitWindow(start: start, end: start + 3 * hour)
        let series = [
            LimitReading(time: start + 20 * minute, percent: 20),
            LimitReading(time: start + 50 * minute, percent: 30),
            LimitReading(time: start + 80 * minute, percent: 15),
            LimitReading(time: start + 110 * minute, percent: 16),
        ]
        let restored = LimitShareRules.restoredReadings(series, in: window)
        XCTAssertEqual(restored.map(\.percent), [10.0, 15, 15, 16], "x0.5 before the drop")
    }

    func testADropOfFourPointsIsNoiseAndADropOfFiveHeldIsARestore() {
        let start = at("2026-10-12T00:00:00Z")
        let window = LimitWindow(start: start, end: start + 3 * hour)
        func percents(drop to: Double) -> [Double] {
            LimitShareRules.restoredReadings([
                LimitReading(time: start + 20 * minute, percent: 40),
                LimitReading(time: start + 50 * minute, percent: to),
                LimitReading(time: start + 80 * minute, percent: to),
            ], in: window).map(\.percent)
        }
        XCTAssertEqual(percents(drop: 36), [40, 36, 36], "four points down is within noise")
        XCTAssertEqual(percents(drop: 35), [35, 35, 35], "five points down and held scales the 40 to 35")
    }

    func testALoneDipThatRecoversMovesNothing() {
        let start = at("2026-10-12T00:00:00Z")
        let window = LimitWindow(start: start, end: start + 3 * hour)
        let series = [
            LimitReading(time: start + 20 * minute, percent: 40),
            LimitReading(time: start + 50 * minute, percent: 20),
            LimitReading(time: start + 80 * minute, percent: 41),
        ]
        XCTAssertEqual(LimitShareRules.restoredReadings(series, in: window), series)
    }

    func testARestoreLeavesTheChatsAndOutsideTotallingTheWindowsPercent() throws {
        let start = at("2026-10-12T00:00:00Z")
        let window = LimitWindow(start: start, end: start + 4 * hour)
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: start + 10 * minute, chat: "chat-a", cost: 30),
            Fixture.turnCost(at: start + 40 * minute, chat: "chat-b", cost: 10),
            Fixture.turnCost(at: start + 100 * minute, chat: "chat-a", cost: 5),
        ])
        let request = LimitShareRequest(mode: .subscription, period: window, bucketID: "seven_day", livePercent: nil)
        let records = Fixture.readings(bucketID: "seven_day", points: [
            (at: start + 25 * minute, percent: 30), (at: start + 55 * minute, percent: 40),
            (at: start + 75 * minute, percent: 20), (at: start + 115 * minute, percent: 25),
            (at: start + 200 * minute, percent: 25),
        ])
        let restored = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: records))
        XCTAssertEqual(restored.percent, 25, accuracy: 1e-9)
        XCTAssertEqual(restored.chats.reduce(0) { $0 + $1.points } + restored.outside, 25, accuracy: 1e-9)
    }
}
