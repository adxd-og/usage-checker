import XCTest
@testable import Omelette

/// What a finished limit-share load publishes: spec
/// `docs/superpowers/specs/2026-10-16-limit-analytics.md` § The tab (the page shows a share
/// only for the query on screen) and § Accounts without percent windows (pay as you go with
/// no budget and nothing spent has nothing to divide by). `DashboardState` publishes the
/// load and the query it answered together; "Nothing spent" is read from that answer.
final class LimitsPublishedTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let now = Date(timeIntervalSince1970: 1_788_696_000)
    private let day: TimeInterval = 86_400

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Claude on the API with no budget, nothing in the last 7 days.
    private var api: ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 0)
    }

    private func apiRequest() throws -> LimitShareRequest {
        try XCTUnwrap(LimitShareRules.request(for: api, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: utc))
    }

    func testNothingToMeasurePublishesNoLoadAndAnAnswerWithNoMeasure() {
        let published = LimitsRules.published(serviceID: "claude", kind: .weekly, request: nil, share: nil)
        XCTAssertNil(published.load)
        XCTAssertEqual(published.answer, LimitsQuery(serviceID: "claude", kind: .weekly, measure: nil))
    }

    func testARequestThatFoundNothingSpentPublishesNoLoadButAnswersItsQuery() throws {
        let request = try apiRequest()
        XCTAssertEqual(request.mode, .payAsYouGo(weeklyBudget: nil))
        let published = LimitsRules.published(serviceID: "claude", kind: .weekly, request: request, share: nil)
        XCTAssertNil(published.load)
        XCTAssertEqual(published.answer, LimitsRules.query(serviceID: "claude", kind: .weekly, request: request))
    }

    func testARequestWithAShareAnswersTheQueryItsLoadCarries() throws {
        let share = Fixture.limitShare(
            window: LimitWindow(start: now.addingTimeInterval(-5 * day), end: now),
            chats: [Fixture.chatShare(id: "chat-a", points: 40, cost: 2_480, lastAt: now)]
        )
        let request = LimitShareRequest(mode: .subscription, period: share.window, bucketID: "seven_day", livePercent: 40)
        let published = LimitsRules.published(serviceID: "claude", kind: .weekly, request: request, share: share)
        let load = try XCTUnwrap(published.load)
        XCTAssertEqual(load.share, share)
        XCTAssertEqual(load.request, request)
        XCTAssertEqual(load.query, published.answer)
    }

    func testThePageReadsNothingSpentFromThatAnswer() throws {
        let published = LimitsRules.published(serviceID: "claude", kind: .weekly, request: try apiRequest(), share: nil)
        XCTAssertEqual(
            LimitsRules.page(
                serviceID: "claude", kind: .weekly, service: api, weeklyBudgetUSD: 0,
                load: published.load, answered: published.answer, now: now, calendar: utc
            ),
            .noSpend
        )
    }
}
