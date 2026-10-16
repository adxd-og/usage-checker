import XCTest
@testable import Omelette

/// The past windows the period picker lists: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Window bounds ("a past
/// window: between two resets") and § The tab, item 1 ("the current window and the past
/// ones inside the 31-day horizon, newest first").
///
/// A reading reports when its window resets, so a run of readings naming one reset is one
/// window. On this Mac's history at the time, that finds all 266 session changes and the
/// 13 week changes; a held drop of 5 points finds 207 of the sessions (46
/// never reached 5 %) and splits 5 weeks at mid-week restores. A reported reset wandered at
/// most 2 s between polls here, and the closest two real windows were 20 minutes apart:
/// resets less than 10 minutes apart, reading to reading, are one window. Readings that
/// name no reset (Codex before this release, or an older build run in between) still go
/// through the drop rule.
final class LimitPastWindowsResetTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let minute: TimeInterval = 60

    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    private func at(_ text: String) -> Date { Self.iso.date(from: text) ?? .distantPast }

    private func windows(
        _ records: [HistoryRecord], bucket: String, length: TimeInterval, currentStart: Date,
        horizonStart: Date? = nil
    ) -> [LimitPastWindow] {
        LimitShareRules.pastWindows(
            records: records, bucketID: bucket, windowLength: length, before: currentStart,
            horizonStart: horizonStart ?? currentStart.addingTimeInterval(-31 * day)
        )
    }

    /// One window with the resets its readings named.
    private func past(_ start: Date, _ end: Date, resets: ClosedRange<Date>?) -> LimitPastWindow {
        LimitPastWindow(start: start, end: end, resets: resets)
    }

    // MARK: - Real records

    func testASessionThatNeverReachedFivePercentIsStillAWindow() throws {
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.sessionEndingAtTwoPercent)
        let currentStart = at("2026-10-05T11:30:00Z") // the session that resets at 16:30

        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: currentStart),
            [past(at("2026-10-05T06:30:00Z"), at("2026-10-05T11:30:00Z"),
                  resets: at("2026-10-05T11:29:59Z")...at("2026-10-05T11:30:00Z"))],
            "the highest reset its readings named, 11:30, ends it"
        )
        XCTAssertEqual(
            LimitShareRules.pastWindows(
                series: LimitShareRules.series(records, bucketID: "five_hour"),
                before: currentStart, horizonStart: currentStart.addingTimeInterval(-31 * day)
            ),
            [],
            "2 → 0 is too small a drop to tell a reset by"
        )
    }

    func testARestoreInsideAWeekDoesNotSplitIt() throws {
        // 13:20:42: the week falls 60 → 51 and keeps its reset, 2026-10-15 10:00.
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.restoreAndEarlyReset)
        let reset = at("2026-10-15T10:00:00Z")
        XCTAssertEqual(
            windows(records, bucket: "seven_day", length: 7 * day, currentStart: reset),
            [past(at("2026-10-08T10:00:00Z"), reset, resets: reset...reset)]
        )
    }

    func testASessionResetEarlyEndsWhereTheNextOneBegan() throws {
        // 13:20:42: the session at 99 % (reset 15:00) gives way to one that resets at 18:20.
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.restoreAndEarlyReset)
        let early = at("2026-10-12T15:00:00Z")
        let next = at("2026-10-12T18:20:00Z")
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: at("2026-10-12T19:00:00Z")),
            [
                past(at("2026-10-12T13:20:00Z"), next, resets: next...next),
                past(at("2026-10-12T10:00:00Z"), at("2026-10-12T13:20:00Z"), resets: early...early),
            ],
            "newest first; the early-reset session ends at 13:20, not at its 15:00 reset"
        )
    }

    func testTheWindowOpenNowIsNotAPastOne() throws {
        let records = try LimitHistoryFixture.records(LimitHistoryFixture.restoreAndEarlyReset)
        let early = at("2026-10-12T15:00:00Z")
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: at("2026-10-12T13:20:00Z")),
            [past(at("2026-10-12T10:00:00Z"), at("2026-10-12T13:20:00Z"), resets: early...early)],
            "the session that resets at 18:20 is the one open"
        )
    }

    func testCodexReadingsFromBeforeResetTimesFallBackToTheDropRule() throws {
        let records = try LimitHistoryFixture.records(
            LimitHistoryFixture.codexBeforeResetTimes + LimitHistoryFixture.codexAfterResetTimes
        )
        // The week open now resets 2026-10-22 13:00:48, so it began 2026-10-15 13:00:48.
        XCTAssertEqual(
            windows(records, bucket: "codex_weekly", length: 7 * day, currentStart: at("2026-10-15T13:00:48Z")),
            [past(at("2026-10-12T22:07:44Z"), at("2026-10-14T18:36:37Z"), resets: nil)],
            "between the two drops to 0; the span after the second never left 0"
        )
    }

    // MARK: - Built readings

    func testAWindowWhoseReadingsNeverLeftZeroIsIdleTime() {
        let reset = at("2026-10-05T11:30:00Z")
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: reset.addingTimeInterval(-2 * hour), percent: 0, resetsAt: reset),
            (at: reset.addingTimeInterval(-1 * hour), percent: 0, resetsAt: reset),
        ])
        XCTAssertEqual(windows(records, bucket: "five_hour", length: 5 * hour, currentStart: reset.addingTimeInterval(hour)), [])
    }

    func testAWindowThatBeganBeforeTheTurnHorizonIsLeftOut() {
        let reset = at("2026-10-05T11:30:00Z")
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: reset.addingTimeInterval(-1 * hour), percent: 3, resetsAt: reset),
        ])
        let start = reset.addingTimeInterval(-5 * hour)
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: reset.addingTimeInterval(hour),
                    horizonStart: start.addingTimeInterval(1)),
            [],
            "its turns would already be folded into day totals"
        )
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: reset.addingTimeInterval(hour),
                    horizonStart: start),
            [past(start, reset, resets: reset...reset)]
        )
    }

    func testTheNextWindowsResetSeenEarlyIsNotInsideTheLastWindowTheDropRuleFound() {
        // Codex readings with no reset time: the open week's own drop (30 → 0) is seen ten
        // minutes before the week's computed start. It belongs to the next window, not to
        // this one, so this one ends on its last reading before it.
        let start = at("2026-10-15T13:00:00Z")
        let records = Fixture.readings(service: "codex", bucketID: "codex_weekly", points: [
            (at: start.addingTimeInterval(-9 * day), percent: 40),
            (at: start.addingTimeInterval(-8 * day), percent: 0),
            (at: start.addingTimeInterval(-8 * day + hour), percent: 0),
            (at: start.addingTimeInterval(-3 * day), percent: 10),
            (at: start.addingTimeInterval(-2 * day), percent: 30),
            (at: start.addingTimeInterval(-20 * minute), percent: 30),
            (at: start.addingTimeInterval(-10 * minute), percent: 0),
            (at: start.addingTimeInterval(hour), percent: 2),
        ])
        XCTAssertEqual(
            windows(records, bucket: "codex_weekly", length: 7 * day, currentStart: start),
            [past(start.addingTimeInterval(-9 * day), start.addingTimeInterval(-20 * minute), resets: nil)]
        )
    }

    func testResetsLessThanTenMinutesApartAreOneWindow() {
        let r0 = at("2026-10-05T12:00:00Z")
        let drifted = r0.addingTimeInterval(10 * minute - 1)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: r0.addingTimeInterval(-4 * hour - 50 * minute), percent: 2, resetsAt: r0),
            (at: r0.addingTimeInterval(-4 * hour - 40 * minute), percent: 3, resetsAt: drifted),
        ])
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: r0.addingTimeInterval(6 * hour)),
            [past(drifted.addingTimeInterval(-5 * hour), drifted, resets: r0...drifted)],
            "9 min 59 s apart: one window, ending at the highest reset named"
        )
    }

    func testResetsExactlyTenMinutesApartAreTwoWindows() {
        let r0 = at("2026-10-05T12:00:00Z")
        let next = r0.addingTimeInterval(10 * minute)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: r0.addingTimeInterval(-4 * hour - 55 * minute), percent: 2, resetsAt: r0),
            (at: r0.addingTimeInterval(-4 * hour), percent: 3, resetsAt: next),
        ])
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: r0.addingTimeInterval(6 * hour)),
            [
                past(next.addingTimeInterval(-5 * hour), next, resets: next...next),
                past(r0.addingTimeInterval(-5 * hour), next.addingTimeInterval(-5 * hour), resets: r0...r0),
            ],
            "Claude's resets sit on ten-minute marks: ten minutes apart is an early reset"
        )
    }

    func testResetsJustOverTenMinutesApartAreTwoWindows() {
        let r0 = at("2026-10-05T12:00:00Z")
        let next = r0.addingTimeInterval(10 * minute + 1)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: r0.addingTimeInterval(-4 * hour - 55 * minute), percent: 2, resetsAt: r0),
            (at: r0.addingTimeInterval(-4 * hour), percent: 3, resetsAt: next),
        ])
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: r0.addingTimeInterval(6 * hour)),
            [
                past(next.addingTimeInterval(-5 * hour), next, resets: next...next),
                past(r0.addingTimeInterval(-5 * hour), next.addingTimeInterval(-5 * hour), resets: r0...r0),
            ]
        )
    }

    func testAResetThatDriftsSixMinutesAtATimeIsOneWindow() {
        // 12:00, then 12:06, then 12:12: each reading is six minutes from the one before,
        // so the run stays one window though its ends are twelve minutes apart.
        let r0 = at("2026-10-05T12:00:00Z")
        let last = r0.addingTimeInterval(12 * minute)
        let records = Fixture.timedReadings(bucketID: "five_hour", kind: .session, points: [
            (at: r0.addingTimeInterval(-4 * hour), percent: 2, resetsAt: r0),
            (at: r0.addingTimeInterval(-3 * hour), percent: 3, resetsAt: r0.addingTimeInterval(6 * minute)),
            (at: r0.addingTimeInterval(-2 * hour), percent: 5, resetsAt: last),
        ])
        XCTAssertEqual(
            windows(records, bucket: "five_hour", length: 5 * hour, currentStart: r0.addingTimeInterval(6 * hour)),
            [past(last.addingTimeInterval(-5 * hour), last, resets: r0...last)]
        )
    }

    func testHeldDropsInReadingsWithNoResetBetweenOnesWithResetsStillSplitWindows() {
        // Codex's week: this build's readings name their reset; between them an older
        // build ran and wrote readings with none, and those hold two drops that held.
        let ra = at("2026-10-01T12:00:00Z")
        let rb = ra.addingTimeInterval(7 * day)
        let currentStart = ra.addingTimeInterval(5 * day + 12 * hour)
        let rc = currentStart.addingTimeInterval(7 * day)
        let named = Fixture.timedReadings(service: "codex", bucketID: "codex_weekly", kind: .weekly, points: [
            (at: ra.addingTimeInterval(-2 * day), percent: 10, resetsAt: ra),
            (at: ra.addingTimeInterval(-1 * day), percent: 30, resetsAt: ra),
            (at: ra.addingTimeInterval(1 * hour), percent: 4, resetsAt: rb),
            (at: ra.addingTimeInterval(1 * day), percent: 20, resetsAt: rb),
            (at: ra.addingTimeInterval(6 * day), percent: 1, resetsAt: rc),
        ])
        let unnamed = Fixture.readings(service: "codex", bucketID: "codex_weekly", points: [
            (at: ra.addingTimeInterval(2 * day), percent: 40),
            (at: ra.addingTimeInterval(3 * day), percent: 3),
            (at: ra.addingTimeInterval(3 * day + hour), percent: 4),
            (at: ra.addingTimeInterval(4 * day), percent: 25),
            (at: ra.addingTimeInterval(4 * day + 12 * hour), percent: 2),
            (at: ra.addingTimeInterval(4 * day + 13 * hour), percent: 3),
            (at: ra.addingTimeInterval(5 * day), percent: 15),
        ])
        XCTAssertEqual(
            windows(named + unnamed, bucket: "codex_weekly", length: 7 * day, currentStart: currentStart),
            [
                past(ra.addingTimeInterval(4 * day), currentStart, resets: nil),
                past(ra.addingTimeInterval(2 * day), ra.addingTimeInterval(4 * day), resets: nil),
                past(ra, ra.addingTimeInterval(2 * day), resets: rb...rb),
                past(ra.addingTimeInterval(-7 * day), ra, resets: ra...ra),
            ],
            "40 → 3 and 25 → 2 each end a window, though the readings around them name none"
        )
    }

    func testAWindowKeepsTheLengthItsReadingsRecorded() {
        // Codex's 30-day window, then a plan whose "weekly" window is a week: the bucket
        // live now says 7 days, its past readings said 30.
        let end = at("2026-10-10T00:00:00Z")
        let records = Fixture.timedReadings(
            service: "codex", bucketID: "codex_weekly", kind: .weekly, windowLength: 30 * day, points: [
                (at: end.addingTimeInterval(-20 * day), percent: 12, resetsAt: end),
                (at: end.addingTimeInterval(-2 * day), percent: 40, resetsAt: end),
            ]
        )
        XCTAssertEqual(
            windows(records, bucket: "codex_weekly", length: 7 * day, currentStart: end),
            [past(end.addingTimeInterval(-30 * day), end, resets: end...end)]
        )
    }
}
