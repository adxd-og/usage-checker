import SwiftUI
import XCTest
@testable import Omelette

/// Session rulings of 2026-09-25 on the P2 plan (R4), over liquid-glass spec § Tokens:
/// the dashboard window's tint, the sidebar's shadows and light edge, the screen title and
/// its subtitle.
/// Values from `Dashboard-Overview(-Light).dc.html` lines 18–19 and the header rows.
final class DashboardChromeTokensTests: XCTestCase {
    func testTheWindowTintIsTheMockupsWindowFill() {
        // rgba(20,21,26,0.9) and rgba(247,246,250,0.86).
        XCTAssertEqual(OMPalette.rgba(.windowTint, scheme: .dark), OMRGBA(hex: 0x14151A, opacity: 0.9))
        XCTAssertEqual(OMPalette.rgba(.windowTint, scheme: .light), OMRGBA(hex: 0xF7F6FA, opacity: 0.86))
    }

    func testTheSidebarCastsTheMockupsTwoShadows() {
        XCTAssertEqual(OMGlass.sidebarShadows(scheme: .dark), [
            OMShadow(color: .black(0.35), y: 10, blur: 30),
            OMShadow(color: .black(0.3), y: 2, blur: 10),
        ])
        // rgba(50,40,90,…) is 0x32285A.
        XCTAssertEqual(OMGlass.sidebarShadows(scheme: .light), [
            OMShadow(color: OMRGBA(hex: 0x32285A, opacity: 0.1), y: 8, blur: 24),
            OMShadow(color: OMRGBA(hex: 0x32285A, opacity: 0.08), y: 2, blur: 8),
        ])
    }

    func testInDarkTheSidebarIsChromeGlass() {
        XCTAssertEqual(OMGlass.recipe(.sidebar, scheme: .dark), OMGlass.recipe(.chrome, scheme: .dark))
    }

    func testInLightTheSidebarsEdgeIsTheHairlineNotTheMockupsDarkOutline() {
        let sidebar = OMGlass.recipe(.sidebar, scheme: .light)
        let chrome = OMGlass.recipe(.chrome, scheme: .light)
        XCTAssertEqual(sidebar.border, .black(0.08))
        XCTAssertEqual(sidebar.border, OMPalette.rgba(.hairline, scheme: .light))
        XCTAssertEqual(sidebar.fill, chrome.fill)
        XCTAssertEqual(sidebar.topHighlight, chrome.topHighlight)
        XCTAssertEqual(sidebar.bottomHighlight, chrome.bottomHighlight)
        XCTAssertEqual(sidebar.shadow, chrome.shadow)
    }

    func testTheSidebarIsSystemGlassLikeChrome() {
        XCTAssertTrue(OMGlassRules.usesSystemGlass(.sidebar))
    }

    func testDashboardTitlesAre26PointBoldAndTheTourKeepsItsOwn() {
        XCTAssertEqual(OMFont.dashboardTitle, Font.system(size: 26, weight: .bold))
        XCTAssertEqual(OMFont.screenTitle, Font.system(size: 22, weight: .semibold))
    }

    func testTheHeadersSubtitleIsTwelveAndAHalfPointAsTheMockupDrawsIt() {
        // Under the title: `font-size: 12.5px; color: rgba(245,245,247,0.64)`.
        XCTAssertEqual(OMFont.dashboardSubtitle, Font.system(size: 12.5))
        XCTAssertEqual(DashboardHeader.subtitleFont, OMFont.dashboardSubtitle)
    }
}
