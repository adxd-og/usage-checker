import XCTest
@testable import Omelette

/// Independent verification of `SessionHistoryView.subtitle`, from the spec rather than
/// from the executor's own `HistoryHeaderTests`. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — "History header"; report D § 1.
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
}
