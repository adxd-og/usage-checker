import XCTest
@testable import Omelette

/// Spec docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design, Accounting →
/// Time zone: "`dayCache` clears on `NSSystemTimeZoneDidChange`." The three cost
/// aggregators keep the day their last lookup fell in; with an autoupdating calendar
/// that kept day is the only thing still standing on the old zone after a change
/// (report B #4). The notification is posted on a private center, never the app's.
final class DayBinCacheTests: XCTestCase {
    /// 2026-09-05 22:30 UTC: still the 5th in UTC, already the 6th at UTC+3.
    private let lateEvening = Date(timeIntervalSince1970: 1_788_647_400)
    /// 2026-09-05 00:00 UTC.
    private let fifthInUTC = Date(timeIntervalSince1970: 1_788_566_400)
    /// 2026-09-06 00:00 at UTC+3 (2026-09-05 21:00 UTC).
    private let sixthAtPlus3 = Date(timeIntervalSince1970: 1_788_642_000)

    private func calendar(secondsFromGMT: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    func testAMomentIsFiledUnderTheStartOfItsDay() {
        let bins = DayBinCache(center: NotificationCenter())
        let utc = calendar(secondsFromGMT: 0)
        XCTAssertEqual(bins.start(of: lateEvening, in: utc), fifthInUTC)
        XCTAssertEqual(
            bins.start(of: fifthInUTC.addingTimeInterval(60), in: utc), fifthInUTC,
            "the kept day answers for the rest of it"
        )
    }

    /// Why the notification matters: the kept interval still covers the moment, so a
    /// calendar that has moved to another zone gets the old zone's midnight back.
    func testTheKeptDayCannotSeeAZoneChangeOnItsOwn() {
        let bins = DayBinCache(center: NotificationCenter())
        _ = bins.start(of: lateEvening, in: calendar(secondsFromGMT: 0))
        XCTAssertEqual(bins.start(of: lateEvening, in: calendar(secondsFromGMT: 3 * 3600)), fifthInUTC)
    }

    func testASystemTimeZoneChangeDropsTheKeptDay() {
        let center = NotificationCenter()
        let bins = DayBinCache(center: center)
        _ = bins.start(of: lateEvening, in: calendar(secondsFromGMT: 0))

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(bins.start(of: lateEvening, in: calendar(secondsFromGMT: 3 * 3600)), sixthAtPlus3)
    }

    func testAReleasedCacheIsNotKeptAliveByItsObserver() {
        let center = NotificationCenter()
        var bins: DayBinCache? = DayBinCache(center: center)
        weak let released = bins
        bins = nil
        XCTAssertNil(released)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    }

    /// Issue #13: the aggregators that keep chats are told, and only once the kept day
    /// is gone — the handler already bins the moment on the new zone's day.
    func testAZoneChangeIsPassedOnOnceTheKeptDayIsGone() {
        let center = NotificationCenter()
        let bins = DayBinCache(center: center)
        let moment = lateEvening
        let plus3 = calendar(secondsFromGMT: 3 * 3600)
        _ = bins.start(of: moment, in: calendar(secondsFromGMT: 0))
        let seen = SeenDays()
        bins.onZoneChange { [weak bins] in seen.record(bins?.start(of: moment, in: plus3)) }

        center.post(name: .NSSystemTimeZoneDidChange, object: nil)

        XCTAssertEqual(seen.days, [sixthAtPlus3])
    }

    /// The aggregator's own `timeZoneDidChange` resets the cache; if that reset passed
    /// the notice on, the handler would call the aggregator back without end.
    func testAResetAskedForDirectlyIsNotPassedOn() {
        let bins = DayBinCache(center: NotificationCenter())
        let seen = SeenDays()
        bins.onZoneChange { seen.record(nil) }

        bins.reset()

        XCTAssertTrue(seen.days.isEmpty)
    }
}

/// What a zone-change handler saw. The notification is posted synchronously on the
/// test's own thread, so nothing reads this while the handler writes it.
private final class SeenDays: @unchecked Sendable {
    private(set) var days: [Date?] = []
    func record(_ day: Date?) { days.append(day) }
}
