import XCTest
@testable import Omelette

/// Cloud session credits spec § Design: a credit pool never drives the menu bar, the
/// hero, the tiles, a threshold alert, the widget, the rings, the floating window, the
/// Settings summary, the quota analytics or the burn-rate bucket, and the "only when
/// they are all the account has" fallbacks keep their shape. One service is built per
/// case from the same buckets the live payload produces.
final class CloudCreditsRankingVerificationTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 7, kind: .session)
    private let weekly = Fixture.bucket(id: "seven_day", label: "All models", percent: 69, kind: .weekly)
    private let opus = Fixture.bucket(id: "seven_day_opus", label: "Opus only", percent: 30, kind: .modelSpecific)
    private let promoHot = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 99, kind: .other)
    private let promoCool = Fixture.bucket(id: "seven_day_promotional", label: "Promo pool", percent: 50, kind: .other)
    private var credit: UsageBucket { Fixture.cloudCredits }

    private func service(_ buckets: [UsageBucket], extra: ExtraUsage? = nil, weekCost: Double? = nil) -> ServiceSnapshot {
        Fixture.snapshot(buckets: buckets, extraUsage: extra, weekCost: weekCost)
    }

    private let spendLimit = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.4, utilization: 24.8)

    // MARK: - headline (menu bar)

    func testTheMenuBarHeadlineIgnoresACreditPoolHotterThanThePlan() {
        XCTAssertEqual(service([session, weekly, credit]).headlinePercent, 69, accuracy: 1e-9)
        XCTAssertEqual(service([weekly, credit]).headlinePercent, 69, accuracy: 1e-9)
        XCTAssertEqual(service([credit, weekly]).headlinePercent, 69, accuracy: 1e-9, "order must not matter")
    }

    func testTheHeadlineStillTakesTheWorstCoreWindowAndNotJustTheSession() {
        XCTAssertEqual(service([Fixture.bucket(id: "five_hour", percent: 95, kind: .session), weekly, credit]).headlinePercent, 95, accuracy: 1e-9)
    }

    func testAnEnabledSpendLimitStillCompetesAgainstTheCreditPoolsAbsence() {
        let limit = ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 45, utilization: 90)
        XCTAssertEqual(service([weekly, credit], extra: limit).headlinePercent, 90, accuracy: 1e-9)
    }

    func testCreditPoolAloneIsTheHeadlineAsALastResort() {
        // The fallbacks "keep their shape": a pool is shown when it is all the account has.
        XCTAssertEqual(service([credit]).headlinePercent, 92.368272, accuracy: 1e-9)
    }

    func testModelSpecificBeatsACreditPoolWhenThereIsNoCoreWindow() {
        XCTAssertEqual(service([opus, credit]).headlinePercent, 30, accuracy: 1e-9)
    }

    func testCreditBesidePromoFallsBackToTheFullestOfTheTwo() {
        XCTAssertEqual(service([credit, promoCool]).headlinePercent, 92.368272, accuracy: 1e-9)
        XCTAssertEqual(service([credit, promoHot]).headlinePercent, 99, accuracy: 1e-9)
    }

    func testAPromoPoolStillNeverBeatsARealWindow() {
        XCTAssertEqual(service([weekly, credit, promoHot]).headlinePercent, 69, accuracy: 1e-9)
    }

    func testTheMenuBarTextSaysThePlansNumber() {
        let text = MenuBarLabel.text(for: service([session, weekly, credit]))
        XCTAssertEqual(text, "Claude usage 69%")
    }

    // MARK: - hero, tile, secondary

    func testHeroAndTileLeadWithThePlansWindowsNotThePool() {
        let s = service([session, weekly, credit])
        XCTAssertEqual(WindowRanking.heroBucket(for: s)?.id, "seven_day")
        XCTAssertEqual(WindowRanking.detailHero(for: s)?.id, "five_hour")
        XCTAssertEqual(WindowRanking.tileHero(for: s)?.id, "five_hour")
        XCTAssertEqual(WindowRanking.secondaryBucket(for: s)?.id, "seven_day")
    }

    func testTheSecondaryBucketIsNeverTheCreditPool() {
        // Session as hero, no "seven_day": the next-worst core window must not be the pool.
        let monthly = Fixture.bucket(id: "monthly", label: "Monthly", percent: 40, kind: .other)
        let s = service([session, credit, monthly])
        XCTAssertEqual(WindowRanking.secondaryBucket(for: s)?.id, "monthly")
        // Only a session and the pool: nothing to show under the hero.
        XCTAssertNil(WindowRanking.secondaryBucket(for: service([session, credit])))
    }

    func testWeeklyOnlyAccountHeroIsTheWeeklyAndHasNoSecondary() {
        let s = service([weekly, credit])
        XCTAssertEqual(WindowRanking.tileHero(for: s)?.id, "seven_day")
        XCTAssertNil(WindowRanking.secondaryBucket(for: s))
    }

    func testAHeroOverASpendLimitIsNotTheCreditPoolEither() {
        let s = service([credit], extra: spendLimit)
        XCTAssertEqual(WindowRanking.heroBucket(for: s)?.id, WindowRanking.extraUsageBucketID(for: s))
    }

    func testCreditPoolAloneIsTheHeroAsALastResort() {
        XCTAssertEqual(WindowRanking.heroBucket(for: service([credit]))?.id, "iguana_necktie")
        XCTAssertEqual(WindowRanking.tileHero(for: service([credit]))?.id, "iguana_necktie")
    }

    func testBesideAPromoPoolTheFallbackPicksTheFullestAndHeadlineAndHeroAgree() {
        for promo in [promoCool, promoHot] {
            let s = service([credit, promo])
            let hero = WindowRanking.heroBucket(for: s)
            XCTAssertEqual(s.headlinePercent, hero?.clampedPercent ?? -1, accuracy: 1e-9, "the menu bar and the hero must read the same window")
        }
        XCTAssertEqual(WindowRanking.heroBucket(for: service([credit, promoCool]))?.id, "iguana_necktie")
        XCTAssertEqual(WindowRanking.heroBucket(for: service([credit, promoHot]))?.id, "seven_day_promotional")
    }

    func testSessionRowsAndPopoverRowsNeverIncludeTheCreditPool() {
        let s = service([session, weekly, opus, credit])
        XCTAssertFalse(WindowRanking.sessionRows(for: s, hero: nil).contains { $0.isCreditPool })
        // The Claude tab's weekly group takes only .weekly and .modelSpecific; the pool is .other.
        XCTAssertEqual(PopoverView.creditPools(s).map(\.id), ["iguana_necktie"])
    }

    // MARK: - threshold alerts

    func testNoThresholdAlertIsWatchedForACreditPool() {
        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service([session, weekly, credit])).map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service([credit])).map(\.id), [])
        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service([opus, credit])).map(\.id), ["seven_day_opus"])
        XCTAssertEqual(UsageNotifier.watchableBuckets(for: service([credit, promoHot])).map(\.id), [])
    }

    func testASpendLimitIsStillWatchedBesideACreditPool() {
        let ids = UsageNotifier.watchableBuckets(for: service([credit], extra: spendLimit)).map(\.id)
        XCTAssertEqual(ids.count, 1)
        XCTAssertFalse(ids.contains("iguana_necktie"))
    }

    // MARK: - widget

    func testTheWidgetCarriesNoRowForACreditPool() {
        let widget = WidgetBridge.widgetServices(from: [service([session, weekly, credit])])
        XCTAssertEqual(widget.first?.buckets.map(\.id), ["five_hour", "seven_day"])
    }

    func testAnAccountWhoseOnlyReadingIsACreditPoolHasNoWidgetRowAndKeepsItsSpendLine() {
        XCTAssertTrue(WidgetBridge.widgetServices(from: [service([credit])]).isEmpty, "no windows, no dollars: nothing for the widget")
        let withSpend = WidgetBridge.widgetServices(from: [service([credit], weekCost: 12)])
        XCTAssertEqual(withSpend.first?.buckets.count, 0)
        XCTAssertEqual(withSpend.first?.spendLabel, "$12.00 last 7 days")
    }

    func testTheWidgetKeepsPromoPoolsAsBefore() {
        let widget = WidgetBridge.widgetServices(from: [service([weekly, promoHot, credit])])
        XCTAssertEqual(widget.first?.buckets.map(\.id), ["seven_day", "seven_day_promotional"])
    }

    // MARK: - dashboard Overview rings

    func testTheRingsAndLegendNeverListACreditPool() {
        let s = service([session, weekly, opus, credit])
        let windows = OverviewRingsRules.windows(for: s)
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertTrue(windows.allSatisfy { !$0.bucket.isCreditPool })
        XCTAssertEqual(windows.map { $0.series != nil }, [true, true, true])
    }

    func testAFourthPlanWindowIsALegendRowAndStillNoPool() {
        let sonnet = Fixture.bucket(id: "seven_day_sonnet", label: "Sonnet only", percent: 10, kind: .modelSpecific)
        let windows = OverviewRingsRules.windows(for: service([session, weekly, opus, sonnet, credit]))
        XCTAssertEqual(windows.count, 4)
        XCTAssertNil(windows[3].series)
        XCTAssertFalse(windows.contains { $0.bucket.isCreditPool })
    }

    func testAPoolThatWouldBeTheHeroIsStillNotARing() {
        // detailHero's last resort is the pool when it is all there is, or the fullest of pool+promo.
        XCTAssertEqual(OverviewRingsRules.windows(for: service([credit])).map(\.id), [])
        XCTAssertEqual(OverviewRingsRules.windows(for: service([credit, promoCool])).map(\.id), ["seven_day_promotional"])
        XCTAssertEqual(OverviewRingsRules.windows(for: service([credit, promoHot])).map(\.id), ["seven_day_promotional"])
    }

    func testPromoPoolsStillSitLastInTheRings() {
        let ids = OverviewRingsRules.windows(for: service([promoHot, weekly, credit])).map(\.id)
        XCTAssertEqual(ids, ["seven_day", "seven_day_promotional"])
    }

    // MARK: - floating window

    func testTheFloatingWindowTakesNoRowForACreditPool() {
        let content = FloatingMiniLayout.content(for: service([session, weekly, credit]))
        XCTAssertEqual(content.hero?.id, "five_hour")
        XCTAssertEqual(content.rows.map(\.id), ["seven_day"])
        let weeklyOnly = FloatingMiniLayout.content(for: service([weekly, credit]))
        XCTAssertEqual(weeklyOnly.hero?.id, "seven_day")
        XCTAssertEqual(weeklyOnly.rows.map(\.id), [])
    }

    // MARK: - Settings summary

    func testTheSettingsSummaryNamesThePlansWindowsOnly() {
        let text = SettingsView.usageSummary(service([session, weekly, credit]), mode: .used)
        XCTAssertEqual(text, "Week 69% · Session 7%", "worst first")
        XCTAssertFalse(text.contains("Cloud"))
        XCTAssertEqual(SettingsView.usageSummary(service([weekly, credit]), mode: .remaining), "Week 31%")
    }

    func testTheSettingsSummaryOfAPoolOnlyAccountDoesNotQuoteThePool() {
        XCTAssertEqual(SettingsView.usageSummary(service([credit]), mode: .used), "—")
        XCTAssertEqual(SettingsView.usageSummary(service([credit], weekCost: 4), mode: .used), "$4.00 this week")
    }

    // MARK: - quota analytics and burn bucket

    func testTheCoreBucketsNeverIncludeTheCreditPool() {
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: [session, weekly, credit]).map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: [opus, credit]).map(\.id), ["seven_day_opus"])
    }

    func testTheCoreBucketsLastFallbackNeverReturnsTheCreditPool() {
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: [credit]).map(\.id), [])
        // A promo pool still stands in when it is all there is besides the pool.
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: [credit, promoHot]).map(\.id), ["seven_day_promotional"])
        XCTAssertEqual(QuotaAnalytics.coreBuckets(of: [promoHot]).map(\.id), ["seven_day_promotional"], "promo-only keeps its old fallback")
    }

    func testTheQuotaBucketInfosMarkThePoolNonCoreButLive() {
        let infos = QuotaAnalytics.bucketInfos(service: service([session, weekly, credit]), records: [])
        let pool = infos.first { $0.id == "iguana_necktie" }
        XCTAssertEqual(pool?.isCore, false)
        XCTAssertEqual(pool?.isLive, true)
        XCTAssertEqual(pool?.label, "Cloud session credits")
        XCTAssertEqual(infos.filter(\.isCore).map(\.id), ["five_hour", "seven_day"])
    }

    func testTheBurnRateBucketIsThePlansWindow() {
        XCTAssertEqual(DashboardState.burnBucket(of: service([session, weekly, credit]))?.id, "five_hour")
        XCTAssertEqual(DashboardState.burnBucket(of: service([weekly, credit]))?.id, "seven_day")
        XCTAssertEqual(DashboardState.burnBucket(of: service([opus, credit]))?.id, "seven_day_opus")
        XCTAssertNil(DashboardState.burnBucket(of: service([credit])), "a pool is not a limit to pace against")
    }

    // MARK: - Popover spend card

    func testTheSpendCardIsShownForAPoolEvenWithoutAnyOtherDollars() {
        XCTAssertTrue(PopoverView.showsSpendGroup(service: service([session, weekly, credit]), hasHero: true))
        XCTAssertFalse(PopoverView.showsSpendGroup(service: service([session, weekly]), hasHero: true))
    }

    func testAnAccountWhoseOnlyReadingIsACreditPoolHasSomethingToShow() {
        XCTAssertFalse(PopoverView.nothingToShow(service([credit])))
        XCTAssertTrue(PopoverView.nothingToShow(service([])))
        XCTAssertFalse(PopoverView.nothingToShow(service([], weekCost: 3)))
        XCTAssertFalse(PopoverView.nothingToShow(service([], extra: spendLimit)))
    }

    func testEveryCreditPoolGetsItsOwnRowInTheProvidersOrder() {
        let second = Fixture.bucket(
            id: "walrus", label: "Included credits", percent: 10, kind: .other,
            credit: CreditPool(usedDollars: 10, limitDollars: 100)
        )
        XCTAssertEqual(PopoverView.creditPools(service([session, credit, weekly, second])).map(\.id), ["iguana_necktie", "walrus"])
        XCTAssertEqual(PopoverView.creditPools(service([session, weekly])).count, 0)
    }

    // MARK: - Row text

    private let enUS = Locale(identifier: "en_US")

    func testTheRowValueRoundsToWholeDollars() {
        XCTAssertEqual(PopoverView.creditRowValue(credit, locale: enUS), "$231 / $250")
    }

    func testTheRowValueForOtherLimits() {
        func value(_ used: Double, _ limit: Double) -> String? {
            PopoverView.creditRowValue(
                Fixture.bucket(id: "p", credit: CreditPool(usedDollars: used, limitDollars: limit)), locale: enUS
            )
        }
        XCTAssertEqual(value(0, 1000), "$0 / $1,000")
        XCTAssertEqual(value(999.4, 1000), "$999 / $1,000")
        XCTAssertEqual(value(1000, 1000), "$1,000 / $1,000")
        XCTAssertEqual(value(0.2, 250), "$0 / $250")
        XCTAssertEqual(value(1234.567, 5000), "$1,235 / $5,000")
        // Over the limit is not clamped: the file records what is true.
        XCTAssertEqual(value(260.4, 250), "$260 / $250")
    }

    func testTheRowValueIsNilForAWindowThatIsNotAPool() {
        XCTAssertNil(PopoverView.creditRowValue(weekly, locale: enUS))
        XCTAssertNil(PopoverView.creditRowHelp(weekly))
    }

    func testTheRowValueKeepsTheDollarSignForTheUSDollar() {
        // In a non-US locale the currency code spells itself out; the amounts must still be whole.
        let value = PopoverView.creditRowValue(credit, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(value, "US$231 / US$250")
        let german = PopoverView.creditRowValue(credit, locale: Locale(identifier: "de_DE"))
        XCTAssertNotNil(german)
        XCTAssertTrue(german?.contains("231") == true && german?.contains("250") == true, german ?? "")
        XCTAssertFalse(german?.contains(",") == true, "no fraction digits: \(german ?? "")")
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }

    func testTheRowHelpSaysWhenTheCreditExpires() {
        let now = Date(timeIntervalSince1970: 1_791_115_200) // 2026-10-04 12:00 UTC
        XCTAssertEqual(
            PopoverView.creditRowHelp(credit, now: now, calendar: utcCalendar, locale: Locale(identifier: "en_GB")),
            "Expires 5 Nov, 7:59"
        )
    }

    func testTheRowHelpWithinAWeekUsesTheWeekdayAndTheSameDayUsesJustTheTime() {
        let now = Date(timeIntervalSince1970: 1_791_115_200)
        let soon = Fixture.bucket(
            id: "p", resetsAt: now.addingTimeInterval(2 * 86_400),
            credit: CreditPool(usedDollars: 1, limitDollars: 2)
        )
        XCTAssertEqual(
            PopoverView.creditRowHelp(soon, now: now, calendar: utcCalendar, locale: Locale(identifier: "en_GB")),
            "Expires Tue 12:00"
        )
        let today = Fixture.bucket(
            id: "p", resetsAt: now.addingTimeInterval(3600),
            credit: CreditPool(usedDollars: 1, limitDollars: 2)
        )
        XCTAssertEqual(
            PopoverView.creditRowHelp(today, now: now, calendar: utcCalendar, locale: Locale(identifier: "en_GB")),
            "Expires 13:00"
        )
    }

    func testTheRowHelpIsNilWhenTheProviderGaveNoDate() {
        let pool = Fixture.bucket(
            id: "p", resetsAt: .distantFuture, credit: CreditPool(usedDollars: 1, limitDollars: 2)
        )
        XCTAssertNil(PopoverView.creditRowHelp(pool, now: Date(timeIntervalSince1970: 1_791_115_200), calendar: utcCalendar, locale: Locale(identifier: "en_GB")))
    }
}
