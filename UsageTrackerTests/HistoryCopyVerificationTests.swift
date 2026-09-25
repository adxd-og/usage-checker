import XCTest
@testable import Omelette

/// Independent verification of `HistoryCopy` against liquid-glass spec § Screens (the
/// History rows) and § Decisions ("What limit hit counts", D10, D12).
final class HistoryCopyVerificationTests: XCTestCase {
    // MARK: - subtitle (D10: one sentence covers every cost view)

    func testSubtitleForAQuotaOnlyProviderNamesTheProvider() {
        let text = HistoryCopy.subtitle(showsQuota: true, providerName: "Antigravity", sourceName: nil, isPayAsYouGo: false)
        XCTAssertEqual(text, "How full Antigravity usage windows ran")
    }

    func testSubtitleForASubscriptionNamesTheApiEquivalent() {
        let text = HistoryCopy.subtitle(
            showsQuota: false, providerName: "Claude", sourceName: "Claude Code's session logs", isPayAsYouGo: false
        )
        XCTAssertEqual(text, "API-equivalent cost from Claude Code's session logs, not your subscription bill")
    }

    func testSubtitleForPayAsYouGoDoesNotClaimAnApiEquivalent() {
        let text = HistoryCopy.subtitle(showsQuota: false, providerName: "Codex", sourceName: "Codex CLI logs", isPayAsYouGo: true)
        XCTAssertEqual(text, "Cost from Codex CLI logs")
    }

    func testSubtitleFallsBackWhenNoSourceName() {
        let text = HistoryCopy.subtitle(showsQuota: false, providerName: "X", sourceName: nil, isPayAsYouGo: false)
        XCTAssertEqual(text, "API-equivalent cost from local CLI logs, not your subscription bill")
    }

    // MARK: - quotaOnlyNote: per-provider reason (spec § Removals, "usage history only")

    func testQuotaOnlyNoteNamesAntigravitysOwnReason() {
        XCTAssertTrue(HistoryCopy.quotaOnlyNote(provider: "antigravity").hasPrefix("Antigravity keeps no local token log"))
    }

    func testQuotaOnlyNoteNamesGeminisOwnReason() {
        XCTAssertTrue(HistoryCopy.quotaOnlyNote(provider: "gemini").contains("Omelette doesn't read the Gemini CLI's token log"))
    }

    func testQuotaOnlyNoteHasAGenericFallbackForAnyOtherProvider() {
        let text = HistoryCopy.quotaOnlyNote(provider: "codex")
        XCTAssertTrue(text.hasSuffix("so there are no costs or sessions here. Quota over time is charted instead."))
    }

    // MARK: - daysAtLimit

    func testDaysAtLimitIsNilBeforeAnythingWasObserved() {
        XCTAssertNil(HistoryCopy.daysAtLimit(0, of: 0))
    }

    func testDaysAtLimitSingularBoundary() {
        XCTAssertEqual(HistoryCopy.daysAtLimit(0, of: 1), "0 of 1 day at limit")
    }

    func testDaysAtLimitPluralPhrasing() {
        XCTAssertEqual(HistoryCopy.daysAtLimit(3, of: 28), "3 of 28 days at limit")
    }

    // MARK: - dollars (D12: US-grouped after "$")

    func testDollarsAreUsGroupedWithTwoDecimals() {
        XCTAssertEqual(HistoryCopy.dollars(1_352.28), "$1,352.28")
        XCTAssertEqual(HistoryCopy.dollars(0), "$0.00")
    }

    func testCostBarLabelDropsCentsAtTenDollarsAndAbove() {
        XCTAssertEqual(HistoryCopy.costBarLabel(9.50), "$9.50", "just under 10 keeps cents")
        XCTAssertEqual(HistoryCopy.costBarLabel(10.00), "$10", "10 itself is whole dollars")
        XCTAssertEqual(HistoryCopy.costBarLabel(518.4), "$518")
        XCTAssertEqual(HistoryCopy.costBarLabel(1_352.28), "$1,352")
    }

    // MARK: - rangePhrase / calendarTitle

    func testRangePhraseCoversEveryOfferedRange() {
        XCTAssertEqual(HistoryCopy.rangePhrase(.oneDay), "last 24 hours")
        XCTAssertEqual(HistoryCopy.rangePhrase(.sevenDays), "last 7 days")
        XCTAssertEqual(HistoryCopy.rangePhrase(.thirtyDays), "last 30 days")
        XCTAssertEqual(HistoryCopy.rangePhrase(.ninetyDays), "last 90 days")
        XCTAssertEqual(HistoryCopy.rangePhrase(.oneYear), "last year")
    }

    func testCalendarTitleSwitchesBetweenCostAndDailyPeak() {
        XCTAssertEqual(HistoryCopy.calendarTitle(range: .sevenDays, showsQuota: false), "Cost per day, last 7 days")
        XCTAssertEqual(HistoryCopy.calendarTitle(range: .sevenDays, showsQuota: true), "Daily peak, last 7 days")
    }

    // MARK: - Sessions card / open-chat columns (spec § Screens "History · Session expanded")

    func testSessionColumnsCarryTheMockupsFour() {
        XCTAssertEqual(Array(HistoryCopy.sessionColumns.dropFirst()), ["Last active", "Turns", "Tokens", "Cost"])
    }

    func testDayColumnsMatchTheByDayTable() {
        XCTAssertEqual(HistoryCopy.dayColumns, ["Day", "Turns", "Tokens", "Cost"])
    }

    func testAgentColumnsMatchTheSubAgentsTable() {
        XCTAssertEqual(HistoryCopy.agentColumns, ["Agent", "Model", "Effort", "Turns", "Tokens", "Cost"])
    }

    func testMoneyTitleNamesDollarsOnlyWhenPriced() {
        XCTAssertEqual(HistoryCopy.moneyTitle(hasCost: true), "Where the money went")
        XCTAssertEqual(HistoryCopy.moneyTitle(hasCost: false), "Tokens by type")
    }

    // MARK: - viewModeKey / modePickerLabel are storage / accessibility contracts

    func testViewModeStorageKeyIsHistoryView() {
        XCTAssertEqual(HistoryRules.viewModeKey, "historyView")
    }
}
