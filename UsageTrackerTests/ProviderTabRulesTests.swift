import XCTest
@testable import Omelette

/// Liquid-glass redesign spec § Screens, "Popover · provider": "weekly limits as bars".
/// `Popover-Claude.dc.html`: one group card (padding 14, gap 14) titled "Weekly limits",
/// rows "All models" and "Fable". Extra usage and the week's dollars get a second card.
final class ProviderTabRulesTests: XCTestCase {
    private let session = Fixture.bucket(id: "five_hour", label: "Current session", percent: 53, kind: .session)

    func testAWeeklyRowDropsOnlyAndKeepsAllModelsWhole() {
        XCTAssertEqual(PopoverCopy.limitRowLabel("Fable only"), "Fable")
        XCTAssertEqual(PopoverCopy.limitRowLabel("All models"), "All models")
        XCTAssertEqual(PopoverCopy.limitRowLabel("Cowork"), "Cowork")
    }

    func testAnUntouchedWindowKeepsItsRowButDims() {
        XCTAssertEqual(PopoverView.limitRowOpacity(Fixture.bucket(id: "seven_day_sonnet", label: "Sonnet only", percent: 0, kind: .modelSpecific)), 0.55)
        XCTAssertEqual(PopoverView.limitRowOpacity(Fixture.bucket(id: "seven_day", label: "All models", percent: 41, kind: .weekly)), 1)
    }

    func testTheSpendGroupShowsTheWeeksDollarsOrAnEnabledSpendLimit() {
        let withWeek = Fixture.snapshot(id: "claude", buckets: [session], weekCost: 41.37)
        let noSpend = Fixture.snapshot(id: "claude", buckets: [session])
        let extra = Fixture.snapshot(id: "claude", buckets: [session],
                                     extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 12.5, utilization: 25))
        let extraOff = Fixture.snapshot(id: "claude", buckets: [session],
                                        extraUsage: ExtraUsage(isEnabled: false, monthlyLimit: 50, usedCredits: 0, utilization: 0))
        XCTAssertTrue(PopoverView.showsSpendGroup(service: withWeek, hasHero: true))
        XCTAssertFalse(PopoverView.showsSpendGroup(service: noSpend, hasHero: true))
        XCTAssertTrue(PopoverView.showsSpendGroup(service: extra, hasHero: true))
        XCTAssertFalse(PopoverView.showsSpendGroup(service: extraOff, hasHero: true))
    }

    func testAWindowlessAccountsWeekLeadsItsSpendGroup() {
        XCTAssertTrue(PopoverView.showsSpendGroup(service: Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 6.41), hasHero: false))
        XCTAssertFalse(PopoverView.showsSpendGroup(service: Fixture.snapshot(id: "grok", displayName: "Grok", weekCost: 0), hasHero: false))
    }

    func testGroupsAreTheMockupsFourteenPointCards() {
        XCTAssertEqual(PopoverView.groupPadding, 14)
        XCTAssertEqual(PopoverView.groupSpacing, 14)
    }

    // MARK: - Credit pools (cloud session credits spec § A row where the dollars live)

    private let us = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")
    private var utcGB: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    /// Sunday 2026-10-04 12:00 UTC, the day the menu bar showed the pool's 92 %.
    private let october4 = Date(timeIntervalSince1970: 1_791_115_200)

    func testACloudSessionCreditRowReadsWholeDollarsUsedOverLimit() {
        // $230.92 of $250 spent; claude.ai shows the same pool as "$19 of $250 left".
        XCTAssertEqual(PopoverView.creditRowValue(Fixture.cloudCredits, locale: us), "$231 / $250")
    }

    func testACreditRowsTooltipSaysWhenTheCreditsExpire() {
        XCTAssertEqual(
            PopoverView.creditRowHelp(Fixture.cloudCredits, now: october4, calendar: utcGB, locale: gb),
            // ResetCopy.absolute's own spelling: Date.FormatStyle's `.shortened` time
            // writes en_GB's 07:59 as "7:59".
            "Expires 5 Nov, 7:59"
        )
        let undated = Fixture.bucket(
            id: "nimbus_quill", label: "Included credits", percent: 24,
            credit: CreditPool(usedDollars: 1200, limitDollars: 5000)
        )
        XCTAssertNil(PopoverView.creditRowHelp(undated, now: october4, calendar: utcGB, locale: gb))
    }

    func testOnlyCreditPoolsGetACreditRowAndAPoolAtZeroKeepsIt() {
        let untouched = Fixture.bucket(
            id: "nimbus_quill", label: "Included credits", percent: 0,
            credit: CreditPool(usedDollars: 0, limitDollars: 50)
        )
        let service = Fixture.snapshot(id: "claude", buckets: [session, Fixture.cloudCredits, untouched])
        XCTAssertEqual(PopoverView.creditPools(service).map(\.id), ["iguana_necktie", "nimbus_quill"])
        XCTAssertEqual(PopoverView.creditRowValue(untouched, locale: us), "$0 / $50")
        XCTAssertNil(PopoverView.creditRowValue(session, locale: us), "a rate-limit window has no dollars")
    }

    func testACreditPoolOpensTheSpendCardOnItsOwn() {
        // No week's dollars, no extra usage: before this the pool had no row anywhere.
        let service = Fixture.snapshot(id: "claude", buckets: [session, Fixture.cloudCredits])
        XCTAssertTrue(PopoverView.showsSpendGroup(service: service, hasHero: true))
    }

    func testAnAccountWhoseOnlyReadingIsItsCreditHasSomethingToShow() {
        XCTAssertFalse(PopoverView.nothingToShow(Fixture.snapshot(id: "claude", buckets: [Fixture.cloudCredits])))
        XCTAssertTrue(PopoverView.nothingToShow(Fixture.snapshot(id: "claude")))
    }
}
