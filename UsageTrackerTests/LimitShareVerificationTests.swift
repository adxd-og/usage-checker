import XCTest
@testable import Omelette

/// Verification of the limit-share rule, written from the spec
/// (`docs/superpowers/specs/2026-10-16-limit-analytics.md` § Design "The rule: limit share
/// by half-hour bins" and § Accounts without percent windows) and not from the executor's
/// tests. It leans on what the executor's files leave thin:
/// - the invariant "chats + Outside (+ unbinned Outside + Earlier) = total" under a seeded
///   random sweep, with an independent reference for bin membership and the lag;
/// - bin edges: a turn on an edge opens the later bin, a reading on it closes the earlier;
/// - whole-number Claude percents and fractional Codex percents;
/// - price and change-signal thresholds (exactly 1 point, exactly 10 points, exactly 75 %);
/// - empty inputs, windows that have not started, DST months.
final class LimitShareVerificationTests: XCTestCase {
    /// 2026-09-06 12:00 UTC, a Sunday.
    private let start = Date(timeIntervalSince1970: 1_788_696_000)
    private let alpha = "-Users-tester-Projects-alpha"
    private let beta = "-Users-tester-Projects-beta"
    private let day: TimeInterval = 86_400

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    private func window(_ minutes: Double) -> LimitWindow { LimitWindow(start: start, end: at(minutes)) }

    private func share(
        window: LimitWindow, _ readings: [(Double, Double)], _ turns: [TurnCost],
        bucketID: String = "five_hour"
    ) -> LimitShare {
        LimitShareRules.share(
            window: window,
            bucketID: bucketID,
            readings: Fixture.readings(
                bucketID: bucketID, points: readings.map { (at: at($0.0), percent: $0.1) }
            ),
            log: TurnCostLog(turns: turns)
        )
    }

    private func points(_ result: LimitShare, _ chat: String) -> Double {
        result.chats.first { $0.id == chat }?.points ?? -1
    }

    // MARK: - Bin edges

    func testATurnOnABinEdgeOpensTheLaterBinWhileAReadingOnTheEdgeClosesTheEarlierOne() {
        // 90 minutes, three bins. Chat B's turn is on the window's first instant (bin 0), chat A's
        // on minute 30 exactly (bin 1), chat C's on the window's end (not this window's).
        let result = share(
            window: window(90),
            [(30, 4), (60, 6), (90, 6)],
            [
                Fixture.turnCost(at: at(0), chat: "chat-b", cost: 1),
                Fixture.turnCost(at: at(30), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(90), chat: "chat-c", cost: 1),
            ]
        )

        XCTAssertEqual(result.bins.map(\.delta), [4, 2, 0])
        XCTAssertEqual(points(result, "chat-b"), 4, accuracy: 1e-9, "the minute-30 reading closes bin 0, where chat B ran")
        XCTAssertEqual(points(result, "chat-a"), 2, accuracy: 1e-9, "the minute-60 reading closes bin 1, where chat A's minute-30 turn opened")
        XCTAssertEqual(result.chats.map(\.id).sorted(), ["chat-a", "chat-b"], "a turn on the window's end belongs to the next window")
        XCTAssertEqual(result.outside, 0)
    }

    func testAReadingOnABinEdgeWithNoTurnBeforeItAndOneAfterItIsOutsideThisMac() {
        // The reading at minute 30 closes bin 0. A turn at minute 30 opens bin 1. Bin 0 has no turn
        // and no bin before it, so its 4 points are Outside, not the minute-30 chat's.
        let result = share(
            window: window(60),
            [(30, 4)],
            [Fixture.turnCost(at: at(30), chat: "chat-a", cost: 1)]
        )

        XCTAssertEqual(result.bins.map(\.delta), [4, 0])
        XCTAssertEqual(result.outside, 4)
        XCTAssertEqual(points(result, "chat-a"), 0)
        XCTAssertEqual(result.percent, 4)
    }

    func testAReadingAtTheWindowEndCountsAndOneAtItsStartDoesNot() {
        let result = share(
            window: window(60),
            [(0, 50), (60, 3)],
            [Fixture.turnCost(at: at(45), chat: "chat-a", cost: 1)]
        )
        XCTAssertEqual(result.percent, 3, "the reading on the start is the previous window's; the one on the end is this window's")
        XCTAssertEqual(points(result, "chat-a"), 3, accuracy: 1e-9)
    }

    // MARK: - The lag

    func testALagReachesOneBinBackFromAnyBinWithoutATurnNotTwo() {
        // Turn in bin 2. Bins 3 (lag, one back) and 4 (two back) both move.
        let result = share(
            window: window(150),
            [(100, 3), (130, 5)],
            [Fixture.turnCost(at: at(65), chat: "chat-a", cost: 1)]
        )
        XCTAssertEqual(result.bins.map(\.delta), [0, 0, 0, 3, 2])
        XCTAssertEqual(result.bins[3].chats["chat-a"] ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(result.bins[4].chats, [:])
        XCTAssertEqual(result.bins[4].outside, 2)
        XCTAssertEqual(result.outside, 2)
    }

    func testABinWithItsOwnTurnsKeepsItsPointsAndNothingLagsBackFromIt() {
        // Chat A ran in bin 0, chat B in bin 1; bin 1 moved by 5. All of it is chat B's.
        let result = share(
            window: window(60),
            [(50, 5)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 9),
                Fixture.turnCost(at: at(35), chat: "chat-b", cost: 1),
            ]
        )
        XCTAssertEqual(points(result, "chat-b"), 5, accuracy: 1e-9)
        XCTAssertEqual(points(result, "chat-a"), 0, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 0)
    }

    func testALagFromABinWhoseOwnPercentDidNotMoveStillGoesToItsChats() {
        // Bin 0 has the turn and no reading. Bin 1 moves 2. The lag gives it to bin 0's chat.
        let result = share(
            window: window(60),
            [(50, 2)],
            [Fixture.turnCost(at: at(10), chat: "chat-a", cost: 1)]
        )
        XCTAssertEqual(result.bins.map(\.delta), [0, 2])
        XCTAssertEqual(points(result, "chat-a"), 2, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 0)
    }

