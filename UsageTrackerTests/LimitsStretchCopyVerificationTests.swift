import XCTest
@testable import Omelette

/// The words under a chat that opens into its stretches: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, item 5 (each stretch
/// shows its time range, its share and dollars, its cold-start cost, and as its name the
/// first human prompt after the boundary). Clock, zone and locale are pinned.
final class LimitsStretchCopyVerificationTests: XCTestCase {
    /// 2026-10-19 12:00 UTC, a Monday.
    private let now = Date(timeIntervalSince1970: 1_792_411_200)
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")

    private func stretch(
        _ opening: StretchOpening = .firstTurn, from: Date, to: Date, points: Double = 2.4, cost: Double = 12.5,
        cold: Double = 0, prompt: String? = "Fix the flaky reset test"
    ) -> ChatStretch {
        ChatStretch(opening: opening, firstAt: from, lastAt: to, points: points, cost: cost, coldStartCost: cold, prompt: prompt)
    }

    private func subtitle(_ stretch: ChatStretch) -> String {
        LimitsCopy.stretchSubtitle(stretch, now: now, calendar: calendar, locale: locale)
    }

    func testAStretchReadsItsHoursHowItBeganAndWhatItsColdStartCost() {
        let from = now.addingTimeInterval(-3_600)      // 11:00 today
        let to = now.addingTimeInterval(-600)          // 11:50 today
        XCTAssertEqual(subtitle(stretch(from: from, to: to)), "Today 11:00–11:50")
        XCTAssertEqual(
            subtitle(stretch(.compaction, from: from, to: to, cold: 1.2)),
            "Today 11:00–11:50 · after a compaction · cold start $1.20"
        )
        XCTAssertEqual(subtitle(stretch(.coldStart, from: from, to: to, cold: 0.31)), "Today 11:00–11:50 · cold start $0.31")
    }

    func testAColdStartThatCostNothingIsNotNamed() {
        let at = now.addingTimeInterval(-3_600)
        XCTAssertEqual(subtitle(stretch(.coldStart, from: at, to: at, cold: 0.004)), "Today 11:00")
        XCTAssertEqual(subtitle(stretch(.coldStart, from: at, to: at, cold: 0)), "Today 11:00")
    }

    func testAStretchAcrossMidnightNamesBothDays() {
        let friday = Date(timeIntervalSince1970: 1_792_411_200 - 3 * 86_400 + 10 * 3_600 + 30 * 60) // Fri 22:30
        let saturday = friday.addingTimeInterval(5 * 3_600)                                          // Sat 03:30
        XCTAssertEqual(subtitle(stretch(from: friday, to: saturday)), "Fri 22:30 – Sat 3:30")
    }

    func testAStretchOlderThanAWeekNamesItsDate() {
        let old = now.addingTimeInterval(-9 * 86_400)
        XCTAssertEqual(subtitle(stretch(from: old, to: old.addingTimeInterval(1_800))), "10 Oct 12:00–12:30")
    }

    func testTheRowsAreTheChatsStretchesInOrderNamedByTheirPrompt() throws {
        let one = stretch(.firstTurn, from: now.addingTimeInterval(-7_200), to: now.addingTimeInterval(-6_000), points: 1.04, cost: 3)
        let two = stretch(.coldStart, from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(-600), points: 0.04, cost: 0.2, prompt: nil)
        let rows = LimitsRules.stretchRows(
            chatIDs: ["chat-a", "chat-z"], stretches: ["chat-a": [one, two], "chat-b": [one]],
            now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(Set(rows.keys), ["chat-a"], "only the chats asked for, and only those with stretches")
        let a = try XCTUnwrap(rows["chat-a"])
        XCTAssertEqual(a.map(\.title), ["Fix the flaky reset test", LimitsCopy.noPrompt])
        XCTAssertEqual(a.map(\.id), ["chat-a#0", "chat-a#1"])
        XCTAssertEqual(a.map(\.share), [LimitsCopy.share(1.04), LimitsCopy.share(0.04)])
        XCTAssertEqual(a.map(\.dollars), [LimitsCopy.dollars(3), LimitsCopy.dollars(0.2)])
    }
}
