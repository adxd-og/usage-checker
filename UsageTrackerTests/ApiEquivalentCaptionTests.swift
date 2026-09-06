import XCTest
@testable import Omelette

/// Where the "API-equivalent" sentence lands, as pure rules: the History subtitle and
/// the daily summary body. The popover and the Overview compose the same
/// `CostCopy.apiEquivalentCaption` directly and are covered by the build.
final class ApiEquivalentCaptionTests: XCTestCase {
    // MARK: - SessionHistoryView.subtitle

    func testTheCostSubtitleCarriesTheCaptionForASubscription() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude", longName: "Claude Code logs",
                mode: .cost, isPayAsYouGo: false
            ),
            "Daily cost from Claude Code logs · API-equivalent cost of your CLI usage — not what your subscription bills."
        )
    }

    func testPayAsYouGoKeepsThePlainSubtitle() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude", longName: "Claude Code logs",
                mode: .cost, isPayAsYouGo: true
            ),
            "Daily cost from Claude Code logs"
        )
    }

    func testTheTokensModeSaysNothingAboutDollars() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Claude", longName: "Claude Code logs",
                mode: .tokens, isPayAsYouGo: false
            ),
            "Daily cost from Claude Code logs",
            "the tokens chart shows no dollars, so a caption about dollars would be noise"
        )
    }

    func testAProviderWithoutACostLogKeepsTheQuotaSubtitle() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: true, providerName: "Antigravity", longName: nil,
                mode: .cost, isPayAsYouGo: false
            ),
            "How full Antigravity's usage windows ran"
        )
    }

    func testAProviderWithACostLogButNoLongNameStillReadsAsASentence() {
        XCTAssertEqual(
            SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Grok", longName: nil,
                mode: .cost, isPayAsYouGo: false
            ),
            "Daily cost · API-equivalent cost of your CLI usage — not what your subscription bills."
        )
    }

    // MARK: - UsageNotifier.dailySummaryBody

    func testTheDailySummarySaysWhatKindOfDollarsThoseAre() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 4.2, turns: 23, isPayAsYouGo: false),
            "Yesterday: $4.20 across 23 turns. (API-equivalent)"
        )
    }

    func testPayAsYouGoGetsTheBillWithNoQualifier() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 4.2, turns: 23, isPayAsYouGo: true),
            "Yesterday: $4.20 across 23 turns."
        )
    }

    func testAQuietDayIsStillAQuietDay() {
        XCTAssertEqual(
            UsageNotifier.dailySummaryBody(cost: 0, turns: 0, isPayAsYouGo: false),
            "No Claude Code activity yesterday."
        )
    }
}