    func testTurnsWithNoDollarsAndNoTokensSplitTheirBinsPointsEvenly() {
        let result = share(
            window: window(30),
            [(20, 4)],
            [
                Fixture.turnCost(at: at(1), chat: "chat-a", cost: 0, tokens: 0),
                Fixture.turnCost(at: at(2), chat: "chat-b", cost: 0, tokens: 0),
            ]
        )
        XCTAssertEqual(points(result, "chat-a"), 2, accuracy: 1e-9)
        XCTAssertEqual(points(result, "chat-b"), 2, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 0)
    }

    // MARK: - Windows and turns of one chat

    func testAChatThatStraddlesTheWindowStartOnlyCountsWhatRanInsideTheWindow() {
        let result = share(
            window: window(60),
            [(20, 6)],
            [
                Fixture.turnCost(at: at(-30), chat: "chat-a", project: alpha, cost: 100, tokens: 9_000),
                Fixture.turnCost(at: at(-1), chat: "chat-a", project: beta, cost: 100, tokens: 9_000),
                Fixture.turnCost(at: at(10), chat: "chat-a", project: alpha, cost: 2, tokens: 500),
            ]
        )
        let chat = result.chats.first
        XCTAssertEqual(result.chats.count, 1)
        XCTAssertEqual(chat?.cost ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(chat?.tokens, 500)
        XCTAssertEqual(chat?.lastAt, at(10))
        XCTAssertEqual(chat?.projectSlug, alpha, "the project of the in-window turn, not of the turn a minute before the start")
        XCTAssertEqual(result.cost, 2, accuracy: 1e-9)
    }

    func testAChatsProjectIsItsLatestMainThreadTurnWhateverOrderTheLogIsHandedIn() {
        let result = share(
            window: window(60),
            [(50, 4)],
            [
                Fixture.turnCost(at: at(40), chat: "chat-a", project: beta, cost: 1),
                Fixture.turnCost(at: at(50), chat: "chat-a", project: "-sub", cost: 1, isMainThread: false),
                Fixture.turnCost(at: at(10), chat: "chat-a", project: alpha, cost: 1),
            ]
        )
        XCTAssertEqual(result.chats.first?.projectSlug, beta)
    }

    func testAChatOnlyItsSubAgentsRanInIsStillAChatWithItsPointsAndProject() {
        let result = share(
            window: window(60),
            [(20, 3)],
            [Fixture.turnCost(at: at(5), chat: "parent", project: beta, cost: 4, isMainThread: false)]
        )
        XCTAssertEqual(result.chats.map(\.id), ["parent"])
        XCTAssertEqual(result.chats.first?.projectSlug, beta)
        XCTAssertEqual(points(result, "parent"), 3, accuracy: 1e-9)
        XCTAssertEqual(result.projects.map(\.id), [beta])
        XCTAssertEqual(result.projects.first?.chats, 1)
    }

    func testChatsAreRankedByPointsThenDollarsThenId() {
        // Bin 0: chats b and c at equal dollars share equally; chat a ran in a bin that did not move.
        let result = share(
            window: window(120),
            [(20, 4)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-c", cost: 2),
                Fixture.turnCost(at: at(6), chat: "chat-b", cost: 2),
                Fixture.turnCost(at: at(95), chat: "chat-a", cost: 5),
                Fixture.turnCost(at: at(96), chat: "chat-d", cost: 5),
                Fixture.turnCost(at: at(97), chat: "chat-z", cost: 1),
            ]
        )
        XCTAssertEqual(result.chats.map(\.id), ["chat-b", "chat-c", "chat-a", "chat-d", "chat-z"])
    }

    // MARK: - Empty input

    func testNoReadingsAndNoTurnsGiveAnEmptyShareAtZeroPercent() {
        let result = share(window: window(120), [], [])
        XCTAssertEqual(result.percent, 0)
        XCTAssertEqual(result.outside, 0)
        XCTAssertTrue(result.chats.isEmpty)
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertEqual(result.bins.count, 4)
        XCTAssertEqual(result.bins.map(\.delta), [0, 0, 0, 0])
        XCTAssertNil(result.price)
        XCTAssertEqual(result.cost, 0)
        XCTAssertEqual(result.tokens, 0)
    }

    func testTurnsWithNoReadingsListTheirChatsAtZeroAndGiveNoPrice() {
        let result = share(
            window: window(60), [],
            [Fixture.turnCost(at: at(5), chat: "chat-a", cost: 3)]
        )
        XCTAssertEqual(result.percent, 0)
        XCTAssertEqual(result.chats.map(\.id), ["chat-a"])
        XCTAssertEqual(result.chats.first?.points, 0)
        XCTAssertEqual(result.cost, 3, accuracy: 1e-9)
        XCTAssertNil(result.price, "no attributed point")
    }

    func testReadingsWithNoTurnsAreAllOutsideThisMac() {
        let result = share(window: window(60), [(20, 3), (50, 8)], [])
        XCTAssertEqual(result.percent, 8)
        XCTAssertEqual(result.outside, 8)
        XCTAssertTrue(result.chats.isEmpty)
        XCTAssertEqual(result.attributedPoints, 0)
    }

    func testAnEmptyRequestOnALiveBucketAtZeroIsAnEmptyShare() throws {
        let now = start
        let session = Fixture.bucket(
            id: "five_hour", percent: 0, resetsAt: now.addingTimeInterval(3 * 3_600), kind: .session
        )
        let claude = Fixture.snapshot(id: "claude", buckets: [session])
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: Calendar(identifier: .gregorian)
        ))
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: TurnCostLog(), readings: []))
        XCTAssertEqual(result.percent, 0)
        XCTAssertTrue(result.chats.isEmpty)
        XCTAssertEqual(result.outside, 0)
    }

    // MARK: - Price thresholds

    func testAPriceNeedsOnePointAndNinetyNineHundredthsIsNotEnough() {
        let turn = Fixture.turnCost(at: at(5), chat: "chat-a", cost: 7, tokens: 700)
        XCTAssertNil(share(window: window(60), [(20, 0.99)], [turn]).price)
        let one = share(window: window(60), [(20, 1.0)], [turn])
        XCTAssertEqual(one.price?.dollars ?? -1, 7, accuracy: 1e-9)
        XCTAssertEqual(one.price?.tokens ?? -1, 700, accuracy: 1e-9)
        let more = share(window: window(60), [(20, 1.01)], [turn])
        XCTAssertEqual(more.price?.dollars ?? -1, 7 / 1.01, accuracy: 1e-9)
    }

    func testOneAttributedPointStillPricesWhenFloatingPointSumsItJustUnderOne() {
        // 4.1 reached with 3.1 of it Outside: 4.1 - 3.1 is 0.9999999999999996 in floating point.
        let result = share(
            window: window(150),
            [(20, 3.1), (100, 4.1)],
            [Fixture.turnCost(at: at(95), chat: "chat-a", cost: 5, tokens: 100)]
        )
        XCTAssertEqual(result.outside, 3.1, accuracy: 1e-9)
        XCTAssertEqual(result.attributedPoints, 1, accuracy: 1e-9)
        XCTAssertLessThan(result.attributedPoints, 1, "the premise: binary subtraction lands just under 1")
        XCTAssertNotNil(result.price, "one point in decimal; a threshold must not be fooled by binary sums")
    }

    func testThePriceDividesTheWholeWindowsCostEvenWhenOutsideAlsoMoved() throws {
        // 2 Outside points + 4 local ones, $12 local: $3 a point.
        let result = share(
            window: window(150),
            [(20, 2), (100, 6)],
            [Fixture.turnCost(at: at(95), chat: "chat-a", cost: 12, tokens: 1_200)]
        )
        XCTAssertEqual(result.outside, 2)
        let price = try XCTUnwrap(result.price)
        XCTAssertEqual(price.dollars, 3, accuracy: 1e-9)
        XCTAssertEqual(price.tokens, 300, accuracy: 1e-9)
    }

    // MARK: - Fractional percents (Codex) and whole percents (Claude)

    func testCodexFractionsSplitAndAddUpToTheFractionalPercent() {
        let result = share(
            window: window(120),
            [(20, 0.7), (50, 2.45), (100, 3.15)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(35), chat: "chat-b", cost: 3),
            ],
            bucketID: "codex_session"
        )
        XCTAssertEqual(result.percent, 3.15, accuracy: 1e-9)
        XCTAssertEqual(result.chats.reduce(0) { $0 + $1.points } + result.outside, 3.15, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 0.7, accuracy: 1e-9, "bin 3 has no turn and the bin before it has none: the 0.7 that moved there is Outside")
    }

    func testWholeNumberPercentsGiveWholeNumberBinsAndWholeOutside() {
        let result = share(
            window: window(180),
            [(20, 1), (50, 1), (80, 2), (110, 5), (170, 9)],
            [
                Fixture.turnCost(at: at(5), chat: "chat-a", cost: 1),
                Fixture.turnCost(at: at(100), chat: "chat-b", cost: 2),
            ]
        )
        for bin in result.bins { XCTAssertEqual(bin.delta, bin.delta.rounded(), accuracy: 1e-12) }
        XCTAssertEqual(result.outside, result.outside.rounded(), accuracy: 1e-9)
    }

    // MARK: - Windows

    func testAWindowThatHasNotStartedHasNoBounds() {
        let now = start
        let early = Fixture.bucket(
            id: "five_hour", percent: 1, resetsAt: now.addingTimeInterval(6 * 3_600), kind: .session
        )
        XCTAssertNil(LimitShareRules.currentWindow(of: early, now: now), "start would be an hour after now")
    }

    func testAWindowResettingRightNowEndsNow() {
        let now = start
        let session = Fixture.bucket(id: "five_hour", percent: 1, resetsAt: now, kind: .session)
        XCTAssertEqual(
            LimitShareRules.currentWindow(of: session, now: now),
            LimitWindow(start: now.addingTimeInterval(-5 * 3_600), end: now)
        )
    }

    func testAPercentOverAHundredIsClampedInTheRequestsLivePercent() throws {
        let now = start
        let session = Fixture.bucket(id: "five_hour", percent: 104, resetsAt: now.addingTimeInterval(3_600), kind: .session)
        let claude = Fixture.snapshot(id: "claude", buckets: [session])
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: Calendar(identifier: .gregorian)
        ))
        XCTAssertEqual(request.livePercent, 100)
    }

    func testCodexProliteLoadsItsWeekAndFractionalLivePercentEndToEnd() throws {
        let now = start
        let weekly = Fixture.bucket(
            id: "codex_session", label: "Weekly", percent: 10.35,
            resetsAt: now.addingTimeInterval(day), kind: .weekly, windowLength: 10_080 * 60
        )
        let prolite = Fixture.snapshot(id: "codex", plan: "Prolite", buckets: [weekly])
        let calendar = Calendar(identifier: .gregorian)

        XCTAssertNil(LimitShareRules.request(for: prolite, kind: .session, weeklyBudgetUSD: 0, now: now, calendar: calendar))
        let request = try XCTUnwrap(
            LimitShareRules.request(for: prolite, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: calendar)
        )
        XCTAssertEqual(request.bucketID, "codex_session")
        XCTAssertEqual(request.period, LimitWindow(start: now.addingTimeInterval(-6 * day), end: now))
        XCTAssertEqual(request.livePercent, 10.35)

        let readings = Fixture.readings(service: "codex", bucketID: "codex_session", points: [
            (at: now.addingTimeInterval(-5 * day + 600), percent: 1.2),
            (at: now.addingTimeInterval(-2 * day + 600), percent: 4.8),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-5 * day + 100), chat: "chat-a", cost: 10),
            Fixture.turnCost(at: now.addingTimeInterval(-2 * day + 100), chat: "chat-b", cost: 30),
        ])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(result.percent, 10.35, accuracy: 1e-9)
        XCTAssertEqual(result.chats.reduce(0) { $0 + $1.points } + result.outside, 10.35, accuracy: 1e-9)
        XCTAssertEqual(points(result, "chat-a"), 1.2, accuracy: 1e-9)
        XCTAssertEqual(points(result, "chat-b"), 3.6, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 5.55, accuracy: 1e-9, "the live reading moved the last bin, where no turn ran")
    }

    // MARK: - Modes

    func testExtraUsageEnabledWithNoMonthlyLimitIsNotASpendLimit() {
        let unlimited = ExtraUsage(isEnabled: true, monthlyLimit: 0, usedCredits: 0, utilization: 0)
        let team = Fixture.snapshot(id: "claude", plan: "Team", buckets: [], extraUsage: unlimited, weekCost: 10)
        XCTAssertEqual(LimitShareRules.mode(of: team, weeklyBudgetUSD: 0), .payAsYouGo(weeklyBudget: nil))
    }

    func testAnErroringAccountThatStillHoldsItsLastWindowsIsStillASubscription() {
        let buckets = [Fixture.bucket(id: "five_hour", percent: 9, kind: .session)]
        let stale = Fixture.snapshot(id: "claude", buckets: buckets, state: .error)
        XCTAssertEqual(LimitShareRules.mode(of: stale, weeklyBudgetUSD: 0), .subscription)
    }

    func testAnErroringAccountWithNoWindowsHasNoMode() {
        let broken = Fixture.snapshot(id: "claude", plan: nil, buckets: [], state: .error)
        XCTAssertNil(LimitShareRules.mode(of: broken, weeklyBudgetUSD: 500))
    }

    func testANegativeBudgetIsNoBudget() {
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 10)
        XCTAssertEqual(LimitShareRules.mode(of: api, weeklyBudgetUSD: -5), .payAsYouGo(weeklyBudget: nil))
    }

    func testAZeroBudgetFallsBackToThePeriodsSpendAndZeroSpendHasNoDenominator() {
        XCTAssertEqual(
            LimitShareRules.denominator(for: .payAsYouGo(weeklyBudget: 0), periodSpend: 40), .spend(40)
        )
        XCTAssertEqual(
            LimitShareRules.denominator(for: .payAsYouGo(weeklyBudget: 100), periodSpend: 0), .budget(100),
            "a budget measures an empty week too"
        )
        XCTAssertNil(LimitShareRules.denominator(for: .spendLimit(monthlyLimit: 0, usedCredits: 5), periodSpend: 5))
    }

    // MARK: - Pay as you go and spend limit

    func testPayAsYouGoUsesARolling7DayPeriodWhoseStartIsInAndWhoseEndIsOut() throws {
        let now = start
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 100)
        let calendar = Calendar(identifier: .gregorian)
        let request = try XCTUnwrap(
            LimitShareRules.request(for: api, kind: .weekly, weeklyBudgetUSD: 200, now: now, calendar: calendar)
        )
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: now.addingTimeInterval(-7 * day), chat: "chat-first", cost: 50),
            Fixture.turnCost(at: now.addingTimeInterval(-7 * day - 1), chat: "chat-before", cost: 999),
            Fixture.turnCost(at: now, chat: "chat-now", cost: 999),
        ])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(result.chats.map(\.id), ["chat-first"])
        XCTAssertEqual(result.chats.first?.points ?? -1, 25, accuracy: 1e-9, "$50 of a $200 budget")
        XCTAssertEqual(result.percent, 25, accuracy: 1e-9)
    }

    func testPayAsYouGoOverItsBudgetIsNotClamped() throws {
        let now = start
        let api = Fixture.snapshot(id: "claude", plan: nil, buckets: [], weekCost: 600)
        let request = try XCTUnwrap(LimitShareRules.request(
            for: api, kind: .weekly, weeklyBudgetUSD: 500, now: now, calendar: Calendar(identifier: .gregorian)
        ))
        let log = TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 600)])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(result.percent, 120, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 0)
    }

    func testASpendLimitWhoseLocalSpendRunsAheadOfTheServerHasNoOutside() throws {
        let now = start
        let calendar = utc
        let team = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 500, utilization: 25),
            weekCost: 10
        )
        let request = try XCTUnwrap(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: calendar)
        )
        let log = TurnCostLog(turns: [Fixture.turnCost(at: now.addingTimeInterval(-day), chat: "chat-a", cost: 800)])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: []))
        XCTAssertEqual(result.outside, 0)
        XCTAssertEqual(result.percent, 40, accuracy: 1e-9, "this Mac's own dollars, not the server's smaller figure")
        XCTAssertEqual(result.bins.map(\.delta).reduce(0, +) + result.unbinnedOutside, result.percent, accuracy: 1e-9)
    }

    func testASpendLimitOnTheFirstInstantOfTheMonthHasNoPeriodYetAndASecondLaterDoes() {
        let team = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 2_000, usedCredits: 0, utilization: 0)
        )
        let monthStart = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC
        XCTAssertNil(LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: monthStart, calendar: utc))
        XCTAssertNotNil(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: monthStart.addingTimeInterval(1), calendar: utc)
        )
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// A month in `zone`: a spend limit of $10,000 with $5,000 used on the server; this Mac spent
    /// $10 a day (day totals), of which only the last day is still a turn.
    private func monthInvariants(zone: String, year: Int, month: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let first = try XCTUnwrap(cal.date(from: DateComponents(year: year, month: month, day: 1)), file: file, line: line)
        let days = try XCTUnwrap(cal.range(of: .day, in: .month, for: first), file: file, line: line).count
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: year, month: month, day: days, hour: 23, minute: 30)), file: file, line: line)
        let noon = try XCTUnwrap(cal.date(from: DateComponents(year: year, month: month, day: days, hour: 12)), file: file, line: line)
        let rows = (1...days).map { d -> CLIDailySummary in
            let dayStart = cal.startOfDay(for: cal.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!)
            return CLIDailySummary(day: dayStart, totalCost: 10, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:])
        }
        let team = Fixture.snapshot(
            id: "claude", plan: "Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 10_000, usedCredits: 5_000, utilization: 50),
            weekCost: 10
        )
        let request = try XCTUnwrap(
            LimitShareRules.request(for: team, kind: .weekly, weeklyBudgetUSD: 0, now: now, calendar: cal),
            file: file, line: line
        )
        XCTAssertEqual(request.period.start, first, "\(zone): the month starts at the local midnight of the 1st", file: file, line: line)
        let log = TurnCostLog(turns: [Fixture.turnCost(at: noon, chat: "chat-z", cost: 10)])
        let result = try XCTUnwrap(
            LimitShareRules.share(for: request, log: log, readings: [], dailySpend: rows), file: file, line: line
        )
        let earlier = try XCTUnwrap(result.earlier, "\(zone) \(year)-\(month)", file: file, line: line)
        XCTAssertEqual(earlier.cost, Double(days - 1) * 10, accuracy: 1e-9, "\(zone): every day row of the month counts once", file: file, line: line)
        XCTAssertEqual(result.chats.first?.points ?? -1, 0.1, accuracy: 1e-9, "\(zone)", file: file, line: line)
        XCTAssertEqual(result.outside, (5_000 - Double(days) * 10) / 100, accuracy: 1e-9, "\(zone)", file: file, line: line)
        XCTAssertEqual(result.percent, 50, accuracy: 1e-9, "\(zone)", file: file, line: line)
        XCTAssertEqual(
            result.chats.reduce(0) { $0 + $1.points } + result.outside + earlier.points, result.percent,
            accuracy: 1e-9, "\(zone)", file: file, line: line
        )
        XCTAssertEqual(
            result.bins.map(\.delta).reduce(0, +) + result.unbinnedOutside + earlier.points, result.percent,
            accuracy: 1e-9, "\(zone)", file: file, line: line
        )
        XCTAssertEqual(result.bins.count, Int((now.timeIntervalSince(first) / 1_800).rounded(.up)), "\(zone)", file: file, line: line)
    }

    func testASpendLimitMonthKeepsItsTotalsInZonesWhoseMonthIsNot31x24Hours() throws {
        try monthInvariants(zone: "Europe/Vilnius", year: 2026, month: 10)   // 31 days + 1 h
        try monthInvariants(zone: "Europe/Vilnius", year: 2026, month: 3)    // 31 days - 1 h
        try monthInvariants(zone: "America/New_York", year: 2026, month: 11) // 30 days + 1 h
        try monthInvariants(zone: "America/New_York", year: 2026, month: 3)  // 31 days - 1 h
        try monthInvariants(zone: "Australia/Sydney", year: 2026, month: 10) // 31 days - 1 h
        try monthInvariants(zone: "Australia/Sydney", year: 2026, month: 4)  // 30 days + 1 h
        try monthInvariants(zone: "UTC", year: 2026, month: 2)               // 28 days
    }

    // MARK: - Change signal

    private let weekStart = Date(timeIntervalSince1970: 1_788_696_000)

    private var now: Date { weekStart.addingTimeInterval(3 * day) }
    private var horizonStart: Date { now.addingTimeInterval(-31 * day) }

    private func week(
        _ weeksBack: Int, points: Double, cost: Double, model: String = "claude-opus-4-5"
    ) -> LimitShare {
        let weekBegin = weekStart.addingTimeInterval(-Double(weeksBack) * 7 * day)
        let end = weeksBack == 0 ? now : weekBegin.addingTimeInterval(7 * day)
        return LimitShareRules.share(
            window: LimitWindow(start: weekBegin, end: end),
            bucketID: "seven_day",
            readings: Fixture.readings(
                bucketID: "seven_day", points: [(at: weekBegin.addingTimeInterval(20 * 60), percent: points)]
            ),
            log: TurnCostLog(turns: [
                Fixture.turnCost(at: weekBegin.addingTimeInterval(5 * 60), chat: "w\(weeksBack)", model: model, cost: cost),
            ])
        )
    }

    private var usual: [LimitShare] {
        [week(1, points: 40, cost: 2_400), week(2, points: 50, cost: 3_000), week(3, points: 30, cost: 1_800)]
    }

    func testExactlyTenAttributedPointsThisWeekCanFireAndJustUnderCannot() {
        XCTAssertNotNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 10, cost: 400), previous: usual, horizonStart: horizonStart
        ))
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 9.99, cost: 399), previous: usual, horizonStart: horizonStart
        ))
    }

    func testAPreviousWeekWithExactlyTenAttributedPointsIsUsual() throws {
        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800),
            previous: [week(1, points: 10, cost: 600)], horizonStart: horizonStart
        ))
        XCTAssertEqual(signal.usualPrice, 60, accuracy: 1e-9)
    }

    func testJustUnderThreeQuartersFiresAndRoundsItsPercent() throws {
        let fires = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 899.8), previous: usual, horizonStart: horizonStart
        ))
        XCTAssertEqual(fires.price, 44.99, accuracy: 1e-9)
        XCTAssertEqual(fires.percentLess, 25, "25.02 rounds to 25")

        let more = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 880), previous: usual, horizonStart: horizonStart
        ))
        XCTAssertEqual(more.percentLess, 27, "$44 against $60: 26.67 rounds to 27")
    }

    func testAPriceAboveUsualNeverFires() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 2_000), previous: usual, horizonStart: horizonStart
        ))
    }

    func testAWeekStartingExactlyOnTheHorizonIsUsualAndOneSecondBeforeIsNot() throws {
        let onTheEdge = week(4, points: 40, cost: 2_400)
        XCTAssertEqual(onTheEdge.window.start, horizonStart)
        XCTAssertNotNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800), previous: [onTheEdge], horizonStart: horizonStart
        ))
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800), previous: [onTheEdge],
            horizonStart: horizonStart.addingTimeInterval(1)
        ))
    }

    func testTheCurrentWeekIsNeverItsOwnUsualWeek() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800), previous: [week(0, points: 20, cost: 4_000)],
            horizonStart: horizonStart
        ))
    }

    func testTheModelIsComparedByDisplayNameSoADatedIdIsTheSameModel() throws {
        let dated = "claude-opus-4-5-20251101"
        let plain = "claude-opus-4-5"
        let datedName = try XCTUnwrap(ModelPricing.displayName(for: dated))
        let plainName = try XCTUnwrap(ModelPricing.displayName(for: plain))
        try XCTSkipUnless(datedName == plainName, "the price table names these two differently")

        let signal = try XCTUnwrap(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 800, model: dated), previous: usual,
            horizonStart: horizonStart
        ))
        XCTAssertNil(signal.modelChange)
    }

    // MARK: - Reset detection and the change threshold (added after the mutation pass)

    func testADropOfExactlyFivePointsThatHoldsIsAResetAndABounceBackIsNot() {
        func series(_ points: [(Double, Double)]) -> [LimitReading] {
            LimitShareRules.series(
                Fixture.readings(bucketID: "seven_day", points: points.map { (at: at($0.0), percent: $0.1) }),
                bucketID: "seven_day"
            )
        }
        XCTAssertEqual(
            LimitShareRules.resets(in: series([(0, 30), (60, 25), (120, 25)])).count, 1,
            "30 to 25 is 5 points, and it holds"
        )
        XCTAssertEqual(
            LimitShareRules.resets(in: series([(0, 30), (60, 0), (120, 31)])).count, 0,
            "a drop to 0 that is back at 31 a reading later is noise"
        )
        XCTAssertEqual(LimitShareRules.resets(in: series([(0, 30), (60, 26), (120, 26)])).count, 0, "4 points")
    }

    func testAPriceBetweenThreeQuartersAndFourFifthsOfUsualDoesNotFire() {
        XCTAssertNil(LimitShareRules.changeSignal(
            kind: .weekly, current: week(0, points: 20, cost: 940), previous: usual, horizonStart: horizonStart
        ), "$47 is 78 % of $60")
    }

    // MARK: - A reset the poll sees after the window's computed start

    /// The live Claude session bucket at `now`, 30 minutes into its window.
    private func liveSession(percent: Double) throws -> (LimitShareRequest, windowStart: Date) {
        let session = Fixture.bucket(
            id: "five_hour", percent: percent, resetsAt: start.addingTimeInterval(4.5 * 3_600), kind: .session
        )
        let claude = Fixture.snapshot(id: "claude", buckets: [session])
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude, kind: .session, weeklyBudgetUSD: 0, now: start, calendar: utc
        ))
        return (request, request.period.start)
    }

    /// Spec § Design, Totals: "Chat shares plus Outside equal the window's percent now".
    /// Real history on this Mac (`history.jsonl`, 423 session resets since 2026-07-15) has 5 whose
    /// last old-window reading is stamped AFTER the window's computed start (`resets_at` is rounded
    /// to the second and the poll's clock differs): 43 % at 12:50:01 for a window starting 12:50:00,
    /// 99 % at 13:20:07 for 13:20:00, 25 % six minutes after. The running maximum keeps it for the
    /// whole new window.
    func testAnOldWindowsLastReadingStampedJustAfterTheNewWindowsStartDoesNotInflateItsPercent() throws {
        let (request, windowStart) = try liveSession(percent: 4)
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: windowStart.addingTimeInterval(1), percent: 43),   // the old window's last value
            (at: windowStart.addingTimeInterval(64), percent: 0),   // the drop, seen a minute later
            (at: windowStart.addingTimeInterval(10 * 60), percent: 2),
            (at: windowStart.addingTimeInterval(25 * 60), percent: 4),
        ])
        let log = TurnCostLog(turns: [
            Fixture.turnCost(at: windowStart.addingTimeInterval(5 * 60), chat: "chat-a", cost: 2),
        ])

        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: log, readings: readings))
        XCTAssertEqual(result.percent, 4, accuracy: 1e-9, "the live bucket says 4 %; the 43 belongs to the window that just ended")
        XCTAssertEqual(
            result.chats.reduce(0) { $0 + $1.points } + result.outside, 4, accuracy: 1e-9
        )
    }

    func testAnOldWindowsReadingsSixMinutesIntoTheNewWindowDoNotInflateItEither() throws {
        let (request, windowStart) = try liveSession(percent: 4)
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: windowStart.addingTimeInterval(6 * 60), percent: 25),  // still the old value
            (at: windowStart.addingTimeInterval(23 * 60), percent: 3),  // the drop, held from here on
            (at: windowStart.addingTimeInterval(27 * 60), percent: 4),
        ])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: TurnCostLog(), readings: readings))
        XCTAssertEqual(result.percent, 4, accuracy: 1e-9)
        XCTAssertEqual(result.outside, 4, accuracy: 1e-9)
    }

    /// The same root, mid-week: on 2026-09-15 this Mac's history has the weekly bucket falling from
    /// 94 to 66 with its `resets_at` unchanged (a limit restore), and staying there.
    func testAHeldDropInsideTheCurrentWeekLeavesTheWindowsPercentWhereTheLiveBucketIs() throws {
        let weekly = Fixture.bucket(
            id: "seven_day", percent: 70, resetsAt: start.addingTimeInterval(2 * day), kind: .weekly
        )
        let claude = Fixture.snapshot(id: "claude", buckets: [weekly])
        let request = try XCTUnwrap(LimitShareRules.request(
            for: claude, kind: .weekly, weeklyBudgetUSD: 0, now: start, calendar: utc
        ))
        let weekStart = request.period.start
        let readings = Fixture.readings(bucketID: "seven_day", points: [
            (at: weekStart.addingTimeInterval(1 * day), percent: 50),
            (at: weekStart.addingTimeInterval(2 * day), percent: 94),
            (at: weekStart.addingTimeInterval(3 * day), percent: 66),
            (at: weekStart.addingTimeInterval(4 * day), percent: 66),
            (at: weekStart.addingTimeInterval(4.5 * day), percent: 69),
        ])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: TurnCostLog(), readings: readings))
        XCTAssertEqual(result.percent, 70, accuracy: 1e-9, "the window's percent now is the live bucket's 70 %, not the 94 it held before the restore")
    }

    func testALoneDipInsideTheCurrentWindowIsStillNoise() throws {
        // The counterpart: a drop that does NOT hold (the next reading is back up) is API noise and
        // the running maximum keeps absorbing it.
        let (request, windowStart) = try liveSession(percent: 22)
        let readings = Fixture.readings(bucketID: "five_hour", points: [
            (at: windowStart.addingTimeInterval(5 * 60), percent: 20),
            (at: windowStart.addingTimeInterval(6 * 60), percent: 0),
            (at: windowStart.addingTimeInterval(7 * 60), percent: 21),
        ])
        let result = try XCTUnwrap(LimitShareRules.share(for: request, log: TurnCostLog(), readings: readings))
        XCTAssertEqual(result.percent, 22, accuracy: 1e-9)
    }

    // MARK: - Seeded sweep of the invariants

    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func pick<T>(_ options: [T]) -> T { options[int(options.count)] }
    }

    func testChatsPlusOutsideAreTheWindowsPercentInEveryRandomScenario() {
        var g = Generator(state: 20_261_016)
        for scenario in 0..<400 {
            let lengthMinutes = g.pick([30, 45, 90, 180, 300, 301, 600])
            let durationSeconds = Double(lengthMinutes) * 60 + Double(g.pick([0, 0, 17, 1_799]))
            let win = LimitWindow(start: start, end: start.addingTimeInterval(durationSeconds))
            let binCount = max(1, Int((durationSeconds / 1_800).rounded(.up)))
            let whole = g.int(2) == 0

            // Readings: strictly increasing times, a random walk with dips.
            var readings: [(Date, Double)] = []
            var t = -600
            var percent = 0.0
            while true {
                t += g.pick([60, 900, 1_800, 1_800, 2_400, 3_600])
                if Double(t) > durationSeconds + 900 { break }
                switch g.int(10) {
                case 0, 1: percent = max(0, percent - Double(g.int(3) + 1))
                case 2: break
                default: percent += Double(g.int(5))
                }
                if !whole { percent = (percent * 10).rounded() / 10 + Double(g.int(10)) / 10 }
                percent = min(percent, 100)
                readings.append((start.addingTimeInterval(Double(t)), percent))
            }

            // Turns: positive dollars, some on exact bin edges, some outside the window.
            var turns: [TurnCost] = []
            for _ in 0..<g.int(26) {
                let offset: Double = g.int(3) == 0
                    ? Double(g.int(binCount + 2) - 1) * 1_800
                    : Double(g.int(Int(durationSeconds) + 600) - 300)
                turns.append(Fixture.turnCost(
                    at: start.addingTimeInterval(offset),
                    chat: "chat-\(g.int(5))",
                    project: "proj-\(g.int(3))",
                    cost: g.pick([0.25, 1, 3, 10]),
                    tokens: g.pick([100, 5_000]),
                    isMainThread: g.int(10) < 7
                ))
            }
            let label = "scenario \(scenario)"

            let result = LimitShareRules.share(
                window: win, bucketID: "five_hour",
                readings: Fixture.readings(
                    bucketID: "five_hour", points: readings.map { (at: $0.0, percent: $0.1) }
                ),
                log: TurnCostLog(turns: turns)
            )

            // The reference: running maximum over (start, end], each reading closing the bin it ends.
            let inside = readings.filter { $0.0 > win.start && $0.0 <= win.end }.sorted { $0.0 < $1.0 }
            var high = 0.0
            var lastInBin: [Int: Double] = [:]
            for (time, p) in inside {
                high = max(high, min(100, p))
                let index = min(max(Int((time.timeIntervalSince(start) / 1_800).rounded(.up)) - 1, 0), binCount - 1)
                lastInBin[index] = high
            }
            var expectedDeltas = [Double](repeating: 0, count: binCount)
            var before = 0.0
            for i in 0..<binCount {
                if let v = lastInBin[i] { expectedDeltas[i] = v - before; before = v }
            }
            let owned = turns.filter { $0.timestamp >= win.start && $0.timestamp < win.end }
            var binTurns = [[String: Double]](repeating: [:], count: binCount)
            for turn in owned {
                let i = min(max(Int((turn.timestamp.timeIntervalSince(start) / 1_800).rounded(.down)), 0), binCount - 1)
                binTurns[i][turn.chatID, default: 0] += turn.cost
            }
            var expectedPoints: [String: Double] = [:]
            var expectedOutside = 0.0
            for i in 0..<binCount where expectedDeltas[i] > 0 {
                let source: [String: Double]? = !binTurns[i].isEmpty ? binTurns[i]
                    : (i > 0 && !binTurns[i - 1].isEmpty ? binTurns[i - 1] : nil)
                if let source {
                    let total = source.values.reduce(0, +)
                    for (chat, cost) in source { expectedPoints[chat, default: 0] += expectedDeltas[i] * cost / total }
                } else {
                    expectedOutside += expectedDeltas[i]
                }
            }

            XCTAssertEqual(result.bins.count, binCount, label)
            XCTAssertEqual(result.bins.map(\.delta), expectedDeltas, accuracy: 1e-9, label)
            XCTAssertEqual(result.percent, high, accuracy: 1e-9, label)
            XCTAssertEqual(result.outside, expectedOutside, accuracy: 1e-9, label)
            XCTAssertEqual(result.chats.reduce(0) { $0 + $1.points } + result.outside, result.percent, accuracy: 1e-9, label)
            XCTAssertEqual(result.bins.map(\.delta).reduce(0, +), result.percent, accuracy: 1e-9, label)
            XCTAssertEqual(result.attributedPoints, result.percent - result.outside, accuracy: 1e-9, label)
            XCTAssertEqual(Set(result.chats.map(\.id)), Set(owned.map(\.chatID)), label)
            for chat in result.chats {
                XCTAssertEqual(chat.points, expectedPoints[chat.id] ?? 0, accuracy: 1e-9, "\(label) \(chat.id)")
                XCTAssertGreaterThanOrEqual(chat.points, 0, label)
            }
            for (i, bin) in result.bins.enumerated() {
                XCTAssertEqual(bin.chats.values.reduce(0, +) + bin.outside, bin.delta, accuracy: 1e-9, "\(label) bin \(i)")
                let allowed = Set(binTurns[i].keys.isEmpty ? (i > 0 ? Array(binTurns[i - 1].keys) : []) : Array(binTurns[i].keys))
                XCTAssertTrue(Set(bin.chats.keys).isSubset(of: allowed), "\(label) bin \(i): a point reached a chat the lag rule does not allow")
            }
            // Projects are the sum of their chats.
            XCTAssertEqual(result.projects.reduce(0) { $0 + $1.points }, result.chats.reduce(0) { $0 + $1.points }, accuracy: 1e-9, label)
            XCTAssertEqual(result.projects.reduce(0) { $0 + $1.cost }, result.cost, accuracy: 1e-9, label)
            XCTAssertEqual(result.projects.reduce(0) { $0 + $1.chats }, result.chats.count, label)
            // Ranking.
            for pair in zip(result.chats, result.chats.dropFirst()) {
                let ordered = pair.0.points > pair.1.points
                    || (pair.0.points == pair.1.points && (pair.0.cost > pair.1.cost
                        || (pair.0.cost == pair.1.cost && pair.0.id < pair.1.id)))
                XCTAssertTrue(ordered, "\(label): \(pair.0.id) before \(pair.1.id)")
            }
            // Cost and price.
            XCTAssertEqual(result.cost, owned.reduce(0) { $0 + $1.cost }, accuracy: 1e-9, label)
            if result.attributedPoints >= 1 + 1e-9 {
                XCTAssertEqual(result.price?.dollars ?? -1, result.cost / result.attributedPoints, accuracy: 1e-9, label)
            } else if result.attributedPoints < 1 - 1e-9 {
                XCTAssertNil(result.price, label)
            }
            if whole {
                XCTAssertEqual(result.outside, result.outside.rounded(), accuracy: 1e-9, "\(label): whole percents give whole Outside")
            }
        }
    }

    func testTheSpendModesTotalsAddUpInEveryRandomScenario() throws {
        var g = Generator(state: 7_777)
        for scenario in 0..<200 {
            let limit = g.pick([100.0, 500.0, 2_000.0])
            let used = Double(g.int(Int(limit) * 2))
            let monthStart = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC
            let now = monthStart.addingTimeInterval(Double(g.int(29 * 86_400)) + 1_800)
            var turns: [TurnCost] = []
            for _ in 0..<g.int(20) {
                turns.append(Fixture.turnCost(
                    at: monthStart.addingTimeInterval(Double(g.int(Int(now.timeIntervalSince(monthStart))) )),
                    chat: "chat-\(g.int(4))", cost: g.pick([1.0, 5.0, 40.0])
                ))
            }
            let folded = g.pick([0.0, 0.0, 12.0, 75.0])
            // Day 0's row also carries the dollars folded out of the turns.
            var rows = [CLIDailySummary(
                day: monthStart,
                totalCost: folded + turns.filter { utc.isDate($0.timestamp, inSameDayAs: monthStart) }.reduce(0) { $0 + $1.cost },
                totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:]
            )]
            // The other days' rows carry exactly their turns.
            for d in 1..<30 {
                let dayStart = monthStart.addingTimeInterval(Double(d) * 86_400)
                let cost = turns.filter { utc.isDate($0.timestamp, inSameDayAs: dayStart) }.reduce(0) { $0 + $1.cost }
                rows.append(CLIDailySummary(day: dayStart, totalCost: cost, totalTokens: 0, tokens: .zero, turns: 1, byFamily: [:]))
            }
            let request = LimitShareRequest(
                mode: .spendLimit(monthlyLimit: limit, usedCredits: used),
                period: LimitWindow(start: monthStart, end: now), bucketID: nil, livePercent: nil
            )
            let result = try XCTUnwrap(
                LimitShareRules.share(for: request, log: TurnCostLog(turns: turns), readings: [], dailySpend: rows),
                "scenario \(scenario)"
            )
            let earlier = result.earlier?.points ?? 0
            let label = "scenario \(scenario)"
            XCTAssertEqual(result.chats.reduce(0) { $0 + $1.points } + result.outside + earlier, result.percent, accuracy: 1e-9, label)
            XCTAssertEqual(result.bins.map(\.delta).reduce(0, +) + result.unbinnedOutside + earlier, result.percent, accuracy: 1e-9, label)
            XCTAssertEqual(result.outside, result.unbinnedOutside, label)
            let local = turns.reduce(0) { $0 + $1.cost } + folded
            XCTAssertEqual(result.percent, max(used, local) / limit * 100, accuracy: 1e-6, "\(label): the server's figure, or this Mac's when it is ahead")
            XCTAssertGreaterThanOrEqual(result.outside, 0, label)
            XCTAssertNil(result.price, label)
        }
    }
}

private func XCTAssertEqual(
    _ lhs: [Double], _ rhs: [Double], accuracy: Double, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    guard lhs.count == rhs.count else {
        return XCTFail("\(message): \(lhs.count) elements, expected \(rhs.count)", file: file, line: line)
    }
    for (index, pair) in zip(lhs, rhs).enumerated() {
        XCTAssertEqual(pair.0, pair.1, accuracy: accuracy, "\(message) [\(index)]", file: file, line: line)
    }
}
