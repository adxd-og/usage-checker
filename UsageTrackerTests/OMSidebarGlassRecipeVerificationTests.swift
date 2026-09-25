import SwiftUI
import XCTest
@testable import Omelette

/// Independent verification of P0 (liquid-glass redesign spec § Design → Tokens,
/// "pane glass" row: "sidebar, dashboard cards"; § Components, "Sidebar": "floating
/// glass pane"). `OMGlassKind.pane` (SharedUI/OMTokens.swift:340-341) and
/// `paneGlass(in:)` (UsageTracker/UI/Components/LiquidGlass.swift:99-100) are both
/// documented as the sidebar's recipe. This file checks that claim against the
/// mockups' own inline styles rather than against the spec table's prose, per the
/// verifier brief ("Mockups with the exact values" are the ground truth).
///
/// Every dashboard mockup's `<nav>` (`Dashboard-Overview(-Light)`, `-Agents`,
/// `-Insights`, `-History-Cost.dc.html`) draws the sidebar with these exact values —
/// identical across all four screens and both appearances:
///   dark:  background: rgba(26,26,31,0.6); border: 1px solid rgba(255,255,255,0.11);
///          box-shadow: inset 0 1px 0 rgba(255,255,255,0.16),
///                      inset 0 -1px 0 rgba(255,255,255,0.03)
///   light: background: rgba(255,255,255,0.56); backdrop-filter unchanged;
///          box-shadow: inset 0 1px 0 rgba(255,255,255,0.95), …
/// Those are `OMGlass.recipe(.chrome, …)`'s values verbatim (also `Main.dc.html`'s and
/// `Popover-All-Light.dc.html`'s popover body) — not `.pane`'s content-fill values,
/// which only the dashboard cards (22 pt radius divs: rgba(255,255,255,0.055) /
/// rgba(255,255,255,0.72), no backdrop-filter of their own) actually draw.
final class OMSidebarGlassRecipeVerificationTests: XCTestCase {
    /// `Dashboard-Overview.dc.html`, `Dashboard-Agents.dc.html`,
    /// `Dashboard-Insights.dc.html` and `Dashboard-History-Cost.dc.html` all draw the
    /// sidebar `<nav>` with this exact recipe in dark.
    private let sidebarFromDarkMockups = OMGlassRecipe(
        fill: OMRGBA(hex: 0x1A1A1F, opacity: 0.6),
        border: .white(0.11),
        topHighlight: .white(0.16),
        bottomHighlight: .white(0.03),
        shadow: nil
    )

    func testTheSidebarsDarkPixelsAreChromeGlassNotPaneGlass() {
        XCTAssertEqual(
            sidebarFromDarkMockups, OMGlass.recipe(.chrome, scheme: .dark),
            "the sidebar mockups' values equal the chrome recipe"
        )
        XCTAssertNotEqual(
            sidebarFromDarkMockups, OMGlass.recipe(.pane, scheme: .dark),
            "the sidebar mockups' values do not equal the pane recipe"
        )
    }

    func testTheSidebarsLightFillAndTopHighlightAreChromesNotPanes() {
        // Dashboard-Overview-Light.dc.html <nav>: background: rgba(255,255,255,0.56);
        // box-shadow: inset 0 1px 0 rgba(255,255,255,0.95), … — chrome's light fill and
        // top highlight exactly (pane's light fill is white @ 72%, no top highlight).
        let sidebarFill = OMRGBA.white(0.56)
        let sidebarTopHighlight = OMRGBA.white(0.95)
        XCTAssertEqual(sidebarFill, OMGlass.recipe(.chrome, scheme: .light).fill)
        XCTAssertEqual(sidebarTopHighlight, OMGlass.recipe(.chrome, scheme: .light).topHighlight)
        XCTAssertNotEqual(
            sidebarFill, OMGlass.recipe(.pane, scheme: .light).fill,
            "pane's content fill (white @ 72%) is not what the sidebar mockups draw (white @ 56%)"
        )
    }

    /// The dashboard cards (22 pt radius, e.g. Overview's hero and Tokens-today cards)
    /// really do draw `.pane`'s content-fill values — so `.pane` is right for cards,
    /// which sharpens the sidebar mismatch rather than explaining it away.
    func testPaneGlassDoesMatchTheDashboardCardsWhichIsNotTheSidebar() {
        // Dashboard-Overview.dc.html's 22pt-radius cards: background:
        // rgba(255,255,255,0.055); border: 1px solid rgba(255,255,255,0.05).
        let cardFromMockup = OMGlassRecipe(
            fill: .white(0.055), border: .white(0.05),
            topHighlight: nil, bottomHighlight: nil, shadow: nil
        )
        XCTAssertEqual(cardFromMockup, OMGlass.recipe(.pane, scheme: .dark))
    }
}
