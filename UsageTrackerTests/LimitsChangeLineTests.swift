import XCTest
@testable import Omelette

/// The change line on the Price of a percent card: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design, Change signal ("the
/// card says a percent buys about N % less than usual. When the costliest model this week
/// differs from those weeks', the line says so") and § The tab, item 2, in the mockup's
/// words: "A percent buys about 31 % less than your last 3 weeks. Costliest model this
/// week: Fable 5.1 (was Opus 5.5)."
final class LimitsChangeLineTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400
    private let locale = Locale(identifier: "en_GB")
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    private func signal(usualWeeks: Int, modelChange: LimitChangeSignal.ModelChange? = nil) -> LimitChangeSignal {
        LimitChangeSignal(price: 41.4, usualPrice: 60, percentLess: 31, usualWeeks: usualWeeks, modelChange: modelChange)
    }

    func testTheLineSaysHowMuchLessAPercentBuysThanTheLastWeeks() {
        XCTAssertEqual(LimitsCopy.changeLine(signal(usualWeeks: 3)), "A percent buys about 31 % less than your last 3 weeks.")
    }

    func testOneUsualWeekIsTheWeekBefore() {
        XCTAssertEqual(LimitsCopy.changeLine(signal(usualWeeks: 1)), "A percent buys about 31 % less than the week before.")
    }

    func testAChangedCostliestModelIsNamedWithTheOneBefore() {
        XCTAssertEqual(
            LimitsCopy.changeLine(signal(usualWeeks: 3, modelChange: .init(usual: "Opus 5.5", now: "Fable 5.1"))),
            "A percent buys about 31 % less than your last 3 weeks. Costliest model this week: Fable 5.1 (was Opus 5.5)."
        )
    }

    func testThePriceCardCarriesTheLineOnlyWhenTheSignalFires() {
        let week = LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        var load = Fixture.limitLoad(share: Fixture.limitShare(
            window: week,
            chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 828, lastAt: now)],
            price: PercentPrice(dollars: 41.4, tokens: 90_000_000)
        ))
        XCTAssertNil(LimitsCopy.topCard(for: load, now: now, calendar: calendar, locale: locale).change)
        load.change = signal(usualWeeks: 3)
        XCTAssertEqual(
            LimitsCopy.topCard(for: load, now: now, calendar: calendar, locale: locale).change,
            "A percent buys about 31 % less than your last 3 weeks."
        )
    }
}
