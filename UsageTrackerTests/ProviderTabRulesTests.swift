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
}
