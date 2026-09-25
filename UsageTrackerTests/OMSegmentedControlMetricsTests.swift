import SwiftUI
import XCTest
@testable import Omelette

/// The sizes P0 left to P1 (P0 plan, Decision 8): `Main.dc.html` for the popover,
/// `Dashboard-Overview.dc.html` / `Dashboard-Agents.dc.html` for the dashboard, and the
/// yolk needs-you dot. Plus the container's VoiceOver label, which the dashboard's
/// range picker needs to name ("Time range") rather than inherit "Provider".
final class OMSegmentedControlMetricsTests: XCTestCase {
    func testThePopoverDrawsThirtyPointSegmentsSharingItsWidth() {
        let m = OMSegmentMetrics.popover
        XCTAssertEqual(m.height, 30)
        XCTAssertEqual(m.fontSize, 12)
        XCTAssertEqual(m.selectedWeight, .semibold)
        XCTAssertEqual(m.weight, .semibold)
        XCTAssertEqual(m.iconSize, 16)
        XCTAssertEqual(m.iconTitleSpacing, 7)
        XCTAssertTrue(m.fillsWidth)
    }

    func testTheDashboardDrawsThirtyPointSegmentsThatHugTheirLabels() {
        let m = OMSegmentMetrics.dashboard
        XCTAssertEqual(m.height, 30)
        XCTAssertEqual(m.fontSize, 12.5)
        XCTAssertEqual(m.selectedWeight, .semibold)
        XCTAssertEqual(m.weight, .medium)
        XCTAssertEqual(m.iconSize, 15)
        XCTAssertEqual(m.iconTitleSpacing, 7)
        XCTAssertEqual(m.leadingPadding, 10)
        XCTAssertEqual(m.trailingPadding, 14)
        XCTAssertFalse(m.fillsWidth)
    }

    func testASegmentWithoutALogoIsPaddedEvenly() {
        XCTAssertEqual(OMSegmentedControl.leadingPadding(hasIcon: true, metrics: .dashboard), 10)
        XCTAssertEqual(OMSegmentedControl.leadingPadding(hasIcon: false, metrics: .dashboard), 14)
        XCTAssertEqual(OMSegmentedControl.leadingPadding(hasIcon: true, metrics: .popover), 6)
    }

    /// `Main.dc.html`: a 6 pt yolk dot at `top: 5px; right: calc(50% - 14px)` on a
    /// 30 pt segment whose 16 pt logo is centred — just past the logo's top-right corner.
    func testTheNeedsYouDotIsYolkAtTheLogosTopRight() {
        XCTAssertEqual(OMSegmentedControl.needsYouDotToken, .accent)
        XCTAssertEqual(OMSegmentedControl.needsYouDotDiameter, 6)
        XCTAssertEqual(OMSegmentedControl.needsYouDotOffset, CGSize(width: 6, height: -2))
    }

    @MainActor
    func testTheDashboardSizeIsTheDefaultSoItsCallSitesNeedNoChange() {
        let control = OMSegmentedControl(items: [], selection: .constant("all"))
        XCTAssertEqual(control.metrics, .dashboard)
    }

    @MainActor
    func testTheContainerIsNamedProviderUnlessTheCallerNamesIt() {
        XCTAssertEqual(OMSegmentedControl(items: [], selection: .constant("all")).containerLabel, "Provider")
        XCTAssertEqual(
            OMSegmentedControl(items: [], selection: .constant("7d"), accessibilityLabel: "Time range").containerLabel,
            "Time range"
        )
    }
}
