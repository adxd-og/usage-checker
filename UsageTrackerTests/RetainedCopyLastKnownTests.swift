import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · All": "Antigravity shows 'Last known
/// 12:50', no 'resets now'", and § Packages P1: "Rule under test: Antigravity label".
/// Any retained tile dates its numbers; the CLI's phrase is untouched.
final class RetainedCopyLastKnownTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func moment(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Antigravity, closed since 12:50 on 25 Sep; its session window reset at 13:00.
    private func closedAntigravity(readAt: Date? = nil) -> ServiceSnapshot {
        Fixture.snapshot(
            id: "antigravity",
            displayName: "Antigravity",
            plan: "Antigravity Pro",
            buckets: [Fixture.bucket(id: "antigravity_gemini_pro", label: "Gemini Pro", percent: 21,
                                     resetsAt: moment(day: 25, hour: 13, minute: 0), kind: .session)],
            state: .notRunning,
            stateMessage: "Antigravity isn't running",
            at: readAt ?? moment(day: 25, hour: 12, minute: 50)
        )
    }

    func testAClosedAntigravityIsDatedLastKnownInsteadOfResetsNow() throws {
        let service = closedAntigravity()
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: service))
        let now = moment(day: 25, hour: 14, minute: 10)
        // What the tile said before: the reset has passed, so the countdown is over.
        XCTAssertEqual(WindowRanking.remainingText(until: hero.resetsAt, now: now), "resets now")
        XCTAssertEqual(
            OMProviderTile.heroCaption(for: service, hero: hero, now: now, calendar: calendar, locale: locale),
            OMTileCaption(title: "Last known", value: "12:50")
        )
    }

    func testAnOlderReadingCarriesItsDay() throws {
        let service = closedAntigravity(readAt: moment(day: 24, hour: 12, minute: 50))
        let stamp = try XCTUnwrap(RetainedCopy.lastKnownStamp(
            for: service, now: moment(day: 25, hour: 9, minute: 0), calendar: calendar, locale: locale
        ))
        XCTAssertTrue(stamp.hasSuffix(", 12:50"), stamp)
        XCTAssertNotEqual(stamp, "12:50")
    }

    func testTheTileAndTheCaptionGiveTheSameStamp() throws {
        let service = closedAntigravity()
        let now = moment(day: 25, hour: 14, minute: 10)
        let stamp = try XCTUnwrap(RetainedCopy.lastKnownStamp(for: service, now: now, calendar: calendar, locale: locale))
        XCTAssertEqual(
            RetainedCopy.caption(for: service, now: now, calendar: calendar, locale: locale),
            "Last known values from \(stamp) — Antigravity isn't running"
        )
    }

    func testALiveServiceHasNoLastKnownStamp() {
        let live = Fixture.snapshot(id: "claude", displayName: "Claude",
                                    buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 57, kind: .session)])
        XCTAssertNil(RetainedCopy.lastKnownStamp(for: live))
    }

    func testALiveTileStillCountsDown() throws {
        let now = moment(day: 25, hour: 12, minute: 49)
        let live = Fixture.snapshot(
            id: "claude", displayName: "Claude",
            buckets: [Fixture.bucket(id: "five_hour", label: "Current session", percent: 57,
                                     resetsAt: moment(day: 25, hour: 13, minute: 0), kind: .session)],
            at: now
        )
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: live))
        let caption = OMProviderTile.heroCaption(for: live, hero: hero, now: now, calendar: calendar, locale: locale)
        XCTAssertEqual(caption.value, "11m left")
        XCTAssertNotEqual(caption.title, RetainedCopy.lastKnownTitle)
    }

    func testASpendLimitStillShowsItsDollars() throws {
        let extra = ExtraUsage(isEnabled: true, monthlyLimit: 1500, usedCredits: 431.26, utilization: 28.75)
        let service = Fixture.snapshot(id: "claude", displayName: "Claude", plan: "Enterprise", extraUsage: extra)
        let hero = try XCTUnwrap(WindowRanking.tileHero(for: service))
        XCTAssertEqual(OMProviderTile.heroCaption(for: service, hero: hero).value, SpendLimitCopy.caption(extra, compact: true))
    }

    /// The `omelette` CLI compiles `CLICore/RetainedStamp.swift`, not this rule: its
    /// phrase stays "as of 12:50".
    func testTheCLIPhraseIsUnchanged() {
        XCTAssertEqual(
            RetainedCopy.asOf(moment(day: 25, hour: 12, minute: 50), now: moment(day: 25, hour: 14, minute: 10),
                              calendar: calendar, locale: locale),
            "as of 12:50"
        )
    }
}
