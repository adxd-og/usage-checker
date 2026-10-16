import XCTest
@testable import Omelette

/// What a Limits load publishes beside its share: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab, items 1 (the past
/// windows the picker offers), 2 (the change line) and 5 (stretches). The dashboard
/// publishes the windows its last load found with the provider and window kind they are
/// of; another provider's or the other kind's are never offered. The load carries its
/// stretches and change signal, and answers the same query as the answer beside it.
final class LimitsLoadPublishTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private var lastWeek: LimitPastWindow {
        let end = now.addingTimeInterval(-5 * day)
        return LimitPastWindow(start: end.addingTimeInterval(-7 * day), end: end, resets: end...end)
    }

    func testThePickerOffersTheWindowsFoundForThisProviderAndKind() {
        let list = DashboardState.LimitPastWindows(serviceID: "claude", kind: .weekly, windows: [lastWeek])
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "claude", kind: .weekly), [lastWeek])
    }

    func testWindowsFoundForAnotherProviderOrKindAreNotOffered() {
        let list = DashboardState.LimitPastWindows(serviceID: "claude", kind: .weekly, windows: [lastWeek])
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "codex", kind: .weekly), [])
        XCTAssertEqual(LimitsRules.pastWindows(list, serviceID: "claude", kind: .session), [])
        XCTAssertEqual(LimitsRules.pastWindows(nil, serviceID: "claude", kind: .weekly), [], "none before the first load")
    }

    func testAPublishedLoadCarriesItsStretchesAndChangeSignal() throws {
        let week = LimitWindow(start: now.addingTimeInterval(-5 * day), end: now)
        let share = Fixture.limitShare(
            window: week, chats: [Fixture.chatShare(id: "chat-a", points: 20, cost: 828, lastAt: now)]
        )
        let request = LimitShareRequest(mode: .subscription, period: week, bucketID: "seven_day", livePercent: 20)
        let stretch = ChatStretch(
            opening: .firstTurn, firstAt: week.start, lastAt: now, points: 20, cost: 828, coldStartCost: 0,
            prompt: "Fix the flaky reset test"
        )
        let change = LimitChangeSignal(price: 41.4, usualPrice: 60, percentLess: 31, usualWeeks: 3, modelChange: nil)

        let published = LimitsRules.published(
            serviceID: "claude", kind: .weekly, request: request, share: share,
            stretches: ["chat-a": [stretch]], change: change
        )

        let load = try XCTUnwrap(published.load)
        XCTAssertEqual(load.stretches, ["chat-a": [stretch]])
        XCTAssertEqual(load.change, change)
        XCTAssertEqual(load.period, .current)
        XCTAssertEqual(load.query, published.answer)
    }
}
