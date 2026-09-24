import XCTest
@testable import Omelette

/// Independent verification of spec
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting → Time
/// zone (report B #4): "`dayCache` clears on `NSSystemTimeZoneDidChange`." Written
/// independently of `DayBinCacheTests.swift`: a different zone pair (UTC / UTC-8, not
/// UTC / UTC+3) and its own angle — that the reset is wired specifically to the
/// `NotificationCenter` passed at `init`, not to the notification in general, which is
/// what makes the injected center a real seam and not just a copy of `.default`.
final class DayBinCacheVerificationTests: XCTestCase {
    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private var utc: Calendar { calendar(secondsFromGMT: 0) }
    private var minus8: Calendar { calendar(secondsFromGMT: -8 * 3600) }

    /// 2026-04-10 02:00 UTC: the 10th in UTC, still the 9th (18:00 local) at UTC-8.
    private var earlyMorningUTC: Date {
        utc.date(from: DateComponents(year: 2026, month: 4, day: 10, hour: 2))!
    }
    private var tenthInUTC: Date { utc.startOfDay(for: earlyMorningUTC) }
    private var ninthAtMinus8: Date { minus8.startOfDay(for: earlyMorningUTC) }

    func testTheKeptDayAnswersForAnyMomentInsideIt() {
        let bins = DayBinCache(center: NotificationCenter())
        XCTAssertEqual(bins.start(of: earlyMorningUTC, in: utc), tenthInUTC)
        XCTAssertEqual(
            bins.start(of: tenthInUTC.addingTimeInterval(23 * 3600), in: utc), tenthInUTC,
            "23 hours into the kept day is still the kept day"
        )
    }

    /// A notification on a center this instance never subscribed to must not reset it
    /// — otherwise the injected center would be decoration, not the actual seam.
    func testAZoneChangeOnAnUnwatchedCenterLeavesTheKeptDayInPlace() {
        let watched = NotificationCenter()
        let unrelated = NotificationCenter()
        let bins = DayBinCache(center: watched)
        _ = bins.start(of: earlyMorningUTC, in: utc)

        unrelated.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(
            bins.start(of: earlyMorningUTC, in: minus8), tenthInUTC,
            "still the stale UTC day — the calendar argument alone cannot fix a kept day"
        )
    }

    func testAZoneChangeOnItsOwnCenterMakesTheNextLookupHonorTheNewCalendar() {
        let center = NotificationCenter()
        let bins = DayBinCache(center: center)
        _ = bins.start(of: earlyMorningUTC, in: utc)
        XCTAssertEqual(bins.start(of: earlyMorningUTC, in: minus8), tenthInUTC, "precondition: still stale")

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(
            bins.start(of: earlyMorningUTC, in: minus8), ninthAtMinus8,
            "the reset lookup recomputes with the calendar it is handed now"
        )
    }

    func testTwoInstancesWatchTheirOwnCentersIndependently() {
        let centerA = NotificationCenter()
        let centerB = NotificationCenter()
        let binsA = DayBinCache(center: centerA)
        let binsB = DayBinCache(center: centerB)
        _ = binsA.start(of: earlyMorningUTC, in: utc)
        _ = binsB.start(of: earlyMorningUTC, in: utc)

        centerA.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(binsA.start(of: earlyMorningUTC, in: minus8), ninthAtMinus8, "A reset by its own center")
        XCTAssertEqual(binsB.start(of: earlyMorningUTC, in: minus8), tenthInUTC, "B untouched by A's notification")
    }
}
