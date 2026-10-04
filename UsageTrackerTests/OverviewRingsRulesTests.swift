import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Overview rings", and § Screens, "Overview": one
/// concentric ring per window (three at most), the provider tab's hero outermost, a legend
/// row per window with its reset and figure, and "On track" as coloured text. Values from
/// `Dashboard-Overview(-Light).dc.html`.
final class OverviewRingsRulesTests: XCTestCase {
    private var calendar: Calendar { SessionFixture.calendar }
    private let gb = SessionFixture.locale
    private let us = Locale(identifier: "en_US")
    /// Sunday 2026-09-06 11:20 UTC.
    private var now: Date { SessionFixture.now }

    /// The mockup's Claude: session 53 % resetting in 15 minutes, all models 41 % and
    /// Fable only 47 % resetting Thursday 12:59.
    private func claude(state: ServiceState = .ok, extra: [UsageBucket] = []) -> ServiceSnapshot {
        let thursday = now.addingTimeInterval(4 * 86_400 + 99 * 60)
        return Fixture.snapshot(
            id: "claude", plan: "Claude Max 20x",
            buckets: [
                Fixture.bucket(id: "five_hour", label: "Current session", percent: 53,
                               resetsAt: now.addingTimeInterval(15 * 60), kind: .session),
                Fixture.bucket(id: "seven_day", label: "All models", percent: 41,
                               resetsAt: thursday, kind: .weekly),
                Fixture.bucket(id: "seven_day_fable", label: "Fable only", percent: 47,
                               resetsAt: thursday, kind: .modelSpecific),
            ] + extra,
            state: state, at: now
        )
    }

    // MARK: - Windows

    func testTheMockupsThreeWindowsNestSessionAllModelsFable() {
        let windows = OverviewRingsRules.windows(for: claude())
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(windows.map(\.series), [.seriesSession, .seriesAllModels, .seriesPerModel])
    }

    func testAFourthWindowGetsALegendRowButNoRing() {
        let windows = OverviewRingsRules.windows(for: claude(extra: [
            Fixture.bucket(id: "iguana_necktie", label: "Iguana Necktie", percent: 12, kind: .other)
        ]))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable", "iguana_necktie"])
        XCTAssertNil(windows[3].series)
    }

    func testACloudSessionCreditPoolIsNeitherARingNorALegendRow() {
        // Its figure is dollars, and its row is on the provider tab's spend card.
        let windows = OverviewRingsRules.windows(for: claude(extra: [Fixture.cloudCredits]))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
    }

