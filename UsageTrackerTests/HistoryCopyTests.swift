import XCTest
@testable import Omelette

/// Liquid-glass spec § Screens, the History rows: the page is "History", and one line
/// under the title says where its numbers come from. On a subscription that line is
/// also where the dollars are called API-equivalent, once for the page (CLAUDE.md,
/// Conventions).
final class HistoryCopySubtitleTests: XCTestCase {
    func testThePageIsCalledHistory() {
        XCTAssertEqual(HistoryCopy.title, "History")
    }

    func testASubscriptionsDollarsAreCalledApiEquivalentOnce() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Claude",
                sourceName: "Claude Code's session logs", isPayAsYouGo: false
            ),
            "API-equivalent cost from Claude Code's session logs, not your subscription bill"
        )
    }

    func testPayAsYouGoDollarsAreTheBill() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Claude",
                sourceName: "Claude Code's session logs", isPayAsYouGo: true
            ),
            "Cost from Claude Code's session logs"
        )
    }

    func testALogWithNoNameStillReadsAsASentence() {
        XCTAssertEqual(
            HistoryCopy.subtitle(showsQuota: false, providerName: "Grok", sourceName: nil, isPayAsYouGo: false),
            "API-equivalent cost from local CLI logs, not your subscription bill"
        )
    }

    func testAQuotaOnlyProviderIsAboutHowFullItsWindowsRan() {
        for isPayAsYouGo in [false, true] {
            XCTAssertEqual(
                HistoryCopy.subtitle(
                    showsQuota: true, providerName: "Antigravity",
                    sourceName: nil, isPayAsYouGo: isPayAsYouGo
                ),
                "How full Antigravity usage windows ran"
            )
        }
    }

    func testTheCodexLogIsNamedTheWayCostSourceNamesIt() {
        XCTAssertEqual(
            HistoryCopy.subtitle(
                showsQuota: false, providerName: "Codex",
                sourceName: DashboardState.costSource(for: "codex").longName, isPayAsYouGo: false
            ),
            "API-equivalent cost from the Codex CLI's session logs, not your subscription bill"
        )
    }
}

/// The Cost/Tokens switch names itself for VoiceOver; the control's default is "Provider".
final class HistoryCopyControlsTests: XCTestCase {
    func testTheUnitSwitchIsCalledUnit() {
        XCTAssertEqual(HistoryCopy.modePickerLabel, "Unit")
    }
}
