import XCTest
@testable import Omelette

/// Quota over time is the only usage story available for a provider that keeps no
/// local cost log, so the arithmetic behind it has to survive the things real history
/// does: window resets, buckets that come and go, days the app wasn't running, and a
/// 90-day span that no chart can draw point for point.
final class QuotaAnalyticsTests: XCTestCase {
    /// Fixed to UTC — daily peaks bin by local calendar day, and a test that passes
    /// only in the author's time zone is not a test.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func at(day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    private func records(_ points: [(at: Date, percents: [String: Double])]) -> [HistoryRecord] {
        Fixture.quotaHistory(points: points)
    }

    // MARK: - series

    func testABinKeepsItsPeakNotItsAverage() {
        let from = at(day: 1, hour: 0)
        let to = from.addingTimeInterval(600)
        let history = records([
            (from.addingTimeInterval(60), ["session": 10]),
            (from.addingTimeInterval(120), ["session": 90]),
            (from.addingTimeInterval(180), ["session": 20])
        ])

        let series = QuotaAnalytics.series(records: history, bucketID: "session", from: from, to: to, maxPoints: 1)

        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.percent, 90)
        // And it keeps the peak's own timestamp, not the bin's edge.
        XCTAssertEqual(series.first?.time, from.addingTimeInterval(120))
    }

    func testDownsamplingHonoursTheBudgetAndKeepsEachBinsMaximum() {
        // 100 readings climbing 0…99 over 100 minutes, squeezed into 10 bins: each bin
        // of ten minutes must surrender its highest reading and nothing else.
        let from = at(day: 1, hour: 0)
        let to = from.addingTimeInterval(100 * 60)
        let history = records((0..<100).map { minute in
            (from.addingTimeInterval(Double(minute) * 60), ["session": Double(minute)])
        })

        let series = QuotaAnalytics.series(records: history, bucketID: "session", from: from, to: to, maxPoints: 10)

        XCTAssertEqual(series.map(\.percent), [9, 19, 29, 39, 49, 59, 69, 79, 89, 99])
        XCTAssertEqual(series.map(\.time), series.map(\.time).sorted())
    }

    func testReadingsOutsideTheRangeOrWithoutTheBucketAreSkipped() {
        let from = at(day: 2, hour: 0)
        let to = at(day: 3, hour: 0)
        let history = records([
            (at(day: 1), ["session": 99]),              // before `from`
            (at(day: 4), ["session": 98]),              // after `to`
            (at(day: 2, hour: 6), ["weekly": 50]),      // no reading for this bucket
            (at(day: 2, hour: 9), ["session": 42])
        ])

        let series = QuotaAnalytics.series(records: history, bucketID: "session", from: from, to: to)

        XCTAssertEqual(series.map(\.percent), [42])
    }

    func testUtilizationIsClampedToAPercentageAxis() {
        let from = at(day: 1, hour: 0)
        // One reading per bin, so neither can hide the other behind the max.
        let history = records([
            (from.addingTimeInterval(60), ["session": 104]),
            (from.addingTimeInterval(360), ["session": -3])
        ])

        let series = QuotaAnalytics.series(
            records: history,
            bucketID: "session",
            from: from,
            to: from.addingTimeInterval(600),
            maxPoints: 2
        )

        XCTAssertEqual(series.map(\.percent), [100, 0])
    }

    func testDegenerateBudgetsAndRangesProduceNothingRatherThanCrashing() {
        let from = at(day: 1, hour: 0)
        let history = records([(from, ["session": 50])])

        XCTAssertTrue(QuotaAnalytics.series(
            records: history, bucketID: "session", from: from, to: from.addingTimeInterval(60), maxPoints: 0
        ).isEmpty)
        XCTAssertTrue(QuotaAnalytics.series(
            records: history, bucketID: "session", from: from, to: from.addingTimeInterval(-60)
        ).isEmpty)
        // A zero-width range still holds the reading that sits exactly on it.
        XCTAssertEqual(
            QuotaAnalytics.series(records: history, bucketID: "session", from: from, to: from).map(\.percent),
            [50]
        )
    }

    // MARK: - dailyPeaks

    func testEachDayReportsItsHighestReading() {
        let history = records([
            (at(day: 1, hour: 3), ["session": 20]),
            (at(day: 1, hour: 18), ["session": 71]),
            (at(day: 1, hour: 22), ["session": 4]),
            (at(day: 2, hour: 9), ["session": 33])
        ])

        let peaks = QuotaAnalytics.dailyPeaks(records: history, bucketIDs: ["session"], calendar: cal)

        XCTAssertEqual(peaks.map(\.day), [at(day: 1, hour: 0), at(day: 2, hour: 0)])
        XCTAssertEqual(peaks.map(\.peak), [71, 33])
    }

    func testThePeakNamesTheWindowThatReachedIt() {
        let history = records([(at(day: 1), ["session": 40, "weekly": 70])])

        let peaks = QuotaAnalytics.dailyPeaks(records: history, bucketIDs: ["session", "weekly"], calendar: cal)

        XCTAssertEqual(peaks.first?.peak, 70)
        XCTAssertEqual(peaks.first?.peakBucketID, "weekly")
    }

    func testATieGoesToTheFirstBucketAsked() {
        // Deterministic attribution matters: the grid's tooltip names this window.
        let history = records([(at(day: 1), ["session": 70, "weekly": 70])])

        XCTAssertEqual(
            QuotaAnalytics.dailyPeaks(records: history, bucketIDs: ["session", "weekly"], calendar: cal)
                .first?.peakBucketID,
            "session"
        )
        XCTAssertEqual(
            QuotaAnalytics.dailyPeaks(records: history, bucketIDs: ["weekly", "session"], calendar: cal)
                .first?.peakBucketID,
            "weekly"
        )
    }

    func testDaysWithNothingRecordedAreAbsentRatherThanZero() {
        // "The app wasn't running" is not "the quota stayed at zero", and the activity
        // grid paints the two differently.
        let history = records([
            (at(day: 1), ["session": 50]),
            (at(day: 3), ["session": 60])
        ])

        let peaks = QuotaAnalytics.dailyPeaks(records: history, bucketIDs: ["session"], calendar: cal)

        XCTAssertEqual(peaks.map(\.day), [at(day: 1, hour: 0), at(day: 3, hour: 0)])
    }

    func testAskingForNoBucketsYieldsNoPeaks() {
        let history = records([(at(day: 1), ["session": 50])])
        XCTAssertTrue(QuotaAnalytics.dailyPeaks(records: history, bucketIDs: [], calendar: cal).isEmpty)
    }

    // MARK: - insights

    func testCapacityCountsTheDaysThatActuallyGotInTheWay() {
        let history = records([
            (at(day: 1), ["session": 94.9]),
            (at(day: 2), ["session": 95]),
            (at(day: 3), ["session": 100])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 3, hour: 23)
        )

        XCTAssertEqual(insights.daysAtCapacity, 2)
        XCTAssertEqual(insights.daysObserved, 3)
        XCTAssertEqual(insights.averageDailyPeak ?? 0, (94.9 + 95 + 100) / 3, accuracy: 0.0001)
    }

    func testTheBusiestDayIsTheHighestAndTiesGoToTheEarlier() {
        let history = records([
            (at(day: 1), ["session": 80]),
            (at(day: 2), ["session": 80]),
            (at(day: 3), ["session": 12])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 3)
        )

        XCTAssertEqual(insights.busiestDay?.day, at(day: 1, hour: 0))
        XCTAssertEqual(insights.busiestDay?.peak, 80)
    }

    func testTodaysPeakFollowsTheSuppliedClock() {
        let history = records([
            (at(day: 11), ["session": 90]),
            (at(day: 12, hour: 9), ["session": 30]),
            (at(day: 12, hour: 14), ["session": 55])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 12, hour: 15)
        )

        XCTAssertEqual(insights.todayPeak, 55)
        // A day with no readings has no peak to report, even though history exists.
        XCTAssertNil(QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 13)
        ).todayPeak)
    }

    func testConsumptionCountsResetsAndAttributesThemToTheHourTheyLanded() {
        // A window driven to 60%, reset, then driven to 50% again is 110% of a window
        // spent — a chart of peaks alone would call that a 60% day.
        let history = records([
            (at(day: 1, hour: 9), ["session": 0]),
            (at(day: 1, hour: 10), ["session": 60]),
            (at(day: 1, hour: 11), ["session": 10]),
            (at(day: 1, hour: 13), ["session": 50])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 1, hour: 14)
        )

        XCTAssertEqual(insights.averageDailyConsumption ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(insights.busiestHour, 10)
    }

    func testConsumptionTakesTheLargestWindowNeverTheSum() {
        // A session window and the weekly window it rolls up into move on the same
        // work; adding them would bill that work twice.
        let history = records([
            (at(day: 1, hour: 9), ["session": 0, "weekly": 0]),
            (at(day: 1, hour: 10), ["session": 40, "weekly": 12])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session", "weekly"], calendar: cal, now: at(day: 1, hour: 11)
        )

        XCTAssertEqual(insights.averageDailyConsumption ?? 0, 40, accuracy: 0.0001)
    }

    func testAProviderThatHasNeverMovedHasNoConsumptionOrBusiestHour() {
        let history = records([
            (at(day: 1, hour: 9), ["session": 0]),
            (at(day: 1, hour: 10), ["session": 0])
        ])

        let insights = QuotaAnalytics.insights(
            records: history, bucketIDs: ["session"], calendar: cal, now: at(day: 1, hour: 11)
        )

        XCTAssertEqual(insights.daysObserved, 1)
        XCTAssertNil(insights.averageDailyConsumption)
        XCTAssertNil(insights.busiestHour)
    }

    func testNoHistoryYieldsTheEmptySummary() {
        XCTAssertEqual(
            QuotaAnalytics.insights(records: [], bucketIDs: ["session"], calendar: cal, now: at(day: 1)),
            .empty
        )
        XCTAssertEqual(
            QuotaAnalytics.insights(
                records: records([(at(day: 1), ["session": 50])]),
                bucketIDs: [],
                calendar: cal,
                now: at(day: 1)
            ),
            .empty
        )
    }

    // MARK: - Buckets

    func testCoreWindowsExcludePromotionalPoolsAndModelScopedCaps() {
        let buckets = [
            Fixture.bucket(id: "five_hour", kind: .session),
            Fixture.bucket(id: "seven_day", kind: .weekly),
            Fixture.bucket(id: "seven_day_opus", kind: .modelSpecific),
            Fixture.bucket(id: "five_hour_promotional", kind: .session)
        ]

        XCTAssertEqual(
            QuotaAnalytics.coreBuckets(of: buckets).map(\.id),
            ["five_hour", "seven_day"]
        )
    }

    func testAnAccountWithNothingButAPromoPoolStillHasACoreWindow() {
        // A grid with no squares at all would be worse than one drawn from a bonus.
        let onlyScoped = [Fixture.bucket(id: "gemini_pro", kind: .modelSpecific)]
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: onlyScoped).map(\.id), ["gemini_pro"])

        let onlyPromo = [Fixture.bucket(id: "five_hour_promotional", kind: .session)]
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: onlyPromo).map(\.id), ["five_hour_promotional"])
    }

    func testLiveWindowsKeepTheProvidersOwnNamesAndOrder() {
        let service = Fixture.snapshot(id: "antigravity", buckets: [
            Fixture.bucket(id: "five_hour", label: "5-hour", kind: .session),
            Fixture.bucket(id: "seven_day_opus", label: "Opus weekly", kind: .modelSpecific)
        ])
        let history = records([(at(day: 1), ["five_hour": 10, "seven_day_opus": 20])])

        let infos = QuotaAnalytics.bucketInfos(service: service, records: history)

        XCTAssertEqual(infos.map(\.id), ["five_hour", "seven_day_opus"])
        XCTAssertEqual(infos.map(\.label), ["5-hour", "Opus weekly"])
        XCTAssertEqual(infos.map(\.isCore), [true, false])
        XCTAssertEqual(infos.map(\.isLive), [true, true])
    }

    func testAWindowThatOnlySurvivesInHistoryKeepsAnInferredName() {
        // Renamed or dropped with a plan change: months of readings behind it, and no
        // live snapshot left to name it.
        let service = Fixture.snapshot(id: "antigravity", buckets: [
            Fixture.bucket(id: "five_hour", label: "5-hour", kind: .session)
        ])
        let history = records([(at(day: 1), ["five_hour": 10, "legacy_daily_quota": 20])])

        let infos = QuotaAnalytics.bucketInfos(service: service, records: history)

        XCTAssertEqual(infos.map(\.id), ["five_hour", "legacy_daily_quota"])
        XCTAssertEqual(infos.last?.label, "Legacy Daily Quota")
        XCTAssertEqual(infos.last?.isLive, false)
        // Not a constraint the user is under today, so it never colours the grid.
        XCTAssertEqual(infos.last?.isCore, false)
    }

    func testASignedOutProviderStillChartsItsRecordedHistory() {
        // With no live snapshot there is nothing to demote against — refusing to treat
        // any of it as core would leave a signed-out provider with a blank grid.
        let history = records([(at(day: 1), ["daily": 10, "daily_promotional": 90])])

        let infos = QuotaAnalytics.bucketInfos(service: nil, records: history)

        XCTAssertEqual(infos.map(\.id), ["daily", "daily_promotional"])
        XCTAssertEqual(infos.map(\.isCore), [true, false])
        XCTAssertEqual(infos.map(\.isLive), [false, false])
    }

    func testBucketIDsComeFromTheGenericMapAndAreSorted() {
        let history = records([
            (at(day: 1), ["zulu": 1, "alpha": 2]),
            (at(day: 2), ["alpha": 3, "mike": 4])
        ])

        XCTAssertEqual(QuotaAnalytics.bucketIDs(in: history), ["alpha", "mike", "zulu"])
    }

    func testInferredLabelsAreWordCasedFromTheId() {
        XCTAssertEqual(QuotaAnalytics.prettifiedLabel(for: "five_hour"), "Five Hour")
        XCTAssertEqual(QuotaAnalytics.prettifiedLabel(for: "gemini-pro"), "Gemini Pro")
        XCTAssertEqual(QuotaAnalytics.prettifiedLabel(for: "daily"), "Daily")
        XCTAssertEqual(QuotaAnalytics.prettifiedLabel(for: "_"), "_")
    }
}
