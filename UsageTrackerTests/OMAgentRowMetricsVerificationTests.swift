import XCTest
@testable import Omelette

/// Independent verification that Task 9's opt-in `OMAgentRowMetrics` (plan
/// `docs/superpowers/plans/2026-09-25-3.0-P4-agents.md`, ruling R3) left the popover's
/// agent row exactly as it was at `main` (`54694ed`), before P4 touched the file. The
/// baseline numbers below are copied from `git show 54694ed:UsageTracker/UI/DesignSystem/
/// OMAgentRow.swift` rather than from the constants the redesign now routes through
/// `OMAgentRowMetrics.popover`, so a change to those shared constants would be caught
/// here instead of only self-confirming against itself.
final class OMAgentRowMetricsVerificationTests: XCTestCase {
    // MARK: - The popover baseline, hardcoded from main

    func testPopoverMetricsAreExactlyWhatMainDrewBeforeTheRedesign() {
        XCTAssertEqual(OMAgentRowMetrics.popover.logoSide, 20)
        XCTAssertEqual(OMAgentRowMetrics.popover.badgeDiameter, 8)
        XCTAssertEqual(OMAgentRowMetrics.popover.titleSize, 13)
        XCTAssertEqual(OMAgentRowMetrics.popover.subtitleSize, 11.5)
    }

    func testThePopoverLogoIconIsTwoPointsInsideItsTwentyPointBox() {
        // main drew ProviderIconView(..., size: 18) directly; iconSize must reproduce it.
        XCTAssertEqual(OMAgentRowMetrics.popover.iconSize, 18)
    }

    func testTheSharedRowConstantsThatBuildPopoverAreThemselvesUnmoved() {
        // OMAgentRowMetrics.popover is built from these; confirming them independently
        // catches a drift in the constants themselves, not just the wrapper struct.
        XCTAssertEqual(OMAgentRow.badgeDiameter, 8)
        XCTAssertEqual(OMAgentRow.titleSize, 13)
        XCTAssertEqual(OMAgentRow.subtitleSize, 11.5)
        XCTAssertEqual(OMAgentRow.horizontalPadding, 14)
        XCTAssertEqual(OMAgentRow.verticalPadding, 11)
        XCTAssertEqual(OMAgentRow.dotDiameter, 8)
    }

    // MARK: - The popover is the default at every call site that does not opt in

    func testARowWithNoMetricsArgumentIsPopoverSized() {
        XCTAssertEqual(OMAgentRow.defaultMetrics, .popover)
    }

    func testLeadingWidthWithNoMetricsArgumentMatchesThePopoverLogo() {
        XCTAssertEqual(OMAgentRow.leadingWidth(showsProviderIcon: true), 20)
    }

    func testTextInsetWithNoMetricsArgumentMatchesThePopover() {
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true), 31)
    }

    // MARK: - The dashboard size is genuinely different, not an accidental alias

    func testTheDashboardMetricsAreTheMockupsNotThePopovers() {
        XCTAssertNotEqual(OMAgentRowMetrics.dashboard, OMAgentRowMetrics.popover)
        XCTAssertEqual(OMAgentRowMetrics.dashboard.logoSide, 28)
        XCTAssertEqual(OMAgentRowMetrics.dashboard.badgeDiameter, 10)
        XCTAssertEqual(OMAgentRowMetrics.dashboard.titleSize, 13.5)
        XCTAssertEqual(OMAgentRowMetrics.dashboard.subtitleSize, 12.5)
        XCTAssertEqual(OMAgentRowMetrics.dashboard.iconSize, 26)
    }

    func testDashboardLeadingWidthAndTextInsetGrowWithTheLargerLogo() {
        XCTAssertEqual(OMAgentRow.leadingWidth(showsProviderIcon: true, metrics: .dashboard), 28)
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true, metrics: .dashboard), 39)
    }

    /// The provider-tab dot (no logo) does not scale with the row's metrics — only the
    /// logo box does. A regression here would misalign the dashboard's flat-list rows,
    /// if it ever grows one.
    func testTheStateDotWidthIgnoresMetricsBecauseItHasNoLogoBox() {
        XCTAssertEqual(OMAgentRow.leadingWidth(showsProviderIcon: false, metrics: .popover), OMAgentRow.dotDiameter)
        XCTAssertEqual(OMAgentRow.leadingWidth(showsProviderIcon: false, metrics: .dashboard), OMAgentRow.dotDiameter)
    }

    // MARK: - AgentsLiveCard actually opts into the dashboard size

    func testTheLiveCardsRowMetricsAreTheDashboardSize() {
        XCTAssertEqual(AgentsLiveCard.rowMetrics, .dashboard)
        XCTAssertNotEqual(AgentsLiveCard.rowMetrics, OMAgentRow.defaultMetrics)
    }
}
