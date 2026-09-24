import XCTest
@testable import Omelette

/// History's header at the dashboard's 820 pt minimum. The line beside the controls
/// is short enough to sit there. The API-equivalent sentence that used to ride on it
/// made the Cost subtitle 666 pt wide (673 pt for Codex) and was the part cut off; it
/// now comes back as a line of its own. Spec:
/// docs/superpowers/specs/2026-09-24-2.7.0-hardening.md § Design (session rulings),
/// UI — History header; report D § 1.
final class HistoryHeaderTests: XCTestCase {
    private func header(
        showsQuota: Bool = false, mode: HistoryChartMode,
        isPayAsYouGo: Bool = false, range: TimeRange = .sevenDays
    ) -> (line: String, caption: String?) {
        SessionHistoryView.subtitle(
            showsQuota: showsQuota, providerName: "Claude",
            longName: "Claude Code's session logs",
            mode: mode, isPayAsYouGo: isPayAsYouGo, range: range
        )
    }

    func testNoHeaderLineCarriesTheLongCaption() {
        for mode in HistoryChartMode.allCases {
            for showsQuota in [false, true] {
                for isPayAsYouGo in [false, true] {
                    for range in TimeRange.allCases {
                        let line = header(showsQuota: showsQuota, mode: mode, isPayAsYouGo: isPayAsYouGo, range: range).line
                        XCTAssertFalse(
                            line.contains(CostCopy.apiEquivalent),
                            "\(mode) quota=\(showsQuota) payg=\(isPayAsYouGo) \(range): \(line)"
                        )
                    }
                }
            }
        }
    }

    func testOnlyASubscriptionsCostChartGetsTheCaption() {
        for mode in HistoryChartMode.allCases {
            for showsQuota in [false, true] {
                for isPayAsYouGo in [false, true] {
                    let expected = mode == .cost && !showsQuota && !isPayAsYouGo
                    XCTAssertEqual(
                        header(showsQuota: showsQuota, mode: mode, isPayAsYouGo: isPayAsYouGo).caption != nil,
                        expected,
                        "\(mode) quota=\(showsQuota) payg=\(isPayAsYouGo)"
                    )
                }
            }
        }
    }

    func testTheCaptionIsTheSentenceEveryOtherSurfaceUses() {
        XCTAssertEqual(header(mode: .cost).caption, CostCopy.apiEquivalentCaption(isPayAsYouGo: false))
    }

    func testTheCostLineIsJustTheSourceOnceTheCaptionMovesOut() {
        let codex = SessionHistoryView.subtitle(
            showsQuota: false, providerName: "Codex",
            longName: "the Codex CLI's session logs",
            mode: .cost, isPayAsYouGo: false
        )
        XCTAssertEqual(codex.line, "Daily cost from the Codex CLI's session logs")
    }
}
