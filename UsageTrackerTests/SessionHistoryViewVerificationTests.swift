import XCTest
@testable import Omelette

/// Independent verification of `SessionHistoryView.subtitle` and
/// `SessionHistoryView.tokenColumns(availableWidth:)`, from the spec rather than from
/// the executor's own `HistoryHeaderTests` / `TokenColumnsTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "History header" and "Tokens table"; report D §§ 1, 5.
final class SessionHistoryViewVerificationTests: XCTestCase {
    // MARK: - subtitle: the API-equivalent caption is a separate line

    func testASubscriptionCostChartCarriesTheDisclaimerAsItsOwnCaption() {
        let result = SessionHistoryView.subtitle(
            showsQuota: false, providerName: "Claude", longName: "Claude Code's session logs",
            mode: .cost, isPayAsYouGo: false
        )
        XCTAssertEqual(result.caption, "API-equivalent cost of your CLI usage — not what your subscription bills.")
        XCTAssertFalse(result.line.contains("API-equivalent"), "the disclaimer must not also ride on the line: \(result.line)")
        XCTAssertEqual(result.line, "Daily cost from Claude Code's session logs")
    }

    func testAPayAsYouGoCostChartHasNoDisclaimerAtAll() {
        let result = SessionHistoryView.subtitle(
            showsQuota: false, providerName: "Claude", longName: "Claude Code's session logs",
            mode: .cost, isPayAsYouGo: true
        )
        XCTAssertNil(result.caption)
        XCTAssertEqual(result.line, "Daily cost from Claude Code's session logs", "the line itself is unaffected by pay-as-you-go")
    }

    func testTheTokensChartNeverCarriesTheCostDisclaimer() {
        for isPayAsYouGo in [false, true] {
            let result = SessionHistoryView.subtitle(
                showsQuota: false, providerName: "Codex", longName: "the Codex CLI's session logs",
                mode: .tokens, isPayAsYouGo: isPayAsYouGo
            )
            XCTAssertNil(result.caption, "payg=\(isPayAsYouGo)")
            XCTAssertEqual(result.line, "Daily tokens by type from the Codex CLI's session logs")
        }
    }

    func testTheSessionsChartNeverCarriesTheCostDisclaimerEvenOnASubscription() {
        let result = SessionHistoryView.subtitle(
            showsQuota: false, providerName: "Claude", longName: "Claude Code's session logs",
            mode: .sessions, isPayAsYouGo: false, range: .sevenDays
        )
        XCTAssertNil(result.caption)
        XCTAssertTrue(result.line.contains("API-equivalent cost"), "the sessions line qualifies the dollars inline instead: \(result.line)")
    }

    func testQuotaModeIgnoresChartModeAndPayAsYouGoAndNeverCaptions() {
        let result = SessionHistoryView.subtitle(
            showsQuota: true, providerName: "Antigravity", longName: nil,
            mode: .cost, isPayAsYouGo: false
        )
        XCTAssertNil(result.caption)
        XCTAssertEqual(result.line, "How full Antigravity's usage windows ran")
    }

    /// The full cross product from the spec's own wording: caption present exactly
    /// when subscription + Cost mode + not quota.
    func testCaptionPresenceAcrossEveryCombination() {
        for mode in HistoryChartMode.allCases {
            for showsQuota in [false, true] {
                for isPayAsYouGo in [false, true] {
                    let result = SessionHistoryView.subtitle(
                        showsQuota: showsQuota, providerName: "Claude", longName: "Claude Code's session logs",
                        mode: mode, isPayAsYouGo: isPayAsYouGo
                    )
                    let expectCaption = !showsQuota && mode == .cost && !isPayAsYouGo
                    XCTAssertEqual(
                        result.caption != nil, expectCaption,
                        "mode=\(mode) quota=\(showsQuota) payg=\(isPayAsYouGo) caption=\(String(describing: result.caption))"
                    )
                }
            }
        }
    }

    // MARK: - tokenColumns: the cache-column merge boundary

    func testExactly580StaysSplit() {
        let columns = SessionHistoryView.tokenColumns(availableWidth: 580)
        XCTAssertEqual(columns, [.input, .output, .cacheRead, .cacheWrite, .cost])
    }

    func testJustBelow580Merges() {
        let columns = SessionHistoryView.tokenColumns(availableWidth: 579.99)
        XCTAssertEqual(columns, [.input, .output, .cache, .cost])
    }

    func testWellAboveTheBoundaryStaysSplit() {
        XCTAssertEqual(
            SessionHistoryView.tokenColumns(availableWidth: 900),
            [.input, .output, .cacheRead, .cacheWrite, .cost]
        )
    }

    func testWellBelowTheBoundaryMerges() {
        XCTAssertEqual(
            SessionHistoryView.tokenColumns(availableWidth: 300),
            [.input, .output, .cache, .cost]
        )
    }

    /// The constant the boundary is measured against must itself be 580, not merely
    /// the comparison behaving as if it were.
    func testTheConstantIsExactly580() {
        XCTAssertEqual(SessionHistoryView.minimumSplitCacheWidth, 580)
    }

    func testTheMergedCacheColumnSumsReadAndWrite() {
        let day = SessionFixture.tokens(input: 2_500, output: 750, cacheRead: 3_400_000, cacheWrite5m: 150_000, cacheWrite1h: 250_000)
        XCTAssertEqual(TokenColumn.cache.value(breakdown: day, cost: 0), "3.8M")
        XCTAssertEqual(TokenColumn.cacheRead.value(breakdown: day, cost: 0), "3.4M")
        XCTAssertEqual(TokenColumn.cacheWrite.value(breakdown: day, cost: 0), "400.0k")
        XCTAssertEqual(TokenColumn.input.value(breakdown: day, cost: 0), "2.5k")
        XCTAssertEqual(TokenColumn.output.value(breakdown: day, cost: 0), "750")
        XCTAssertEqual(TokenColumn.cost.value(breakdown: .zero, cost: 7.5), "$7.50")
    }
}