    func testACreditPoolNeverLeadsTheRingsEvenWhenItIsTheFullestBonusPool() {
        // detailHero falls back to the fullest bonus pool when that is all there is.
        // Alone, the pool gets no ring at all.
        let alone = Fixture.snapshot(id: "claude", buckets: [Fixture.cloudCredits], at: now)
        XCTAssertTrue(OverviewRingsRules.windows(for: alone).isEmpty)
        // Beside a calmer promo pool, the promo pool leads and the credit pool is not listed.
        let promo = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 40, kind: .weekly)
        let withPromo = Fixture.snapshot(id: "claude", buckets: [Fixture.cloudCredits, promo], at: now)
        XCTAssertEqual(OverviewRingsRules.windows(for: withPromo).map(\.id), ["seven_day_promotional"])
    }

    func testTheProviderTabsHeroIsTheOutermostRing() {
        // Antigravity lists its weekly pool before its session window.
        let service = Fixture.snapshot(id: "antigravity", plan: nil, buckets: [
            Fixture.bucket(id: "antigravity_gemini", label: "Gemini models", percent: 20, kind: .weekly),
            Fixture.bucket(id: "antigravity_claude_gpt", label: "Claude & GPT models", percent: 60, kind: .session),
        ], at: now)
        XCTAssertEqual(OverviewRingsRules.windows(for: service).map(\.id),
                       ["antigravity_claude_gpt", "antigravity_gemini"])
    }

    func testPromotionalPoolsNestInsideTheLimitsThatBind() {
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 10, kind: .session),
            Fixture.bucket(id: "seven_day_promo", label: "Bonus week", percent: 90, kind: .weekly),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 30, kind: .weekly),
        ], at: now)
        XCTAssertEqual(OverviewRingsRules.windows(for: service).map(\.id),
                       ["five_hour", "seven_day", "seven_day_promo"])
    }

    func testAProviderWithNoWindowHasNoRings() {
        XCTAssertTrue(OverviewRingsRules.windows(for: Fixture.snapshot(buckets: [], at: now)).isEmpty)
    }

    func testASpendLimitWithNoSessionIsTheOnlyRingAndSaysHowMuchIsSpent() {
        let service = Fixture.snapshot(
            plan: "Claude Enterprise", buckets: [],
            extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 1_500, usedCredits: 431.26, utilization: 28.75),
            at: now
        )
        let windows = OverviewRingsRules.windows(for: service)
        XCTAssertEqual(windows.map(\.id), ["claude_extra_usage"])
        XCTAssertEqual(
            OverviewRingsRules.subline(for: windows[0].bucket, service: service, now: now,
                                       calendar: calendar, locale: us),
            "$431.26 of $1,500"
        )
    }

    // MARK: - Legend rows

    func testALegendRowCountsDownWithinTheHourAndNamesTheDayBeyondIt() {
        let service = claude()
        let windows = OverviewRingsRules.windows(for: service)
        XCTAssertEqual(OverviewRingsRules.subline(for: windows[0].bucket, service: service, now: now,
                                                  calendar: calendar, locale: gb), "resets in 15m")
        XCTAssertEqual(OverviewRingsRules.subline(for: windows[1].bucket, service: service, now: now,
                                                  calendar: calendar, locale: gb), "resets Thu 12:59")
    }

    func testLaterTodayIsTheClockTime() {
        let bucket = Fixture.bucket(id: "five_hour", label: "Current session", percent: 5,
                                    resetsAt: now.addingTimeInterval(100 * 60), kind: .session)
        let service = Fixture.snapshot(buckets: [bucket], at: now)
        XCTAssertEqual(OverviewRingsRules.subline(for: bucket, service: service, now: now,
                                                  calendar: calendar, locale: gb), "resets 13:00")
    }

    func testAPassedResetSaysNowOnlyWhileTheProviderIsAnswering() {
        let bucket = Fixture.bucket(id: "five_hour", label: "Current session", percent: 5,
                                    resetsAt: now.addingTimeInterval(-5), kind: .session)
        let live = Fixture.snapshot(buckets: [bucket], state: .ok, at: now)
        let closed = Fixture.snapshot(buckets: [bucket], state: .notRunning, at: now)
        XCTAssertEqual(OverviewRingsRules.subline(for: bucket, service: live, now: now,
                                                  calendar: calendar, locale: gb), "resets now")
        // A closed provider's window may have reset hours ago: "resets now" is the
        // wording the spec removes for a closed Antigravity.
        XCTAssertNil(OverviewRingsRules.subline(for: bucket, service: closed, now: now,
                                                calendar: calendar, locale: gb))
    }

    func testAWindowWithNoResetTimeHasNoSecondLine() {
        let bucket = Fixture.bucket(id: "grok_credits", label: "Credits", percent: 30, kind: .weekly)
        let service = Fixture.snapshot(id: "grok", buckets: [bucket], at: now)
        XCTAssertNil(OverviewRingsRules.subline(for: bucket, service: service, now: now,
                                                calendar: calendar, locale: gb))
    }

    func testVoiceOverReadsTheWindowItsFigureAndItsReset() {
        let session = OverviewRingsRules.windows(for: claude())[0].bucket
        XCTAssertEqual(OverviewRingsRules.accessibilityLabel(for: session, subline: "resets in 15m", mode: .used),
                       "Current session, 53 percent used, resets in 15m")
        XCTAssertEqual(OverviewRingsRules.accessibilityLabel(for: session, subline: nil, mode: .remaining),
                       "Current session, 47 percent left")
    }

    // MARK: - Dollar rows (cloud session credits spec § Design, "Overview legend row")

    /// Sunday 2026-10-04 12:00 UTC, the day the pool read $231 of $250.
    private let october4 = Date(timeIntervalSince1970: 1_791_115_200)

    /// The mockup's Claude with dollars beside its windows: an extra-usage limit and any
    /// credit pools.
    private func claudeWithDollars(
        extraUsage: ExtraUsage?, plan: String = "Claude Max 20x", pools: [UsageBucket] = []
    ) -> ServiceSnapshot {
        Fixture.snapshot(id: "claude", plan: plan, buckets: claude().buckets + pools, extraUsage: extraUsage, at: now)
    }

    private let tenDollarExtra = ExtraUsage(isEnabled: true, monthlyLimit: 10, usedCredits: 0, utilization: 0)

    func testCreditPoolsListsOnlyTheCreditPoolsInProviderOrder() {
        let untouched = Fixture.bucket(
            id: "nimbus_quill", label: "Included credits", percent: 0,
            credit: CreditPool(usedDollars: 0, limitDollars: 50)
        )
        let service = claude(extra: [Fixture.cloudCredits, untouched])
        XCTAssertEqual(service.creditPools.map(\.id), ["iguana_necktie", "nimbus_quill"])
        XCTAssertEqual(PopoverView.creditPools(service), service.creditPools, "the popover reads the same list")
        XCTAssertEqual(claude().creditPools, [])
    }

    func testExtraUsageGetsADollarRowBeforeTheCreditPools() {
        let service = claudeWithDollars(extraUsage: tenDollarExtra, pools: [Fixture.cloudCredits])
        // No locale spells both "$231" and "5 Nov, 7:59": the dollars are pinned in en_US,
        // the expiry in en_GB (ResetCopy.absolute writes its 07:59 as "7:59").
        let inUS = OverviewRingsRules.dollarRows(for: service, now: october4, calendar: calendar, locale: us)
        let inGB = OverviewRingsRules.dollarRows(for: service, now: october4, calendar: calendar, locale: gb)
        XCTAssertEqual(inUS.map(\.id), ["claude_extra_usage", "iguana_necktie"])
        XCTAssertEqual(inUS.map(\.label), ["Extra usage credits", "Cloud session credits"])
        XCTAssertEqual(inUS.map(\.figure), ["$0 / $10", "$231 / $250"])
        XCTAssertEqual(inUS.map(\.token), [.seriesExtraUsage, .seriesCredits])
        XCTAssertEqual(inGB.map(\.subline), [nil, "expires 5 Nov, 7:59"])
    }

    func testDisabledExtraUsageGetsNoDollarRow() {
        let off = ExtraUsage(isEnabled: false, monthlyLimit: 10, usedCredits: 0, utilization: 0)
        let noLimit = ExtraUsage(isEnabled: true, monthlyLimit: 0, usedCredits: 0, utilization: 0)
        for extra in [off, noLimit] {
            let service = claudeWithDollars(extraUsage: extra, pools: [Fixture.cloudCredits])
            XCTAssertEqual(OverviewRingsRules.dollarRows(for: service, now: october4).map(\.id), ["iguana_necktie"])
        }
    }

    func testAnAccountWithoutDollarsHasNoDollarRows() {
        XCTAssertEqual(OverviewRingsRules.dollarRows(for: claude(), now: october4), [])
    }

    func testADollarRowWithoutADateHasNoSubline() {
        let undated = Fixture.bucket(
            id: "nimbus_quill", label: "Included credits", percent: 24, resetsAt: .distantFuture,
            credit: CreditPool(usedDollars: 1200, limitDollars: 5000)
        )
        let rows = OverviewRingsRules.dollarRows(
            for: claudeWithDollars(extraUsage: nil, pools: [undated]), now: october4, calendar: calendar, locale: us
        )
        XCTAssertEqual(rows.map(\.subline), [nil])
        XCTAssertEqual(rows.map(\.accessibilityLabel), ["Included credits, $1,200 / $5,000"])
    }

    func testTheDollarRowsNeverTouchTheRingsOrTheVerdict() {
        let service = claudeWithDollars(extraUsage: tenDollarExtra, pools: [Fixture.cloudCredits])
        XCTAssertEqual(
            OverviewRingsRules.windows(for: service).map(\.id), ["five_hour", "seven_day", "seven_day_fable"]
        )
        XCTAssertEqual(OverviewRingsRules.status(for: service), OverviewRingsRules.status(for: claude()))
    }

    func testVoiceOverReadsADollarRowAsLabelFigureAndExpiry() {
        let service = claudeWithDollars(extraUsage: tenDollarExtra, pools: [Fixture.cloudCredits])
        let inUS = OverviewRingsRules.dollarRows(for: service, now: october4, calendar: calendar, locale: us)
        let inGB = OverviewRingsRules.dollarRows(for: service, now: october4, calendar: calendar, locale: gb)
        XCTAssertEqual(inUS[0].accessibilityLabel, "Extra usage credits, $0 / $10")
        // The spec's line: en_US dollars with en_GB's expiry, which no one locale gives.
        let credits = OverviewDollarRow(
            id: inUS[1].id, label: inUS[1].label, figure: inUS[1].figure, subline: inGB[1].subline, token: inUS[1].token
        )
        XCTAssertEqual(credits.accessibilityLabel, "Cloud session credits, $231 / $250, expires 5 Nov, 7:59")
    }

    func testASpendLimitThatIsAlreadyARingGetsNoDollarRow() {
        // testASpendLimitWithNoSessionIsTheOnlyRingAndSaysHowMuchIsSpent's account: with no
        // session the spend limit is the hero ring, and its legend row already says
        // "$431.26 of $1,500". A dollar row would list it twice.
        let spendLimit = ExtraUsage(isEnabled: true, monthlyLimit: 1_500, usedCredits: 431.26, utilization: 28.75)
        let service = Fixture.snapshot(plan: "Claude Enterprise", buckets: [], extraUsage: spendLimit, at: now)
        XCTAssertEqual(OverviewRingsRules.windows(for: service).map(\.id), ["claude_extra_usage"])
        XCTAssertEqual(OverviewRingsRules.dollarRows(for: service, now: now), [])
        // A credit pool beside it keeps its row: only the ringed limit is skipped.
        let withPool = Fixture.snapshot(
            plan: "Claude Enterprise", buckets: [Fixture.cloudCredits], extraUsage: spendLimit, at: now
        )
        XCTAssertEqual(OverviewRingsRules.windows(for: withPool).map(\.id), ["claude_extra_usage"])
        XCTAssertEqual(OverviewRingsRules.dollarRows(for: withPool, now: now).map(\.id), ["iguana_necktie"])
    }

    func testASpendLimitPlanNamesItsRowSpendLimit() {
        let service = claudeWithDollars(extraUsage: tenDollarExtra, plan: "Claude Enterprise")
        XCTAssertEqual(OverviewRingsRules.dollarRows(for: service, now: october4).map(\.label), ["Spend limit"])
    }

    // MARK: - Centre

    func testAtRestTheCentreIsTheOutermostWindowAsTheMockupWritesIt() {
        let windows = OverviewRingsRules.windows(for: claude())
        XCTAssertEqual(OverviewRingsRules.centre(windows: windows, emphasised: nil, mode: .used),
                       OverviewRingsRules.Centre(percent: "53%", name: "session"))
    }

    func testTheCentreFollowsTheEmphasisedWindow() {
        let windows = OverviewRingsRules.windows(for: claude())
        XCTAssertEqual(OverviewRingsRules.centre(windows: windows, emphasised: 1, mode: .used),
                       OverviewRingsRules.Centre(percent: "41%", name: "all models"))
        XCTAssertEqual(OverviewRingsRules.centre(windows: windows, emphasised: 2, mode: .used),
                       OverviewRingsRules.Centre(percent: "47%", name: "Fable only"))
        // The windows changed under the pointer: back to the outermost.
        XCTAssertEqual(OverviewRingsRules.centre(windows: windows, emphasised: 7, mode: .used)?.name, "session")
    }

    func testTheCentreCountsDownInRemainingMode() {
        let windows = OverviewRingsRules.windows(for: claude())
        XCTAssertEqual(OverviewRingsRules.centre(windows: windows, emphasised: nil, mode: .remaining)?.percent, "47%")
    }

    func testNoWindowsNoCentre() {
        XCTAssertNil(OverviewRingsRules.centre(windows: [], emphasised: nil, mode: .used))
    }

    func testCentreNamesKeepAModelsNameAndLowerTheRest() {
        XCTAssertEqual(OverviewRingsRules.centreName("Current session"), "session")
        XCTAssertEqual(OverviewRingsRules.centreName("All models"), "all models")
        XCTAssertEqual(OverviewRingsRules.centreName("Fable only"), "Fable only")
        XCTAssertEqual(OverviewRingsRules.centreName("Weekly"), "Weekly")
        XCTAssertEqual(OverviewRingsRules.centreName("Claude & GPT models"), "Claude & GPT models")
    }

    // MARK: - Verdict

    func testTheLegendsVerdictIsTheWorstLimitsPhraseInItsTone() {
        XCTAssertEqual(OverviewRingsRules.status(for: claude()), OverviewLine(text: "On track", token: .okText))
    }

    func testAModelScopedWindowDoesNotDriveTheVerdict() {
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 30, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 40, kind: .weekly),
            Fixture.bucket(id: "seven_day_fable", label: "Fable only", percent: 95, kind: .modelSpecific),
        ], at: now)
        XCTAssertEqual(OverviewRingsRules.status(for: service),
                       OverviewLine(text: "Plenty of headroom", token: .okText))
    }

    func testAWeeklyNearItsLimitIsTheVerdictWhateverTheSession() {
        let service = Fixture.snapshot(buckets: [
            Fixture.bucket(id: "five_hour", label: "Current session", percent: 10, kind: .session),
            Fixture.bucket(id: "seven_day", label: "All models", percent: 92, kind: .weekly),
        ], at: now)
        XCTAssertEqual(OverviewRingsRules.status(for: service),
                       OverviewLine(text: "Almost at the limit", token: .critical))
    }

    func testTheLegendVerdictIgnoresACreditPool() {
        // The pool at 92 % would read "Almost at the limit"; it is money, not a limit.
        XCTAssertEqual(
            OverviewRingsRules.status(for: claude(extra: [Fixture.cloudCredits])),
            OverviewRingsRules.status(for: claude())
        )
    }

    func testLastKnownNumbersGetNoVerdict() {
        XCTAssertNil(OverviewRingsRules.status(for: claude(state: .notRunning)))
    }

    // MARK: - Drawing

    func testThePaceDotShowsInsideTheWindowAndNeverOnLastKnownNumbers() {
        XCTAssertTrue(OverviewRingsRules.showsPaceDot(pace: 0.5, retained: false))
        XCTAssertFalse(OverviewRingsRules.showsPaceDot(pace: 0.5, retained: true))
        XCTAssertFalse(OverviewRingsRules.showsPaceDot(pace: nil, retained: false))
        XCTAssertFalse(OverviewRingsRules.showsPaceDot(pace: 0.99, retained: false))
    }

    func testTheRingsAreTheMockups() {
        XCTAssertEqual(OverviewRingsRules.diameter, 232)
        XCTAssertEqual(OverviewRingsRules.lineWidth, 16)
        XCTAssertEqual(OverviewRingsRules.radii, [106, 85, 64])
        XCTAssertEqual(OverviewRingsRules.trackOpacity, 0.16)
        XCTAssertEqual(OverviewRingsRules.paceDotDiameter, 6)
    }
}
