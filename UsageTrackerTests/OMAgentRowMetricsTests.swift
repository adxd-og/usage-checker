import XCTest
@testable import Omelette

/// Liquid-glass spec § Components, "Agent row (dashboard)": the dashboard's Live card
/// draws the row a size up (`Dashboard-Agents(-Light).dc.html`: 28 pt logo, 10 pt dot,
/// 13.5 / 12.5 pt text). The popover's row (`Main.dc.html`) is the default and does not
/// move.
final class OMAgentRowMetricsTests: XCTestCase {
    func testThePopoverRowKeepsItsSizes() {
        XCTAssertEqual(
            OMAgentRowMetrics.popover,
            OMAgentRowMetrics(logoSide: 20, badgeDiameter: 8, titleSize: 13, subtitleSize: 11.5)
        )
        XCTAssertEqual(OMAgentRowMetrics.popover.iconSize, 18, "the logo inside its 20 pt box, as before")
    }

    func testARowIsPopoverSizedUnlessItsHostOptsIn() {
        XCTAssertEqual(OMAgentRow.defaultMetrics, .popover)
    }

    func testThePopoverTextInsetIsUnchanged() {
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true, metrics: .popover), 31)
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true), 31)
    }

    func testTheDashboardRowIsTheMockups() {
        XCTAssertEqual(
            OMAgentRowMetrics.dashboard,
            OMAgentRowMetrics(logoSide: 28, badgeDiameter: 10, titleSize: 13.5, subtitleSize: 12.5)
        )
        XCTAssertEqual(OMAgentRowMetrics.dashboard.iconSize, 26)
    }

    func testOnTheDashboardTheButtonsStartPastTheLargerLogo() {
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: true, metrics: .dashboard), 39)
    }

    func testWithoutALogoTheSizeDoesNotMoveTheText() {
        XCTAssertEqual(OMAgentRow.textInset(showsProviderIcon: false, metrics: .dashboard), 19)
    }
}
